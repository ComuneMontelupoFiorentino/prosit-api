-- ============================================================================
-- PROSIT API v2 — PROCEDURE DI INSTALLAZIONE (da superuser, \connect api)
-- ============================================================================
-- Le usa il file generato da bin/genera_api.py a partire da config/api.yaml,
-- ma si possono chiamare anche a mano. Nessun utente delle API puo' eseguirle.
--
--   CALL api_admin.gruppo('tvcc', ARRAY['vigili','ced'], 'Registro TVCC');
--   CALL api_admin.database('segn', 'segnalazioni_23', 'localhost', 5432, 'prosit_ro', '...', 'prosit_rw', '...');
--   CALL api_admin.importa('segn', 'audit', ARRAY['daily_log_tvcc']);
--   CALL api_admin.risorsa('{"nome":"tvcc-log","sorgente":"segn.audit.daily_log_tvcc", ...}');
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE api_admin.impostazione(p_chiave text, p_valore jsonb)
LANGUAGE sql AS $$
  INSERT INTO api_auth.impostazioni (chiave, valore) VALUES (p_chiave, p_valore)
  ON CONFLICT (chiave) DO UPDATE SET valore = EXCLUDED.valore, aggiornata = now();
$$;

-- ----------------------------------------------------------------------------
-- Ruolo di gruppo grp_<nome>, assegnato agli utenti che stanno in uno dei gruppi Lizmap indicati
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE api_admin.gruppo(p_nome text, p_lizmap text[], p_descrizione text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  r text := 'grp_' || p_nome;
BEGIN
  IF p_nome !~ '^[a-z][a-z0-9_]{0,58}$' THEN
    RAISE EXCEPTION 'Nome gruppo non valido: % (minuscole, cifre, _)', p_nome;
  END IF;
  IF p_nome = 'utenti' THEN
    RAISE EXCEPTION 'Il gruppo "utenti" e'' predefinito (tutti gli utenti autenticati)';
  END IF;
  IF COALESCE(cardinality(p_lizmap), 0) = 0 THEN
    RAISE EXCEPTION 'Gruppo %: indicare almeno un gruppo Lizmap', p_nome;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
    EXECUTE format('CREATE ROLE %I NOLOGIN', r);
  END IF;
  EXECUTE format('GRANT %I TO api_rolemgr WITH ADMIN OPTION, INHERIT FALSE, SET FALSE', r);
  EXECUTE format('COMMENT ON ROLE %I IS %L', r,
                 'Prosit API: ' || COALESCE(p_descrizione, p_nome) || ' (Lizmap: ' || array_to_string(p_lizmap, ', ') || ')');
  INSERT INTO api_auth.gruppi (ruolo, lizmap, descrizione) VALUES (r, p_lizmap, p_descrizione)
  ON CONFLICT (ruolo) DO UPDATE SET lizmap = EXCLUDED.lizmap, descrizione = EXCLUDED.descrizione;
END $$;

-- ----------------------------------------------------------------------------
-- Database esterno raggiunto con postgres_fdw: server fdw_<alias> + due user mapping
--   api_lettore   -> utente in sola lettura sul db esterno (es. prosit_ro)
--   api_scrittore -> utente con scrittura sul db esterno (es. prosit_rw)
-- Le password stanno solo nel catalogo di PostgreSQL (pg_user_mapping, leggibile solo dal superuser).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE api_admin.database(
  p_alias text, p_dbname text, p_host text, p_port integer,
  p_ro_utente text, p_ro_password text, p_rw_utente text DEFAULT NULL, p_rw_password text DEFAULT NULL,
  p_estensioni text DEFAULT NULL
) LANGUAGE plpgsql AS $$
DECLARE
  s   text := 'fdw_' || p_alias;
  opt text;
  m   record;
BEGIN
  IF p_alias !~ '^[a-z][a-z0-9_]{0,20}$' THEN
    RAISE EXCEPTION 'Alias database non valido: %', p_alias;
  END IF;
  IF p_ro_password IS NULL OR p_ro_password = '' THEN
    RAISE EXCEPTION 'Database %: password di sola lettura mancante', p_alias;
  END IF;
  opt := format('host %L, port %L, dbname %L, fetch_size %L, updatable %L, application_name %L',
                p_host, p_port::text, p_dbname, '500', 'true', 'prosit-api');
  IF p_estensioni IS NOT NULL THEN
    opt := opt || format(', extensions %L', p_estensioni);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = s) THEN
    EXECUTE format('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS (%s)', s, opt);
  ELSE
    EXECUTE format('ALTER SERVER %I OPTIONS (SET host %L, SET port %L, SET dbname %L)', s, p_host, p_port::text, p_dbname);
  END IF;
  EXECUTE format('ALTER SERVER %I OWNER TO prosit_api_owner', s);
  EXECUTE format('REVOKE ALL ON FOREIGN SERVER %I FROM PUBLIC', s);
  EXECUTE format('GRANT USAGE ON FOREIGN SERVER %I TO api_lettore, api_scrittore', s);

  FOR m IN SELECT * FROM (VALUES
      ('api_lettore', p_ro_utente, p_ro_password),
      ('api_scrittore', COALESCE(p_rw_utente, p_ro_utente), COALESCE(NULLIF(p_rw_password, ''), p_ro_password))
    ) v(locale, remoto, pw)
  LOOP
    IF EXISTS (SELECT 1 FROM pg_user_mappings WHERE srvname = s AND usename = m.locale) THEN
      EXECUTE format('ALTER USER MAPPING FOR %I SERVER %I OPTIONS (SET user %L, SET password %L)', m.locale, s, m.remoto, m.pw);
    ELSE
      EXECUTE format('CREATE USER MAPPING FOR %I SERVER %I OPTIONS (user %L, password %L)', m.locale, s, m.remoto, m.pw);
    END IF;
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- Valori predefiniti remoti.
-- postgres_fdw invia in INSERT tutte le colonne della tabella esterna: quelle non
-- indicate partono come NULL e i DEFAULT del database di origine NON vengono usati
-- (id serial/identity, data di inserimento...). importa() ricrea quindi i default in
-- locale: le espressioni semplici (now(), costanti) vengono copiate, le sequenze
-- vengono lette dal database di origine con api_fn.prossimo_valore().
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_auth.sequenze (
  server   name NOT NULL,
  sequenza text NOT NULL,
  PRIMARY KEY (server, sequenza)
);
ALTER TABLE api_auth.sequenze OWNER TO prosit_api_owner;
REVOKE ALL ON api_auth.sequenze FROM PUBLIC;
GRANT SELECT ON api_auth.sequenze TO api_scrittore;

CREATE OR REPLACE FUNCTION api_fn.prossimo_valore(p_server text, p_sequenza text) RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v bigint;
BEGIN
  -- solo sequenze registrate da importa(): nessun accesso libero alle sequenze remote
  IF NOT EXISTS (SELECT 1 FROM api_auth.sequenze s WHERE s.server = p_server AND s.sequenza = p_sequenza) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Sequenza remota non registrata';
  END IF;
  -- una connessione per server, riusata finche' la sessione PostgREST resta aperta
  IF p_server <> ALL (COALESCE(dblink_get_connections(), '{}')) THEN
    PERFORM dblink_connect(p_server, p_server);
  END IF;
  BEGIN
    SELECT x INTO v FROM dblink(p_server, format('SELECT nextval(%L)', p_sequenza)) AS t(x bigint);
  EXCEPTION WHEN connection_exception OR sqlclient_unable_to_establish_sqlconnection THEN
    PERFORM dblink_disconnect(p_server);
    PERFORM dblink_connect(p_server, p_server);
    SELECT x INTO v FROM dblink(p_server, format('SELECT nextval(%L)', p_sequenza)) AS t(x bigint);
  END;
  RETURN v;
END $$;
ALTER FUNCTION api_fn.prossimo_valore(text, text) OWNER TO api_scrittore;
REVOKE ALL ON FUNCTION api_fn.prossimo_valore(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_fn.prossimo_valore(text, text) TO grp_utenti, api_scrittore;

-- ----------------------------------------------------------------------------
-- Importa tabelle/viste di uno schema esterno in fdw_<alias>_<schema>
-- (l'importazione usa la connessione di api_scrittore)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE api_admin.importa(p_alias text, p_schema text, p_tabelle text[])
LANGUAGE plpgsql AS $$
DECLARE
  loc text := 'fdw_' || p_alias || '_' || lower(regexp_replace(p_schema, '[^A-Za-z0-9_]', '_', 'g'));
  t   text;
  d   record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'fdw_' || p_alias) THEN
    RAISE EXCEPTION 'Database % non definito (api_admin.database)', p_alias;
  END IF;
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION prosit_api_owner', loc);
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', loc);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO api_lettore, api_scrittore', loc);
  EXECUTE format('GRANT CREATE ON SCHEMA %I TO api_scrittore', loc);
  FOREACH t IN ARRAY p_tabelle LOOP
    EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.%I CASCADE', loc, t);
  END LOOP;
  SET LOCAL ROLE api_scrittore;
  EXECUTE format('IMPORT FOREIGN SCHEMA %I LIMIT TO (%s) FROM SERVER %I INTO %I',
                 p_schema, (SELECT string_agg(format('%I', x), ', ') FROM unnest(p_tabelle) x),
                 'fdw_' || p_alias, loc);
  -- default del database di origine (vedi api_fn.prossimo_valore)
  FOR d IN
    SELECT * FROM dblink('fdw_' || p_alias, format($q$
      SELECT c.relname::text, a.attname::text, pg_get_expr(ad.adbin, ad.adrelid),
             pg_get_serial_sequence(format('%%I.%%I', n.nspname, c.relname), a.attname)
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
       WHERE n.nspname = %L AND c.relname = ANY (%L::text[]) AND a.attnum > 0 AND NOT a.attisdropped
         AND (ad.adbin IS NOT NULL OR a.attidentity <> '') AND a.attgenerated = ''
    $q$, p_schema, p_tabelle)) AS x(tabella text, colonna text, espressione text, sequenza text)
  LOOP
    IF to_regclass(format('%I.%I', loc, d.tabella)) IS NULL THEN
      CONTINUE;
    END IF;
    IF d.sequenza IS NOT NULL THEN
      RESET ROLE;
      INSERT INTO api_auth.sequenze (server, sequenza) VALUES ('fdw_' || p_alias, d.sequenza) ON CONFLICT DO NOTHING;
      SET LOCAL ROLE api_scrittore;
      EXECUTE format('ALTER FOREIGN TABLE %I.%I ALTER COLUMN %I SET DEFAULT api_fn.prossimo_valore(%L, %L)',
                     loc, d.tabella, d.colonna, 'fdw_' || p_alias, d.sequenza);
    ELSE
      BEGIN
        EXECUTE format('ALTER FOREIGN TABLE %I.%I ALTER COLUMN %I SET DEFAULT %s', loc, d.tabella, d.colonna, d.espressione);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Default di %.%.% non riproducibile in locale (%): in inserimento la colonna va valorizzata',
          p_schema, d.tabella, d.colonna, d.espressione;
      END;
    END IF;
  END LOOP;
  RESET ROLE;
  FOREACH t IN ARRAY p_tabelle LOOP
    IF to_regclass(format('%I.%I', loc, t)) IS NULL THEN
      RAISE WARNING 'Non trovata sul database esterno %: %.% (controllare nome e permessi di prosit_rw)', p_alias, p_schema, t;
    ELSE
      EXECUTE format('REVOKE ALL ON %I.%I FROM PUBLIC', loc, t);
      EXECUTE format('GRANT SELECT ON %I.%I TO api_lettore', loc, t);
    END IF;
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- Risorsa = vista api.<nome> su una tabella esterna + GRANT ai gruppi
--
-- {
--   "nome": "tvcc-log",                       nome pubblico (kebab-case) -> vista api.tvcc_log
--   "sorgente": "segn.audit.daily_log_tvcc",  alias.schema.tabella
--   "descrizione": "...",
--   "colonne": [...] | "escludi": [...],      colonne esposte
--   "filtro": "manteiner = ...",              condizione SQL sulle righe (puo' usare api_fn.*)
--   "lettura": ["tvcc"], "inserimento": [...], "modifica": [...], "cancellazione": [...],
--   "scrivibili": ["note"],                   colonne che il client puo' inviare in inserimento
--   "modificabili": [...],                    colonne modificabili (predefinito: scrivibili)
--   "forzati": {"insert_by": "utente.nome"}   valori messi dal database (il client non puo' inviarli)
--   "chiave": "id"                            colonna identificativa (serve a modifica/cancellazione)
-- }
-- Gruppi: "utenti" = qualunque utente autenticato; altrimenti il nome di api_admin.gruppo().
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE api_admin.risorsa(p jsonb)
LANGUAGE plpgsql AS $$
DECLARE
  v_nome   text := p ->> 'nome';
  v_vista  text := replace(p ->> 'nome', '-', '_');
  v_src    text[] := string_to_array(p ->> 'sorgente', '.');
  v_ft     text;
  v_ftreg  regclass;
  v_cols   text[];
  v_tutte  text[];
  v_scriv  text[] := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p -> 'scrivibili', '[]')));
  v_modif  text[] := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p -> 'modificabili', p -> 'scrivibili', '[]')));
  v_chiave text := p ->> 'chiave';
  v_filtro text := NULLIF(trim(COALESCE(p ->> 'filtro', '')), '');
  v_scrive boolean;
  v_owner  text;
  v_sql    text;
  op       text;
  g        text;
  r        text;
  c        text;
  f        record;
  v_expr   text;
  v_bad    text[];
BEGIN
  IF v_nome IS NULL OR v_nome !~ '^[a-z][a-z0-9-]{0,62}$' THEN
    RAISE EXCEPTION 'Nome risorsa non valido: % (minuscole, cifre, trattino)', v_nome;
  END IF;
  IF v_vista IN ('chiavi', 'risorse') THEN
    RAISE EXCEPTION 'Nome risorsa riservato: %', v_nome;
  END IF;
  IF cardinality(v_src) <> 3 THEN
    RAISE EXCEPTION 'Risorsa %: sorgente deve essere alias.schema.tabella', v_nome;
  END IF;
  v_ft := format('%I.%I', 'fdw_' || v_src[1] || '_' || lower(regexp_replace(v_src[2], '[^A-Za-z0-9_]', '_', 'g')), v_src[3]);
  v_ftreg := to_regclass(v_ft);
  IF v_ftreg IS NULL THEN
    RAISE EXCEPTION 'Risorsa %: tabella esterna % non importata (api_admin.importa)', v_nome, v_ft;
  END IF;

  SELECT array_agg(attname::text ORDER BY attnum) INTO v_tutte
    FROM pg_attribute WHERE attrelid = v_ftreg AND attnum > 0 AND NOT attisdropped;
  IF p ? 'colonne' THEN
    v_cols := ARRAY(SELECT jsonb_array_elements_text(p -> 'colonne'));
  ELSE
    v_cols := ARRAY(SELECT x FROM unnest(v_tutte) WITH ORDINALITY u(x, n)
                     WHERE x <> ALL (ARRAY(SELECT jsonb_array_elements_text(COALESCE(p -> 'escludi', '[]')))) ORDER BY n);
  END IF;
  SELECT array_agg(x) INTO v_bad FROM unnest(v_cols || v_scriv || v_modif || COALESCE(ARRAY[v_chiave], '{}')
                                     || ARRAY(SELECT jsonb_object_keys(COALESCE(p -> 'forzati', '{}')))) x
   WHERE x IS NOT NULL AND x <> ALL (v_tutte);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Risorsa %: colonne inesistenti in %: %', v_nome, v_ft, array_to_string(v_bad, ', ');
  END IF;
  SELECT array_agg(x) INTO v_bad FROM unnest(v_scriv || v_modif || ARRAY(SELECT jsonb_object_keys(COALESCE(p -> 'forzati', '{}')))) x
   WHERE x <> ALL (v_cols);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Risorsa %: colonne scrivibili/forzate non esposte dalla vista: %', v_nome, array_to_string(v_bad, ', ');
  END IF;
  SELECT array_agg(x) INTO v_bad FROM jsonb_object_keys(COALESCE(p -> 'forzati', '{}')) x WHERE x = ANY (v_scriv || v_modif);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Risorsa %: una colonna forzata non puo'' essere anche scrivibile: %', v_nome, array_to_string(v_bad, ', ');
  END IF;

  v_scrive := jsonb_array_length(COALESCE(p -> 'inserimento', '[]')) + jsonb_array_length(COALESCE(p -> 'modifica', '[]'))
            + jsonb_array_length(COALESCE(p -> 'cancellazione', '[]')) > 0;
  IF jsonb_array_length(COALESCE(p -> 'inserimento', '[]')) > 0 AND cardinality(v_scriv) = 0 THEN
    RAISE EXCEPTION 'Risorsa %: inserimento senza colonne "scrivibili"', v_nome;
  END IF;
  IF jsonb_array_length(COALESCE(p -> 'modifica', '[]')) > 0 AND cardinality(v_modif) = 0 THEN
    RAISE EXCEPTION 'Risorsa %: modifica senza colonne "modificabili"', v_nome;
  END IF;
  IF (jsonb_array_length(COALESCE(p -> 'modifica', '[]')) + jsonb_array_length(COALESCE(p -> 'cancellazione', '[]'))) > 0
     AND v_chiave IS NULL THEN
    RAISE EXCEPTION 'Risorsa %: modifica/cancellazione richiedono "chiave"', v_nome;
  END IF;
  v_owner := CASE WHEN v_scrive THEN 'api_scrittore' ELSE 'api_lettore' END;

  -- vista
  EXECUTE format('DROP VIEW IF EXISTS api.%I', v_vista);
  v_sql := format('CREATE VIEW api.%I WITH (security_barrier = true) AS SELECT %s FROM %s',
                  v_vista, (SELECT string_agg(format('%I', x), ', ') FROM unnest(v_cols) x), v_ft);
  IF v_filtro IS NOT NULL THEN
    v_sql := v_sql || ' WHERE (' || v_filtro || ')';
    IF v_scrive THEN
      v_sql := v_sql || ' WITH CASCADED CHECK OPTION';
    END IF;
  END IF;
  EXECUTE v_sql;
  EXECUTE format('ALTER VIEW api.%I OWNER TO %I', v_vista, v_owner);
  EXECUTE format('COMMENT ON VIEW api.%I IS %L', v_vista, COALESCE(p ->> 'descrizione', v_nome));

  -- valori forzati dal database
  FOR f IN SELECT key, value FROM jsonb_each(COALESCE(p -> 'forzati', '{}')) LOOP
    v_expr := CASE
      WHEN jsonb_typeof(f.value) = 'string' AND f.value #>> '{}' = 'utente.login' THEN 'api_fn.login()'
      WHEN jsonb_typeof(f.value) = 'string' AND f.value #>> '{}' = 'utente.nome'  THEN 'api_fn.nome()'
      WHEN jsonb_typeof(f.value) = 'string' AND f.value #>> '{}' = 'utente.email' THEN 'api_fn.email()'
      WHEN jsonb_typeof(f.value) = 'string' AND f.value #>> '{}' = 'adesso'       THEN 'now()'
      WHEN jsonb_typeof(f.value) = 'string' AND f.value #>> '{}' = 'oggi'         THEN 'current_date'
      WHEN jsonb_typeof(f.value) = 'object' AND f.value ? 'valore'                 THEN quote_literal(f.value ->> 'valore')
      ELSE NULL END;
    IF v_expr IS NULL THEN
      RAISE EXCEPTION 'Risorsa %: valore forzato non riconosciuto per %: % (utente.login, utente.nome, utente.email, adesso, oggi, {"valore": ...})',
        v_nome, f.key, f.value;
    END IF;
    EXECUTE format('ALTER VIEW api.%I ALTER COLUMN %I SET DEFAULT %s', v_vista, f.key, v_expr);
  END LOOP;

  -- permessi: nulla a PUBLIC, solo ai ruoli di gruppo indicati
  EXECUTE format('REVOKE ALL ON api.%I FROM PUBLIC', v_vista);
  FOREACH op IN ARRAY ARRAY['lettura', 'inserimento', 'modifica', 'cancellazione'] LOOP
    FOR g IN SELECT jsonb_array_elements_text(COALESCE(p -> op, '[]')) LOOP
      r := 'grp_' || g;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) OR (r <> 'grp_utenti' AND NOT EXISTS (SELECT 1 FROM api_auth.gruppi WHERE ruolo = r)) THEN
        RAISE EXCEPTION 'Risorsa %: gruppo sconosciuto "%" (definirlo in "gruppi")', v_nome, g;
      END IF;
      IF op = 'lettura' THEN
        EXECUTE format('GRANT SELECT ON api.%I TO %I', v_vista, r);
      ELSIF op = 'inserimento' THEN
        EXECUTE format('GRANT INSERT (%s) ON api.%I TO %I', (SELECT string_agg(format('%I', x), ', ') FROM unnest(v_scriv) x), v_vista, r);
      ELSIF op = 'modifica' THEN
        EXECUTE format('GRANT UPDATE (%s) ON api.%I TO %I', (SELECT string_agg(format('%I', x), ', ') FROM unnest(v_modif) x), v_vista, r);
        EXECUTE format('GRANT SELECT (%I) ON api.%I TO %I', v_chiave, v_vista, r);
      ELSE
        EXECUTE format('GRANT DELETE ON api.%I TO %I', v_vista, r);
        EXECUTE format('GRANT SELECT (%I) ON api.%I TO %I', v_chiave, v_vista, r);
      END IF;
    END LOOP;
  END LOOP;

  INSERT INTO api_auth.risorse (nome, vista, descrizione, definizione, aggiornata)
  VALUES (v_nome, v_vista, p ->> 'descrizione', p, now())
  ON CONFLICT (nome) DO UPDATE SET vista = EXCLUDED.vista, descrizione = EXCLUDED.descrizione,
                                   definizione = EXCLUDED.definizione, aggiornata = now();
END $$;

CREATE OR REPLACE PROCEDURE api_admin.rimuovi_risorsa(p_nome text)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP VIEW IF EXISTS api.%I', replace(p_nome, '-', '_'));
  DELETE FROM api_auth.risorse WHERE nome = p_nome;
END $$;

-- ----------------------------------------------------------------------------
-- Catalogo (per generare la documentazione OpenAPI dal database reale)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_admin.catalogo() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH grp AS (
    SELECT rolname FROM pg_roles WHERE rolname LIKE 'grp\_%'
  ), ris AS (
    SELECT r.nome, r.vista, r.descrizione, r.definizione,
      (SELECT jsonb_agg(jsonb_build_object(
          'nome', a.attname,
          'tipo', format_type(a.atttypid, a.atttypmod),
          'categoria', t.typcategory,
          'udt', t.typname,
          'forzata', COALESCE(r.definizione -> 'forzati' ? a.attname::text, false),
          'scrivibile', COALESCE((r.definizione -> 'scrivibili') ? a.attname::text, false),
          'modificabile', COALESCE((COALESCE(r.definizione -> 'modificabili', r.definizione -> 'scrivibili')) ? a.attname::text, false)
        ) ORDER BY a.attnum)
         FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
        WHERE a.attrelid = format('api.%I', r.vista)::regclass AND a.attnum > 0 AND NOT a.attisdropped) AS colonne,
      jsonb_build_object(
        'lettura', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]') FROM grp
                     WHERE has_any_column_privilege(rolname, format('api.%I', r.vista), 'SELECT')
                       AND has_table_privilege(rolname, format('api.%I', r.vista), 'SELECT')),
        'inserimento', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]') FROM grp
                     WHERE has_any_column_privilege(rolname, format('api.%I', r.vista), 'INSERT')),
        'modifica', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]') FROM grp
                     WHERE has_any_column_privilege(rolname, format('api.%I', r.vista), 'UPDATE')),
        'cancellazione', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]') FROM grp
                     WHERE has_table_privilege(rolname, format('api.%I', r.vista), 'DELETE'))
      ) AS permessi
    FROM api_auth.risorse r
    WHERE to_regclass(format('api.%I', r.vista)) IS NOT NULL
  )
  SELECT jsonb_build_object(
    'risorse', (SELECT COALESCE(jsonb_agg(to_jsonb(ris) ORDER BY nome), '[]') FROM ris),
    'funzioni', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'nome', p.proname,
        'argomenti', pg_get_function_arguments(p.oid),
        'risultato', pg_get_function_result(p.oid),
        'volatilita', p.provolatile,
        'descrizione', obj_description(p.oid, 'pg_proc'),
        'gruppi', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]') FROM grp
                    WHERE has_function_privilege(rolname, p.oid, 'EXECUTE'))
      ) ORDER BY p.proname), '[]')
      FROM pg_proc p WHERE p.pronamespace = 'api'::regnamespace AND p.prokind = 'f'),
    'gruppi', (SELECT COALESCE(jsonb_agg(jsonb_build_object('ruolo', ruolo, 'lizmap', lizmap, 'descrizione', descrizione) ORDER BY ruolo), '[]')
                 FROM api_auth.gruppi)
  )
$$;

-- ----------------------------------------------------------------------------
-- Manutenzione
-- ----------------------------------------------------------------------------
-- Audit: conservazione (predefinito 365 giorni)
CREATE OR REPLACE PROCEDURE api_admin.pulisci_audit(p_giorni integer DEFAULT 365)
LANGUAGE sql AS $$
  DELETE FROM api_auth.audit WHERE ts < now() - make_interval(days => p_giorni);
$$;

-- Ruoli lz_* di utenti che non usano le API da N giorni.
-- Il ruolo viene ricreato da solo al prossimo accesso.
CREATE OR REPLACE PROCEDURE api_admin.pulisci_utenti(p_giorni integer DEFAULT 180)
LANGUAGE plpgsql AS $$
DECLARE
  u record;
BEGIN
  FOR u IN SELECT * FROM api_auth.utenti x WHERE x.ultimo_accesso < now() - make_interval(days => p_giorni) LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = u.ruolo) THEN
      EXECUTE format('DROP ROLE %I', u.ruolo);
    END IF;
    DELETE FROM api_auth.utenti WHERE login = u.login;
    RAISE NOTICE 'Rimosso utente API inattivo: %', u.login;
  END LOOP;
END $$;

-- Controlli di sicurezza: deve restituire zero righe con esito 'ERRORE'
CREATE OR REPLACE FUNCTION api_admin.verifica()
RETURNS TABLE (esito text, controllo text, dettaglio text)
LANGUAGE sql STABLE AS $$
  -- funzioni esposte eseguibili da chiunque
  SELECT 'ERRORE', 'funzione eseguibile da PUBLIC', p.oid::regprocedure::text
    FROM pg_proc p
   WHERE p.pronamespace IN ('api'::regnamespace, 'api_auth'::regnamespace, 'api_fn'::regnamespace, 'api_admin'::regnamespace)
     AND has_function_privilege('public', p.oid, 'EXECUTE')
     AND p.prokind = 'f'
  UNION ALL
  -- viste/tabelle con permessi a PUBLIC o al ruolo anonimo
  SELECT 'ERRORE', 'oggetto accessibile a PUBLIC/web_anon', c.oid::regclass::text
    FROM pg_class c
   WHERE c.relnamespace IN ('api'::regnamespace, 'api_auth'::regnamespace)
     AND c.relkind IN ('r', 'v', 'f', 'm')
     AND (has_table_privilege('web_anon', c.oid, 'SELECT') OR has_table_privilege('web_anon', c.oid, 'INSERT')
          OR has_any_column_privilege('web_anon', c.oid, 'SELECT'))
  UNION ALL
  SELECT 'ERRORE', 'tabella esterna accessibile agli utenti', c.oid::regclass::text
    FROM pg_class c
   WHERE c.relkind = 'f' AND has_any_column_privilege('grp_utenti', c.oid, 'SELECT')
  UNION ALL
  SELECT 'ERRORE', 'authenticator con privilegi elevati', rolname
    FROM pg_roles WHERE rolname = 'authenticator' AND (rolsuper OR rolinherit OR rolcreaterole OR rolcreatedb OR rolbypassrls)
  UNION ALL
  SELECT 'ERRORE', 'ruolo utente con LOGIN o privilegi', rolname
    FROM pg_roles WHERE (rolname LIKE 'lz\_%' OR rolname LIKE 'grp\_%') AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls)
  UNION ALL
  SELECT 'ERRORE', 'vista api con SECURITY INVOKER (userebbe la user mapping dell''utente)', c.oid::regclass::text
    FROM pg_class c
   WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
     AND COALESCE(c.reloptions, '{}') && ARRAY['security_invoker=true', 'security_invoker=on']
  UNION ALL
  SELECT 'AVVISO', 'risorsa registrata senza vista', nome FROM api_auth.risorse WHERE to_regclass(format('api.%I', vista)) IS NULL
  UNION ALL
  SELECT 'OK', 'controlli completati', to_char(now(), 'YYYY-MM-DD HH24:MI')
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api_admin FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA api_admin FROM PUBLIC;

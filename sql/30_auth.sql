-- ============================================================================
-- PROSIT API v2 — UTENTI, RUOLI, AUDIT (da superuser, \connect api)
-- ============================================================================
-- Flusso
--   1. Il modulo Lizmap "prositapi" riconosce l'utente con jAuth di Lizmap:
--      sessione del browser, oppure HTTP Basic per i programmi (utenti tecnici con il
--      diritto "prosit.api.programmi", assegnato dal pannello Amministrazione di Lizmap).
--   2. Chiama api_auth.gateway_utente(): l'utente ha un suo ruolo PostgreSQL
--      (lz_<login>_<hash>) membro di grp_utenti e dei grp_* che corrispondono ai suoi
--      gruppi Lizmap (tabella api_auth.gruppi). L'appartenenza viene riallineata ogni volta.
--   3. Il modulo firma un token di 60 secondi (libreria firebase/php-jwt) con role = quel
--      ruolo e lo passa a PostgREST, che esegue la richiesta con SET ROLE:
--      i permessi sono i GRANT di PostgreSQL.
--   4. api_fn.pre_request() (db-pre-request) controlla l'emittente e registra le modifiche.
-- ============================================================================
\set ON_ERROR_STOP on


CREATE TABLE IF NOT EXISTS api_auth.impostazioni (
  chiave     text PRIMARY KEY,
  valore     jsonb NOT NULL,
  aggiornata timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE api_auth.impostazioni IS 'Parametri (generati da config/api.yaml)';

CREATE TABLE IF NOT EXISTS api_auth.gruppi (
  ruolo       name PRIMARY KEY CHECK (ruolo ~ '^grp_[a-z0-9_]{1,59}$'),
  lizmap      text[] NOT NULL,          -- id o nomi dei gruppi Lizmap che danno questo ruolo
  descrizione text
);
COMMENT ON TABLE api_auth.gruppi IS 'Corrispondenza gruppi Lizmap -> ruoli PostgreSQL (generata da config/api.yaml)';

CREATE TABLE IF NOT EXISTS api_auth.utenti (
  login          text PRIMARY KEY CHECK (length(login) BETWEEN 1 AND 100),
  ruolo          name NOT NULL UNIQUE CHECK (ruolo ~ '^lz_[a-z0-9_]+$'),
  nome           text,
  email          text,
  gruppi_lizmap  text[] NOT NULL DEFAULT '{}',
  ruoli          text[] NOT NULL DEFAULT '{}',
  primo_accesso  timestamptz NOT NULL DEFAULT now(),
  ultimo_accesso timestamptz NOT NULL DEFAULT now(),
  ultimo_tipo    text
);
COMMENT ON TABLE api_auth.utenti IS 'Utenti Lizmap che hanno usato le API e il loro ruolo PostgreSQL';

CREATE TABLE IF NOT EXISTS api_auth.audit (
  id           bigserial PRIMARY KEY,
  ts           timestamptz NOT NULL DEFAULT now(),
  login        text,
  ruolo        text,
  tipo_accesso text,
  metodo       text,
  percorso     text,
  request_id   text
);
CREATE INDEX IF NOT EXISTS audit_ts_idx ON api_auth.audit (ts);
CREATE INDEX IF NOT EXISTS audit_login_idx ON api_auth.audit (login, ts);
COMMENT ON TABLE api_auth.audit IS 'Modifiche riuscite fatte tramite API (POST/PATCH/DELETE). Conservazione: api_admin.pulisci_audit()';

CREATE TABLE IF NOT EXISTS api_auth.risorse (
  nome        text PRIMARY KEY,              -- nome pubblico (kebab-case), es. tvcc-log
  vista       name NOT NULL UNIQUE,          -- vista in schema api, es. tvcc_log
  descrizione text,
  definizione jsonb NOT NULL,
  aggiornata  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE api_auth.impostazioni OWNER TO prosit_api_owner;
ALTER TABLE api_auth.gruppi       OWNER TO prosit_api_owner;
ALTER TABLE api_auth.utenti       OWNER TO prosit_api_owner;
ALTER TABLE api_auth.audit        OWNER TO prosit_api_owner;
ALTER TABLE api_auth.risorse      OWNER TO prosit_api_owner;
REVOKE ALL ON ALL TABLES IN SCHEMA api_auth FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA api_auth FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON api_auth.utenti TO api_rolemgr;
GRANT SELECT ON api_auth.gruppi, api_auth.impostazioni TO api_rolemgr;

INSERT INTO api_auth.impostazioni (chiave, valore) VALUES ('ruoli.statement_timeout', '"30s"')
ON CONFLICT (chiave) DO NOTHING;

CREATE OR REPLACE FUNCTION api_auth.impostazione(p_chiave text, p_predefinito jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT COALESCE((SELECT valore FROM api_auth.impostazioni WHERE chiave = p_chiave), p_predefinito)
$$;
ALTER FUNCTION api_auth.impostazione(text, jsonb) OWNER TO prosit_api_owner;
REVOKE ALL ON FUNCTION api_auth.impostazione(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_auth.impostazione(text, jsonb) TO api_rolemgr, api_scrittore, api_lettore;

-- ----------------------------------------------------------------------------
-- 1. Allineamento utente -> ruolo PostgreSQL (chiamata dal modulo Lizmap a ogni richiesta)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_auth.gateway_utente(
  p_login text, p_nome text, p_email text, p_gruppi text[], p_tipo text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_login   text := trim(COALESCE(p_login, ''));
  v_gruppi  text[];
  v_ruolo   text;
  v_target  text[];
  v_attuali text[];
  v_riga    api_auth.utenti%ROWTYPE;
  r         text;
BEGIN
  IF v_login = '' OR length(v_login) > 100 OR v_login ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'login non valido';
  END IF;
  IF p_tipo NOT IN ('sessione', 'programma') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'tipo di accesso non valido';
  END IF;
  IF cardinality(COALESCE(p_gruppi, '{}')) > 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'troppi gruppi';
  END IF;
  SELECT COALESCE(array_agg(DISTINCT lower(trim(g)) ORDER BY lower(trim(g))) FILTER (WHERE trim(g) <> ''), '{}')
    INTO v_gruppi FROM unnest(COALESCE(p_gruppi, '{}')) g;

  -- una richiesta alla volta per lo stesso utente (creazione ruolo e GRANT)
  PERFORM pg_advisory_xact_lock(hashtextextended('prosit-api-utente:' || v_login, 0));

  SELECT * INTO v_riga FROM api_auth.utenti WHERE login = v_login;
  v_ruolo := v_riga.ruolo;
  IF v_ruolo IS NULL THEN
    v_ruolo := 'lz_' || left(regexp_replace(lower(v_login), '[^a-z0-9_]', '_', 'g'), 40)
               || '_' || left(md5(v_login), 6);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_ruolo) THEN
    EXECUTE format('CREATE ROLE %I NOLOGIN INHERIT', v_ruolo);
    EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', v_ruolo,
                   api_auth.impostazione('ruoli.statement_timeout', '"30s"') #>> '{}');
    EXECUTE format('GRANT %I TO authenticator', v_ruolo);
  END IF;

  -- ruoli che l'utente deve avere ora
  SELECT array_agg(x ORDER BY x) INTO v_target FROM (
    SELECT 'grp_utenti'::text AS x
    UNION
    SELECT g.ruolo::text FROM api_auth.gruppi g
     WHERE EXISTS (SELECT 1 FROM unnest(g.lizmap) l WHERE lower(trim(l)) = ANY (v_gruppi))
  ) t;

  -- ruoli di gruppo che ha adesso (solo quelli gestiti: grp_*)
  SELECT COALESCE(array_agg(DISTINCT b.rolname::text), '{}') INTO v_attuali
    FROM pg_auth_members m
    JOIN pg_roles u ON u.oid = m.member
    JOIN pg_roles b ON b.oid = m.roleid
   WHERE u.rolname = v_ruolo AND b.rolname LIKE 'grp\_%';

  FOREACH r IN ARRAY v_target LOOP
    IF NOT r = ANY (v_attuali) THEN
      -- INHERIT: l'utente ha i permessi del gruppo; SET FALSE: nessuno puo' fare SET ROLE al gruppo
      EXECUTE format('GRANT %I TO %I WITH INHERIT TRUE, SET FALSE', r, v_ruolo);
    END IF;
  END LOOP;
  FOREACH r IN ARRAY v_attuali LOOP
    IF NOT r = ANY (v_target) THEN
      EXECUTE format('REVOKE %I FROM %I', r, v_ruolo);
    END IF;
  END LOOP;

  IF v_riga.login IS NULL THEN
    INSERT INTO api_auth.utenti (login, ruolo, nome, email, gruppi_lizmap, ruoli, ultimo_tipo)
    VALUES (v_login, v_ruolo, NULLIF(p_nome, ''), NULLIF(p_email, ''), v_gruppi, v_target, p_tipo);
  ELSIF v_riga.gruppi_lizmap IS DISTINCT FROM v_gruppi OR v_riga.ruoli IS DISTINCT FROM v_target
     OR v_riga.nome IS DISTINCT FROM NULLIF(p_nome, '') OR v_riga.email IS DISTINCT FROM NULLIF(p_email, '')
     OR v_riga.ultimo_tipo IS DISTINCT FROM p_tipo OR v_riga.ultimo_accesso < now() - interval '5 minutes' THEN
    UPDATE api_auth.utenti
       SET nome = NULLIF(p_nome, ''), email = NULLIF(p_email, ''), gruppi_lizmap = v_gruppi,
           ruoli = v_target, ultimo_accesso = now(), ultimo_tipo = p_tipo
     WHERE login = v_login;
  END IF;
  RETURN v_ruolo;
END $$;
ALTER FUNCTION api_auth.gateway_utente(text, text, text, text[], text) OWNER TO api_rolemgr;
REVOKE ALL ON FUNCTION api_auth.gateway_utente(text, text, text, text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_auth.gateway_utente(text, text, text, text[], text) TO api_gateway;

-- ----------------------------------------------------------------------------
-- 2. db-pre-request di PostgREST: controllo dell'emittente e audit delle modifiche
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_fn.pre_request() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  c      jsonb := api_fn.claims();
  metodo text  := upper(COALESCE(NULLIF(current_setting('request.method', true), ''), 'GET'));
BEGIN
  IF c ->> 'iss' IS DISTINCT FROM 'prosit-lizmap' OR COALESCE(c ->> 'sub', '') = '' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Accesso consentito solo tramite Lizmap.';
  END IF;
  IF metodo NOT IN ('GET', 'HEAD', 'OPTIONS') THEN
    INSERT INTO api_auth.audit (login, ruolo, tipo_accesso, metodo, percorso, request_id)
    VALUES (c ->> 'sub', current_setting('role', true), c ->> 'auth', metodo,
            left(COALESCE(current_setting('request.path', true), ''), 300),
            left(current_setting('request.headers', true)::json ->> 'x-request-id', 64));
  END IF;
END $$;
ALTER FUNCTION api_fn.pre_request() OWNER TO prosit_api_owner;
REVOKE ALL ON FUNCTION api_fn.pre_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_fn.pre_request() TO grp_utenti;

-- ----------------------------------------------------------------------------
-- 3. Funzioni e viste ESPOSTE (schema api)
-- ----------------------------------------------------------------------------

-- GET /rpc/io : chi sono, con quali ruoli PostgreSQL, come mi sono autenticato
CREATE OR REPLACE FUNCTION api.io() RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object(
    'login', api_fn.login(),
    'nome', api_fn.nome(),
    'email', api_fn.email(),
    'tipo_accesso', api_fn.tipo_accesso(),
    'gruppi_lizmap', COALESCE(api_fn.claims() -> 'gruppi', '[]'::jsonb),
    'ruoli', (SELECT COALESCE(jsonb_agg(substr(rolname, 5) ORDER BY rolname), '[]'::jsonb)
                FROM pg_roles WHERE rolname LIKE 'grp\_%' AND pg_has_role(current_user, oid, 'MEMBER')),
    'token_scade', to_timestamp((api_fn.claims() ->> 'exp')::double precision)
  )
$$;
COMMENT ON FUNCTION api.io() IS 'Utente corrente, gruppi Lizmap, ruoli PostgreSQL e tipo di accesso';

-- GET /risorse : risorse e operazioni consentite all'utente corrente (dai GRANT)
DROP VIEW IF EXISTS api.risorse;
CREATE VIEW api.risorse AS
  SELECT r.nome, r.descrizione, r.definizione ->> 'chiave' AS chiave, ops.operazioni
    FROM api_auth.risorse r
    CROSS JOIN LATERAL (
      SELECT array_remove(ARRAY[
        CASE WHEN has_any_column_privilege(current_user, format('api.%I', r.vista), 'SELECT') THEN 'lettura' END,
        CASE WHEN has_any_column_privilege(current_user, format('api.%I', r.vista), 'INSERT') THEN 'inserimento' END,
        CASE WHEN has_any_column_privilege(current_user, format('api.%I', r.vista), 'UPDATE') THEN 'modifica' END,
        CASE WHEN has_table_privilege(current_user, format('api.%I', r.vista), 'DELETE') THEN 'cancellazione' END
      ], NULL) AS operazioni
    ) ops
   WHERE to_regclass(format('api.%I', r.vista)) IS NOT NULL
     AND cardinality(ops.operazioni) > 0;
COMMENT ON VIEW api.risorse IS 'Risorse accessibili all''utente corrente e operazioni consentite';

ALTER FUNCTION api.io() OWNER TO prosit_api_owner;
ALTER VIEW api.risorse OWNER TO prosit_api_owner;
REVOKE ALL ON FUNCTION api.io() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.io() TO grp_utenti;
REVOKE ALL ON api.risorse FROM PUBLIC;
GRANT SELECT ON api.risorse TO grp_utenti;

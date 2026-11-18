-- ============================================================================
-- PROSIT API v2 — FUNZIONI DEI SERVIZI (da superuser, \connect api)
-- ============================================================================
-- Operazioni che non sono un semplice CRUD su una tabella, esposte come RPC:
--   POST /rpc/segnalazione-mail          (ex POST /v1/segnalazioni/{id}/mail)
--   GET  /rpc/calendario-contesto        (ex GET  /v1/calendario/context)
--   GET  /rpc/calendario-interventi      (ex GET  /v1/calendario/interventi)
--   POST /rpc/calendario-crea            (ex POST /v1/calendario/interventi)
--   POST /rpc/calendario-modifica        (ex PATCH /v1/calendario/interventi)
--   POST /rpc/calendario-elimina         (ex DELETE /v1/calendario/interventi)
-- Il gateway traduce i nomi kebab-case dell'URL in snake_case (calendario_crea).
--
-- Tutte SECURITY DEFINER di api_scrittore: leggono e scrivono le tabelle esterne con
-- la user mapping di prosit_rw; chi le puo' chiamare lo decidono i GRANT EXECUTE
-- in fondo al file. Le tabelle esterne servono gia' importate (sezione "importa"
-- di config/api.yaml).
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Appoggio: nome locale della tabella esterna da 'alias.schema.tabella'
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_auth.tabella_esterna(p_sorgente text) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
  s text[] := string_to_array(p_sorgente, '.');
  t text;
BEGIN
  IF cardinality(s) <> 3 THEN
    RAISE EXCEPTION 'sorgente non valida: %', p_sorgente;
  END IF;
  t := format('%I.%I', 'fdw_' || s[1] || '_' || lower(regexp_replace(s[2], '[^A-Za-z0-9_]', '_', 'g')), s[3]);
  IF to_regclass(t) IS NULL THEN
    RAISE EXCEPTION 'tabella esterna non importata: % (config/api.yaml -> importa)', p_sorgente;
  END IF;
  RETURN t;
END $$;

-- tipo SQL di una colonna (per inserire valori con il cast giusto qualunque sia il tipo remoto)
CREATE OR REPLACE FUNCTION api_auth.tipo_colonna(p_tabella text, p_colonna text) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
   WHERE a.attrelid = p_tabella::regclass AND a.attname = p_colonna AND NOT a.attisdropped
$$;

-- ============================================================================
-- MAIL DEL TICKET
-- ============================================================================
CREATE OR REPLACE FUNCTION api.segnalazione_mail(seg_id integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_id     integer := segnalazione_mail.seg_id;
  v_segn   text := api_auth.tabella_esterna('segn.segn.segn_id');
  v_login  text := api_auth.tabella_esterna('segn.administration.login_rekla_prosit');
  v_coda   text := api_auth.tabella_esterna('segn.audit.mail_queue');
  t        record;
  v_gruppi text[];
  v_dest   jsonb;
  v_email  text := api_fn.email();
  g        text;
BEGIN
  IF api_fn.tipo_accesso() IS DISTINCT FROM 'sessione' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'La mail del ticket si invia solo da Lizmap (sessione utente).';
  END IF;
  EXECUTE format('SELECT man_es, seg_i_rek_alias, seg_o_ogg, seg_o_desc, seg_l_ind, segn_ogg_gen, note_maintainer
                    FROM %s WHERE seg_id = $1', v_segn) INTO t USING v_id;
  IF t IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Segnalazione non trovata.';
  END IF;
  v_gruppi := ARRAY(SELECT lower(trim(x)) FROM unnest(string_to_array(COALESCE(t.man_es, ''), ',')) x WHERE trim(x) <> '');
  IF cardinality(v_gruppi) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'La segnalazione non ha un assegnatario (man_es).';
  END IF;
  FOREACH g IN ARRAY v_gruppi LOOP
    IF api_fn.in_gruppo_lizmap(g) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Sei nel gruppo assegnatario: la mail non serve.';
    END IF;
  END LOOP;
  IF v_email IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Il tuo utente Lizmap non ha un indirizzo email.';
  END IF;
  EXECUTE format('SELECT COALESCE(jsonb_agg(DISTINCT usr_email), ''[]'')
                    FROM %s WHERE lower(trim(id_aclgrp::text)) = ANY ($1)
                     AND usr_email IS NOT NULL AND usr_email <> ''''', v_login) INTO v_dest USING v_gruppi;
  IF jsonb_array_length(v_dest) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Nessun indirizzo email configurato per il gruppo assegnatario.';
  END IF;
  EXECUTE format('INSERT INTO %s (recipient, carbon_copy, subject, body, status, application, id_prosit)
                  VALUES ($1::%s, $2::%s, $3::%s, $4::%s, ''pending'', ''Rekla'', $5::%s)',
                 v_coda,
                 api_auth.tipo_colonna(v_coda, 'recipient'), api_auth.tipo_colonna(v_coda, 'carbon_copy'),
                 api_auth.tipo_colonna(v_coda, 'subject'), api_auth.tipo_colonna(v_coda, 'body'),
                 api_auth.tipo_colonna(v_coda, 'id_prosit'))
    USING v_dest::text, jsonb_build_array(v_email)::text,
          trim('Nuovo ticket ' || COALESCE(t.seg_o_ogg, '') || ' ' || COALESCE(t.seg_i_rek_alias, '')),
          jsonb_build_object('Materia', t.seg_o_ogg, 'Descrizione', t.seg_o_desc,
                             'Localizzazione', COALESCE(t.seg_l_ind, t.segn_ogg_gen),
                             'Nota da ufficio', t.note_maintainer)::text,
          v_id::text;
  RETURN jsonb_build_object('queued', true, 'id', v_id, 'recipients', jsonb_array_length(v_dest));
END $$;
COMMENT ON FUNCTION api.segnalazione_mail(integer) IS 'Mette in coda la mail del ticket verso il gruppo assegnatario (utente corrente in copia)';

-- ============================================================================
-- CALENDARIO INTERVENTI VERDE / STRADE
-- Configurazione: impostazione 'calendario' (sezione servizi.calendario di config/api.yaml)
-- ============================================================================
CREATE OR REPLACE FUNCTION api_auth.cal_cfg() RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT COALESCE(api_auth.impostazione('calendario'), '{}'::jsonb)
$$;

-- ruolo dell'utente nel calendario: admin | viewer | editor | none, gruppo editor e manutentore
CREATE OR REPLACE FUNCTION api_auth.cal_utente(OUT ruolo text, OUT gruppo_editor text, OUT manteiner text)
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
  c   jsonb := api_auth.cal_cfg();
  map jsonb := COALESCE(c -> 'group_manteiner', '{}');
  g   text;
BEGIN
  FOR g IN SELECT jsonb_array_elements_text(COALESCE(c -> 'editor_groups', '[]')) LOOP
    IF api_fn.in_gruppo_lizmap(g) AND map ? g THEN gruppo_editor := g; EXIT; END IF;
  END LOOP;
  IF gruppo_editor IS NULL THEN
    FOR g IN SELECT jsonb_object_keys(map) LOOP
      IF api_fn.in_gruppo_lizmap(g) THEN gruppo_editor := g; EXIT; END IF;
    END LOOP;
  END IF;
  manteiner := map ->> gruppo_editor;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(c -> 'admin_groups', '[]')) x WHERE api_fn.in_gruppo_lizmap(x)) THEN
    ruolo := 'admin';
  ELSIF EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(c -> 'viewers', '[]')) x WHERE api_fn.in_gruppo_lizmap(x)) THEN
    ruolo := 'viewer';
  ELSIF manteiner IS NOT NULL THEN
    ruolo := 'editor';
  ELSE
    ruolo := 'none';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION api_auth.cal_tabella(p_fonte text) RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
  src text := api_auth.cal_cfg() -> 'tab' ->> p_fonte;
BEGIN
  IF p_fonte NOT IN ('verde', 'strade') OR src IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Fonte non valida (verde | strade).';
  END IF;
  RETURN api_auth.tabella_esterna(src);
END $$;

-- GET /rpc/calendario-contesto
CREATE OR REPLACE FUNCTION api.calendario_contesto() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  u   record := api_auth.cal_utente();
  c   jsonb := api_auth.cal_cfg();
  all_ boolean;
BEGIN
  all_ := u.ruolo IN ('admin', 'viewer');
  RETURN jsonb_build_object(
    'login', api_fn.login(),
    'name', api_fn.nome(),
    'groups', COALESCE(api_fn.claims() -> 'gruppi', '[]'),
    'role', u.ruolo,
    'manteiner', u.manteiner,
    'isEditor', u.ruolo IN ('admin', 'editor'),
    'seeAll', all_,
    'filterGroups', CASE WHEN all_ THEN COALESCE(c -> 'data_groups', '[]')
                         WHEN u.gruppo_editor IS NOT NULL THEN jsonb_build_array(u.gruppo_editor)
                         ELSE '[]'::jsonb END,
    'editor_group', u.gruppo_editor,
    'tipi_fonte', COALESCE(c -> 'tipi_fonte', '{}'));
END $$;

-- GET /rpc/calendario-interventi?dal=2026-11-01&al=2026-11-30
CREATE OR REPLACE FUNCTION api.calendario_interventi(dal date DEFAULT NULL, al date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  u      record := api_auth.cal_utente();
  v_dal  date := COALESCE(calendario_interventi.dal, date_trunc('month', current_date)::date);
  v_al   date := COALESCE(calendario_interventi.al, (date_trunc('month', current_date) + interval '1 month - 1 day')::date);
  all_   boolean := u.ruolo IN ('admin', 'viewer');
  v_rows jsonb := '[]';
  part   jsonb;
  f      text;
BEGIN
  IF u.manteiner IS NULL AND NOT all_ THEN
    RETURN jsonb_build_object('manteiner', NULL, 'giorni', '{}'::jsonb);
  END IF;
  IF v_al < v_dal OR v_al - v_dal > 400 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Intervallo di date non valido (massimo 400 giorni).';
  END IF;
  FOREACH f IN ARRAY ARRAY['verde', 'strade'] LOOP
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(jsonb_build_object(
          ''id'', id, ''fonte'', %L, ''tipo'', ty_int, ''rif'', %s, ''strada'', %s, ''manteiner'', manteiner,
          ''eseguito'', COALESCE(execution::text IN (''true'', ''t'', ''1''), false),
          ''date_int'', date_int, ''date_int_ex'', date_int_ex, ''planned_int'', planned_int)), ''[]'')
         FROM %s WHERE date_int BETWEEN $1 AND $2 AND ($3 OR manteiner = $4)',
      f, CASE WHEN f = 'verde' THEN 'id_zona' ELSE 'NULL' END, CASE WHEN f = 'strade' THEN 'strada' ELSE 'NULL' END,
      api_auth.cal_tabella(f))
      INTO part USING v_dal, v_al, all_, u.manteiner;
    v_rows := v_rows || part;
  END LOOP;
  RETURN jsonb_build_object('manteiner', u.manteiner, 'giorni', COALESCE((
    SELECT jsonb_object_agg(d, jsonb_build_object('interventi', items))
      FROM (SELECT r ->> 'date_int' AS d, jsonb_agg(r - 'date_int' ORDER BY (r ->> 'id')::int) AS items
              FROM jsonb_array_elements(v_rows) r WHERE r ->> 'date_int' IS NOT NULL GROUP BY 1) x), '{}'::jsonb));
END $$;

-- POST /rpc/calendario-crea {"tipo":"potature siepi","data":"2026-11-02","id_zona":12,"ripeti":{"fino_a":"2026-11-30","giorni":[1,3]}}
-- (firma precedente, senza date_int_ex: va tolta, altrimenti PostgREST vedrebbe due funzioni)
DROP FUNCTION IF EXISTS api.calendario_crea(text, date, integer, text, boolean, jsonb);
CREATE OR REPLACE FUNCTION api.calendario_crea(
  tipo text, data date, id_zona integer DEFAULT NULL, strada text DEFAULT NULL,
  execution boolean DEFAULT false, ripeti jsonb DEFAULT NULL, date_int_ex date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  u      record := api_auth.cal_utente();
  c      jsonb := api_auth.cal_cfg();
  v_fonte text := c -> 'tipi_fonte' ->> calendario_crea.tipo;
  v_man  text;
  v_tab  text;
  v_date date[];
  v_fino date;
  v_gg   int[];
  d      date;
  v_ids  int[] := '{}';
  v_id   int;
  v_ex   boolean := COALESCE(calendario_crea.execution, false);
  v_rif  text;
  v_sql  text;
BEGIN
  IF u.ruolo NOT IN ('admin', 'editor') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Utente non abilitato all''inserimento.';
  END IF;
  v_man := COALESCE(u.manteiner, 'Manutentori interni');
  IF v_fonte IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Tipo intervento non gestito: ' || COALESCE(calendario_crea.tipo, '');
  END IF;
  IF calendario_crea.data IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Data obbligatoria.';
  END IF;
  IF v_fonte = 'verde' AND COALESCE(calendario_crea.id_zona, 0) <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Seleziona una zona/oggetto.';
  END IF;
  IF v_fonte = 'strade' AND COALESCE(trim(calendario_crea.strada), '') = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Seleziona una strada/oggetto.';
  END IF;
  -- date (ripetizione su giorni ISO 1=lun..7=dom, massimo 366)
  v_date := ARRAY[calendario_crea.data];
  IF jsonb_typeof(ripeti) = 'object' AND ripeti ? 'fino_a' THEN
    v_fino := (ripeti ->> 'fino_a')::date;
    v_gg := ARRAY(SELECT jsonb_array_elements_text(COALESCE(ripeti -> 'giorni', '[]'))::int);
    IF v_fino >= calendario_crea.data THEN
      v_date := ARRAY(SELECT g::date FROM generate_series(calendario_crea.data, v_fino, interval '1 day') g
                       WHERE cardinality(v_gg) = 0 OR extract(isodow FROM g)::int = ANY (v_gg) LIMIT 366);
      IF cardinality(v_date) = 0 THEN v_date := ARRAY[calendario_crea.data]; END IF;
    END IF;
  END IF;
  v_tab := api_auth.cal_tabella(v_fonte);
  v_rif := CASE WHEN v_fonte = 'verde' THEN 'id_zona' ELSE 'strada' END;
  -- i valori passano come testo con il cast al tipo reale della colonna remota
  v_sql := format('INSERT INTO %s (%I, ty_int, date_int, execution, date_int_ex, planned_int, manteiner)
                   VALUES ($1::%s, $2::%s, $3::%s, $4::%s, $5::%s, $6::%s, $7::%s) RETURNING id',
                  v_tab, v_rif,
                  api_auth.tipo_colonna(v_tab, v_rif), api_auth.tipo_colonna(v_tab, 'ty_int'),
                  api_auth.tipo_colonna(v_tab, 'date_int'), api_auth.tipo_colonna(v_tab, 'execution'),
                  api_auth.tipo_colonna(v_tab, 'date_int_ex'), api_auth.tipo_colonna(v_tab, 'planned_int'),
                  api_auth.tipo_colonna(v_tab, 'manteiner'));
  FOREACH d IN ARRAY v_date LOOP
    EXECUTE v_sql
      INTO v_id
      USING CASE WHEN v_fonte = 'verde' THEN calendario_crea.id_zona::text ELSE trim(calendario_crea.strada) END,
            calendario_crea.tipo, d::text, v_ex::text,
            -- data di esecuzione: quella indicata (solo senza ripetizione), altrimenti il giorno stesso
            CASE WHEN v_ex THEN COALESCE(CASE WHEN cardinality(v_date) = 1 THEN calendario_crea.date_int_ex END, d)::text END,
            COALESCE(c ->> 'planned_int', 'su Programmazione'), v_man;
    v_ids := v_ids || v_id;
  END LOOP;
  RETURN jsonb_build_object('ids', to_jsonb(v_ids), 'creati', cardinality(v_ids), 'fonte', v_fonte);
END $$;

-- POST /rpc/calendario-modifica {"id":3,"fonte":"verde","dati":{"execution":true,"date_int_ex":"2026-11-03"}}
CREATE OR REPLACE FUNCTION api.calendario_modifica(id integer, fonte text, dati jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  u     record := api_auth.cal_utente();
  c     jsonb := api_auth.cal_cfg();
  v_tab text := api_auth.cal_tabella(calendario_modifica.fonte);
  v_set text[] := '{}';
  v_ex  boolean;
  n     int;
BEGIN
  IF u.ruolo NOT IN ('admin', 'editor') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Utente non abilitato alla modifica.';
  END IF;
  IF jsonb_typeof(dati) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Nessun campo da aggiornare.';
  END IF;
  IF dati ? 'data' THEN
    v_set := v_set || format('date_int = %L::%s', (dati ->> 'data')::date, api_auth.tipo_colonna(v_tab, 'date_int'));
  END IF;
  IF dati ? 'ty_int' THEN
    IF NOT (c -> 'tipi_fonte') ? (dati ->> 'ty_int') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Tipo intervento non gestito.';
    END IF;
    v_set := v_set || format('ty_int = %L', dati ->> 'ty_int');
  END IF;
  IF dati ? 'execution' THEN
    v_ex := COALESCE((dati ->> 'execution')::boolean, false);
    v_set := v_set || format('execution = %L::%s', v_ex, api_auth.tipo_colonna(v_tab, 'execution'))
                   || format('date_int_ex = %L::%s', CASE WHEN v_ex THEN COALESCE((dati ->> 'date_int_ex')::date, current_date) END,
                             api_auth.tipo_colonna(v_tab, 'date_int_ex'));
  END IF;
  IF fonte = 'verde' AND dati ? 'id_zona' THEN
    v_set := v_set || format('id_zona = %L::%s', (dati ->> 'id_zona')::int, api_auth.tipo_colonna(v_tab, 'id_zona'));
  END IF;
  IF fonte = 'strade' AND dati ? 'strada' THEN
    v_set := v_set || format('strada = %L', trim(dati ->> 'strada'));
  END IF;
  IF cardinality(v_set) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Nessun campo da aggiornare.';
  END IF;
  EXECUTE format('UPDATE %s SET %s WHERE id = $1 AND ($2 OR manteiner = $3)', v_tab, array_to_string(v_set, ', '))
    USING calendario_modifica.id, u.ruolo IN ('admin', 'viewer'), u.manteiner;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Intervento inesistente o inserito da un altro manutentore.';
  END IF;
  RETURN jsonb_build_object('id', calendario_modifica.id, 'fonte', calendario_modifica.fonte);
END $$;

-- POST /rpc/calendario-elimina {"id":3,"fonte":"verde"}
CREATE OR REPLACE FUNCTION api.calendario_elimina(id integer, fonte text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  u     record := api_auth.cal_utente();
  v_tab text := api_auth.cal_tabella(calendario_elimina.fonte);
  n     int;
BEGIN
  IF u.ruolo NOT IN ('admin', 'editor') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Utente non abilitato alla cancellazione.';
  END IF;
  EXECUTE format('DELETE FROM %s WHERE id = $1 AND ($2 OR manteiner = $3)', v_tab)
    USING calendario_elimina.id, u.ruolo = 'admin', u.manteiner;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Intervento inesistente o inserito da un altro manutentore.';
  END IF;
  RETURN jsonb_build_object('id', calendario_elimina.id, 'fonte', calendario_elimina.fonte);
END $$;

COMMENT ON FUNCTION api.calendario_contesto() IS 'Calendario verde/strade: ruolo dell''utente e configurazione';
COMMENT ON FUNCTION api.calendario_interventi(date, date) IS 'Calendario verde/strade: interventi nel periodo, raggruppati per giorno';
COMMENT ON FUNCTION api.calendario_crea(text, date, integer, text, boolean, jsonb, date) IS 'Calendario verde/strade: nuovo intervento (con ripetizione)';
COMMENT ON FUNCTION api.calendario_modifica(integer, text, jsonb) IS 'Calendario verde/strade: modifica di un intervento';
COMMENT ON FUNCTION api.calendario_elimina(integer, text) IS 'Calendario verde/strade: cancellazione di un intervento';

-- ----------------------------------------------------------------------------
-- Proprieta' e permessi
-- ----------------------------------------------------------------------------
ALTER FUNCTION api_auth.tabella_esterna(text) OWNER TO api_scrittore;
ALTER FUNCTION api_auth.tipo_colonna(text, text) OWNER TO api_scrittore;
ALTER FUNCTION api_auth.cal_cfg() OWNER TO api_scrittore;
ALTER FUNCTION api_auth.cal_utente() OWNER TO api_scrittore;
ALTER FUNCTION api_auth.cal_tabella(text) OWNER TO api_scrittore;
ALTER FUNCTION api.segnalazione_mail(integer) OWNER TO api_scrittore;
ALTER FUNCTION api.calendario_contesto() OWNER TO api_scrittore;
ALTER FUNCTION api.calendario_interventi(date, date) OWNER TO api_scrittore;
ALTER FUNCTION api.calendario_crea(text, date, integer, text, boolean, jsonb, date) OWNER TO api_scrittore;
ALTER FUNCTION api.calendario_modifica(integer, text, jsonb) OWNER TO api_scrittore;
ALTER FUNCTION api.calendario_elimina(integer, text) OWNER TO api_scrittore;

REVOKE ALL ON FUNCTION api_auth.tabella_esterna(text), api_auth.tipo_colonna(text, text), api_auth.cal_cfg(),
  api_auth.cal_utente(), api_auth.cal_tabella(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.segnalazione_mail(integer), api.calendario_contesto(), api.calendario_interventi(date, date),
  api.calendario_crea(text, date, integer, text, boolean, jsonb, date), api.calendario_modifica(integer, text, jsonb),
  api.calendario_elimina(integer, text) FROM PUBLIC;

-- chi puo' chiamarle: tutti gli utenti autenticati (i controlli fini sono dentro le funzioni,
-- come nella versione precedente). Per restringere: GRANT a un gruppo invece che a grp_utenti.
GRANT EXECUTE ON FUNCTION api.segnalazione_mail(integer) TO grp_utenti;
GRANT EXECUTE ON FUNCTION api.calendario_contesto(), api.calendario_interventi(date, date),
  api.calendario_crea(text, date, integer, text, boolean, jsonb, date), api.calendario_modifica(integer, text, jsonb),
  api.calendario_elimina(integer, text) TO grp_utenti;

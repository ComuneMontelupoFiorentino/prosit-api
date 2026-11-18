-- ============================================================================
-- PROSIT API v2 — STRUTTURA DEL DATABASE "api" (da superuser, \connect api)
-- ============================================================================
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS postgres_fdw SCHEMA public;
-- dblink: solo per ottenere i valori delle sequenze remote (id serial/identity) in inserimento
CREATE EXTENSION IF NOT EXISTS dblink SCHEMA public;

-- public contiene solo le estensioni: uso si', creazione no.
-- Le funzioni dei nostri schemi sono revocate a PUBLIC una per una (controllo: api_admin.verifica()).
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO prosit_api_owner, api_lettore, api_scrittore, grp_utenti;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;   -- dblink e postgres_fdw: nessuno li usa direttamente
GRANT EXECUTE ON FUNCTION public.dblink(text, text), public.dblink_connect(text, text),
  public.dblink_disconnect(text), public.dblink_get_connections() TO api_scrittore;

CREATE SCHEMA IF NOT EXISTS api       AUTHORIZATION prosit_api_owner;
CREATE SCHEMA IF NOT EXISTS api_fn    AUTHORIZATION prosit_api_owner;
CREATE SCHEMA IF NOT EXISTS api_auth  AUTHORIZATION prosit_api_owner;
CREATE SCHEMA IF NOT EXISTS api_admin AUTHORIZATION prosit_api_owner;

REVOKE ALL ON SCHEMA api, api_fn, api_auth, api_admin FROM PUBLIC;
GRANT USAGE ON SCHEMA api    TO grp_utenti;
GRANT USAGE ON SCHEMA api_fn TO grp_utenti, api_lettore, api_scrittore;
-- api_auth: solo chi esegue le funzioni SECURITY DEFINER che lo usano (proprietari)
GRANT USAGE ON SCHEMA api_auth TO api_rolemgr, api_scrittore, api_lettore, api_gateway;
-- le viste in "api" sono di api_lettore/api_scrittore
GRANT USAGE, CREATE ON SCHEMA api TO api_lettore, api_scrittore;

COMMENT ON SCHEMA api IS 'Prosit API v2: unico schema pubblicato da PostgREST';

-- ----------------------------------------------------------------------------
-- api_fn: chi sta facendo la richiesta (dal token firmato dal gateway)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_fn.claims() RETURNS jsonb
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

CREATE OR REPLACE FUNCTION api_fn.login() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT api_fn.claims() ->> 'sub'
$$;

-- "Nome Cognome" (o il login se il nome manca)
CREATE OR REPLACE FUNCTION api_fn.nome() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT COALESCE(NULLIF(api_fn.claims() ->> 'nome', ''), api_fn.claims() ->> 'sub')
$$;

CREATE OR REPLACE FUNCTION api_fn.email() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT NULLIF(api_fn.claims() ->> 'email', '')
$$;

-- 'sessione' (cookie Lizmap) oppure 'chiave' (chiave API personale)
CREATE OR REPLACE FUNCTION api_fn.tipo_accesso() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT api_fn.claims() ->> 'auth'
$$;

-- Gruppo Lizmap (id o nome, senza distinzione maiuscole) presente nel token
CREATE OR REPLACE FUNCTION api_fn.in_gruppo_lizmap(p_gruppo text) RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT COALESCE(api_fn.claims() -> 'gruppi' ? lower(trim(p_gruppo)), false)
$$;

-- Ruolo PostgreSQL di gruppo (es. 'admins' -> grp_admins) dell'utente corrente.
-- E' la stessa informazione usata dai GRANT: un'unica fonte di verita' per i permessi.
CREATE OR REPLACE FUNCTION api_fn.ha_ruolo(p_ruolo text) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE
  r text := CASE WHEN p_ruolo LIKE 'grp\_%' THEN p_ruolo ELSE 'grp_' || p_ruolo END;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
    RETURN false;
  END IF;
  RETURN pg_has_role(current_user, r, 'MEMBER');
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api_fn FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_fn TO grp_utenti, api_lettore, api_scrittore, prosit_api_owner;

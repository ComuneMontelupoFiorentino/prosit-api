-- ============================================================================
-- PROSIT API v2 — DATABASE "api" (da superuser, sul database "postgres")
-- ============================================================================
-- Un solo database espone le API. Non contiene dati di servizio: i dati restano
-- nei database esistenti (segnalazioni_23, llpp, vp, ip_2020_2022...) e sono
-- raggiunti con postgres_fdw. Qui ci sono solo:
--   api        viste e funzioni ESPOSTE da PostgREST (l'unico schema pubblicato)
--   api_fn     funzioni di appoggio usate dalle viste (utente corrente, gruppi)
--   api_auth   utenti, chiavi API, gruppi, audit (MAI esposto)
--   api_admin  procedure di installazione (solo superuser)
--   fdw_*      tabelle esterne importate dai database di origine (MAI esposte)
-- ============================================================================
\set ON_ERROR_STOP on

SELECT 'CREATE DATABASE api OWNER prosit_api_owner ENCODING ''UTF8'' TEMPLATE template0'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'api') \gexec

ALTER DATABASE api OWNER TO prosit_api_owner;
REVOKE ALL ON DATABASE api FROM PUBLIC;
GRANT CONNECT ON DATABASE api TO authenticator, api_gateway;
-- percorso di ricerca prudente per chiunque si colleghi
ALTER DATABASE api SET search_path = pg_catalog, public;

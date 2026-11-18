-- ============================================================================
-- PROSIT API v2 — RUOLI DEL CLUSTER (da superuser, sul database "postgres")
-- ============================================================================
--   psql -d postgres -v authenticator_pass='...' -v gateway_pass='...' -f sql/00_ruoli.sql
-- Rilanciabile: crea cio' che manca e riallinea password e attributi.
--
-- Chi e' chi
--   prosit_api_owner  proprietario del database "api", delle tabelle di autenticazione
--                     e delle funzioni SECURITY DEFINER di sistema. NOLOGIN.
--   api_lettore       proprietario delle viste in sola lettura. La sua user mapping
--                     postgres_fdw usa prosit_ro sui database esterni. NOLOGIN.
--   api_scrittore     proprietario delle viste scrivibili e delle funzioni che scrivono.
--                     La sua user mapping usa prosit_rw. NOLOGIN.
--   api_rolemgr       crea i ruoli per utente (lz_*) e ne gestisce l'appartenenza ai
--                     gruppi. Solo CREATEROLE; puo' gestire SOLO i ruoli che crea (PG >= 16).
--   authenticator     l'utente con cui PostgREST si collega. NOINHERIT: non ha permessi
--                     propri, assume il ruolo indicato nel token (lz_<utente>).
--   web_anon          ruolo anonimo di PostgREST: nessun permesso.
--   api_gateway       l'utente con cui il modulo Lizmap allinea gli utenti ai ruoli:
--                     puo' solo eseguire le funzioni api_auth.gateway_*.
--   grp_utenti        ogni utente Lizmap autenticato ne fa parte.
--   grp_*             un ruolo per ogni gruppo "funzionale" (config/api.yaml -> gruppi),
--                     creati da api_admin.gruppo() al momento della generazione.
-- ============================================================================
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF current_setting('server_version_num')::int < 160000 THEN
    RAISE EXCEPTION 'Serve PostgreSQL 16 o successivo (trovato %): con versioni precedenti CREATEROLE consente troppo.',
      current_setting('server_version');
  END IF;
END $$;

SELECT 'CREATE ROLE prosit_api_owner NOLOGIN'  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prosit_api_owner') \gexec
SELECT 'CREATE ROLE api_lettore NOLOGIN'       WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_lettore') \gexec
SELECT 'CREATE ROLE api_scrittore NOLOGIN'     WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_scrittore') \gexec
SELECT 'CREATE ROLE api_rolemgr NOLOGIN CREATEROLE' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_rolemgr') \gexec
SELECT 'CREATE ROLE web_anon NOLOGIN'          WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') \gexec
SELECT 'CREATE ROLE grp_utenti NOLOGIN'        WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grp_utenti') \gexec
SELECT 'CREATE ROLE authenticator LOGIN NOINHERIT' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') \gexec
SELECT 'CREATE ROLE api_gateway LOGIN'         WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_gateway') \gexec

ALTER ROLE prosit_api_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE api_lettore      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE api_scrittore    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE api_rolemgr      NOLOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE web_anon         NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE grp_utenti       NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT format('ALTER ROLE authenticator LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 40 PASSWORD %L', :'authenticator_pass') \gexec
SELECT format('ALTER ROLE api_gateway LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 40 PASSWORD %L', :'gateway_pass') \gexec

-- PostgREST deve poter assumere il ruolo anonimo
GRANT web_anon TO authenticator;

-- il gestore dei ruoli deve poter assegnare grp_utenti (ADMIN), senza ereditarne i permessi
GRANT grp_utenti TO api_rolemgr WITH ADMIN OPTION, INHERIT FALSE, SET FALSE;

-- limiti di sicurezza sui ruoli impersonati (valgono come impostazioni di transazione)
ALTER ROLE grp_utenti SET statement_timeout = '30s';
ALTER ROLE web_anon SET statement_timeout = '1s';
ALTER ROLE authenticator SET statement_timeout = '30s';
ALTER ROLE api_gateway SET statement_timeout = '5s';

\echo 'Ruoli Prosit API creati/aggiornati.'

-- ============================================================================
-- PROSIT API v2 — UTENTI DEDICATI AI COLLEGAMENTI TRA DATABASE (postgres_fdw)
-- ============================================================================
--   psql -d postgres -v ro_pass='...' -v rw_pass='...' -v base_ro=prosit_ro -v base_rw=prosit_rw \
--        -f sql/05_utenti_fdw.sql
-- Rilanciabile. Crea prosit_api_ro e prosit_api_rw, con password generate dall'installazione,
-- membri di prosit_ro e prosit_rw: hanno esattamente i loro permessi sui database esterni.
--
-- Perche' utenti propri e non direttamente prosit_ro/prosit_rw:
--   - postgres_fdw esige che il server chieda la password; su questa VM i collegamenti locali
--     sono in "trust" per tutti. La regola pg_hba con la password si aggiunge SOLO per questi
--     due utenti, senza cambiare nulla per i servizi esistenti che usano prosit_ro/prosit_rw;
--   - non serve conoscere le password di prosit_ro/prosit_rw;
--   - negli accessi (pg_stat_activity, log) si distingue la Prosit API dagli altri servizi.
-- ============================================================================
\set ON_ERROR_STOP on

-- una riga sempre; NULL (variabile non impostata) se i ruoli ci sono
SELECT 'Mancano i ruoli ' || string_agg(r, ', ') || ': indicare quelli giusti (FDW_BASE_RO / FDW_BASE_RW)' AS messaggio
  FROM unnest(ARRAY[:'base_ro', :'base_rw']) r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gset errore_
\if :{?errore_messaggio}
  \echo :errore_messaggio
  SELECT 1/0 AS ruoli_mancanti;
\endif

SELECT 'CREATE ROLE prosit_api_ro LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prosit_api_ro') \gexec
SELECT 'CREATE ROLE prosit_api_rw LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prosit_api_rw') \gexec

SELECT format('ALTER ROLE prosit_api_ro LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 30 PASSWORD %L', :'ro_pass') \gexec
SELECT format('ALTER ROLE prosit_api_rw LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 30 PASSWORD %L', :'rw_pass') \gexec

-- permessi ereditati (INHERIT), ma senza poter diventare quei ruoli (SET FALSE)
SELECT format('GRANT %I TO prosit_api_ro WITH INHERIT TRUE, SET FALSE', :'base_ro') \gexec
SELECT format('GRANT %I TO prosit_api_rw WITH INHERIT TRUE, SET FALSE', :'base_rw') \gexec

-- impostazioni di ruolo (es. default_transaction_read_only) NON si ereditano con l'appartenenza:
-- si copiano da prosit_ro / prosit_rw, cosi' i due utenti si comportano come loro
SELECT format('ALTER ROLE %I%s SET %s', n.nuovo,
              CASE WHEN s.setdatabase <> 0 THEN format(' IN DATABASE %I', d.datname) ELSE '' END,
              -- come pg_dumpall: le liste (search_path, ...) vanno scritte cosi' come sono
              CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'local_preload_libraries', 'session_preload_libraries')
                   THEN format('%s = %s', split_part(c, '=', 1), substring(c from position('=' in c) + 1))
                   ELSE format('%s = %L', split_part(c, '=', 1), substring(c from position('=' in c) + 1)) END)
  FROM (VALUES (:'base_ro', 'prosit_api_ro'), (:'base_rw', 'prosit_api_rw')) n(base, nuovo)
  JOIN pg_roles r ON r.rolname = n.base
  JOIN pg_db_role_setting s ON s.setrole = r.oid
  LEFT JOIN pg_database d ON d.oid = s.setdatabase
  CROSS JOIN LATERAL unnest(s.setconfig) c \gexec
-- in ogni caso il collegamento di sola lettura apre transazioni di sola lettura
ALTER ROLE prosit_api_ro SET default_transaction_read_only = on;

COMMENT ON ROLE prosit_api_ro IS 'Prosit API v2: collegamenti postgres_fdw in lettura (membro di prosit_ro)';
COMMENT ON ROLE prosit_api_rw IS 'Prosit API v2: collegamenti postgres_fdw in scrittura (membro di prosit_rw)';

\echo 'Utenti dei collegamenti tra database creati/aggiornati.'

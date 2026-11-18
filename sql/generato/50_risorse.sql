-- ============================================================================
-- GENERATO da bin/genera_api.py (api.yaml) il 2026-11-02 09:27 UTC
-- NON MODIFICARE: cambiare config/api.yaml e rigenerare.
-- Uso (da superuser):  psql -d api -v pw_<utente>=... -f sql/generato/50_risorse.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
BEGIN;


-- gruppi: ruolo PostgreSQL <- gruppi Lizmap
CALL api_admin.gruppo('admins', ARRAY['admins']::text[], 'Amministratori');
CALL api_admin.gruppo('tvcc', ARRAY['admins', 'vigili', 'ced']::text[], 'Registro controlli videosorveglianza');
CALL api_admin.gruppo('manutentori_verde', ARRAY['man_verde_es', 'man_int']::text[], 'Manutentori del verde (esterni e interni)');

-- database esterni (postgres_fdw)
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA public;
CALL api_admin.database('segn', 'segnalazioni_23', '127.0.0.1', 5432, 'prosit_api_ro', :'pw_prosit_api_ro', 'prosit_api_rw', :'pw_prosit_api_rw', 'postgis');
CALL api_admin.database('llpp', 'llpp', '127.0.0.1', 5432, 'prosit_api_ro', :'pw_prosit_api_ro', 'prosit_api_rw', :'pw_prosit_api_rw', NULL);
CALL api_admin.database('vp', 'vp', '127.0.0.1', 5432, 'prosit_api_ro', :'pw_prosit_api_ro', 'prosit_api_rw', :'pw_prosit_api_rw', NULL);
CALL api_admin.database('ip', 'ip_2020_2022', '127.0.0.1', 5432, 'prosit_api_ro', :'pw_prosit_api_ro', 'prosit_api_rw', :'pw_prosit_api_rw', NULL);

-- tabelle esterne
CALL api_admin.importa('segn', 'segn', ARRAY['segn_id', 'reporting_ticket_deleted', 'ident_coord', 'rekla_doc', 'issue_docs_attachment', 'insert_ticket_tvcc_rekla_v']::text[]);
CALL api_admin.importa('segn', 'audit', ARRAY['frontend_communication', 'todo_queue', 'list_tvcc_reported', 'daily_log_tvcc', 'mail_queue']::text[]);
CALL api_admin.importa('segn', 'administration', ARRAY['assignee_list', 'login_rekla_prosit']::text[]);
CALL api_admin.importa('segn', 'buildings', ARRAY['list_tickets_full_all_v', 'reporting_ticket', 'attached_docs_ticket']::text[]);
CALL api_admin.importa('llpp', 'prog', ARRAY['manomissioni_sheet_v', 'manomissioni_attachs']::text[]);
CALL api_admin.importa('ip', 'punti_luce', ARRAY['sheet_supporti_v']::text[]);
CALL api_admin.importa('ip', 'manutenzioni', ARRAY['timeline_updates_v']::text[]);
CALL api_admin.importa('vp', 'interventi', ARRAY['join_int_user', 'obj_mantainer_int']::text[]);
CALL api_admin.importa('vp', 'gestione', ARRAY['pian_int', 'pian_int_street']::text[]);

-- risorse (viste in schema api + GRANT)
CALL api_admin.risorsa($j${"nome": "segnalazioni", "descrizione": "Segnalazioni (Rekla / Twproject / Prosit)", "sorgente": "segn.segn.segn_id", "chiave": "seg_id", "escludi": ["geom"], "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "segnalazioni-cronologia", "descrizione": "Aggiornamenti di stato della segnalazione (filtrare con id_prosit)", "sorgente": "segn.segn.reporting_ticket_deleted", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "segnalazioni-comunicazioni", "descrizione": "Comunicazioni inviate per il ticket (filtrare con id_ticket)", "sorgente": "segn.audit.frontend_communication", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "todo", "descrizione": "Attivita' (ToDo Twproject) collegate al ticket (filtrare con id_segn)", "sorgente": "segn.audit.todo_queue", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "segnalazioni-coordinate", "descrizione": "Tema/oggetto dell'elemento segnalato (filtrare con ident)", "sorgente": "segn.segn.ident_coord", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "segnalazioni-allegati-rekla", "descrizione": "Allegati Rekla (filtrare con seg_i_rek_n)", "sorgente": "segn.segn.rekla_doc", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "segnalazioni-allegati-twproject", "descrizione": "Allegati Twproject (filtrare con id_ticket)", "sorgente": "segn.segn.issue_docs_attachment", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "assegnatari", "descrizione": "Elenco assegnatari (man_es -> alias_name)", "sorgente": "segn.administration.assignee_list", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "bit-ticket", "descrizione": "Ticket edifici (vista completa)", "sorgente": "segn.buildings.list_tickets_full_all_v", "chiave": "id", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "bit-cronologia", "descrizione": "Aggiornamenti ticket edifici (filtrare con id_ticket)", "sorgente": "segn.buildings.reporting_ticket", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "bit-allegati", "descrizione": "Allegati ticket edifici (filtrare con id_ticket)", "sorgente": "segn.buildings.attached_docs_ticket", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "tvcc-apparati", "descrizione": "Telecamere con segnalazioni aperte", "sorgente": "segn.audit.list_tvcc_reported", "chiave": "id_app", "lettura": ["tvcc"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "tvcc-ticket", "descrizione": "Nuova segnalazione dal registro TVCC (vista con trigger di inserimento)", "sorgente": "segn.segn.insert_ticket_tvcc_rekla_v", "scrivibili": ["seg_o_ogg", "seg_o_desc", "segn_ogg_gen"], "inserimento": ["tvcc"], "forzati": {"seg_s_ac_op": "utente.nome"}}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "tvcc-log", "descrizione": "Registro giornaliero dei controlli", "sorgente": "segn.audit.daily_log_tvcc", "chiave": "id", "scrivibili": ["note"], "lettura": ["tvcc"], "inserimento": ["tvcc"], "forzati": {"insert_by": "utente.nome"}}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "manomissioni", "descrizione": "Scheda manomissione", "sorgente": "llpp.prog.manomissioni_sheet_v", "chiave": "id", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "manomissioni-allegati", "descrizione": "Allegati della manomissione (filtrare con id_man)", "sorgente": "llpp.prog.manomissioni_attachs", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "pali-luce", "descrizione": "Scheda sostegno illuminazione", "sorgente": "ip.punti_luce.sheet_supporti_v", "chiave": "pl_id", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "pali-luce-interventi", "descrizione": "Interventi/ispezioni sul sostegno (filtrare con pl_id)", "sorgente": "ip.manutenzioni.timeline_updates_v", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "vp-tipi-intervento", "descrizione": "Tipi di intervento per gruppo", "sorgente": "vp.interventi.join_int_user", "lettura": ["utenti"]}$j$::jsonb);
CALL api_admin.risorsa($j${"nome": "vp-oggetti-manutentore", "descrizione": "Zone/oggetti per manutentore e tipo", "sorgente": "vp.interventi.obj_mantainer_int", "lettura": ["utenti"]}$j$::jsonb);

-- risorse non piu' presenti nella configurazione
DO $$ DECLARE n text; BEGIN
  FOR n IN SELECT nome FROM api_auth.risorse WHERE nome <> ALL (ARRAY['segnalazioni', 'segnalazioni-cronologia', 'segnalazioni-comunicazioni', 'todo', 'segnalazioni-coordinate', 'segnalazioni-allegati-rekla', 'segnalazioni-allegati-twproject', 'assegnatari', 'bit-ticket', 'bit-cronologia', 'bit-allegati', 'tvcc-apparati', 'tvcc-ticket', 'tvcc-log', 'manomissioni', 'manomissioni-allegati', 'pali-luce', 'pali-luce-interventi', 'vp-tipi-intervento', 'vp-oggetti-manutentore']::text[]) LOOP
    CALL api_admin.rimuovi_risorsa(n); RAISE NOTICE 'Rimossa risorsa %', n;
  END LOOP;
END $$;

-- configurazione dei servizi
CALL api_admin.impostazione('calendario', $j${"tab": {"verde": "vp.gestione.pian_int", "strade": "vp.gestione.pian_int_street"}, "tipi_fonte": {"potature siepi": "verde", "falciatura tappeti erbosi": "verde", "Pulizia Strade, Piazze, Parcheggi...": "strade"}, "planned_int": "su Programmazione", "editor_groups": ["man_verde_es", "man_int", "admins"], "group_manteiner": {"man_verde_es": "Cooperativa orizzonti", "man_int": "Manutentori interni", "admins": "Manutentori interni"}, "admin_groups": ["admins"], "viewers": ["man", "urp"], "data_groups": ["man_verde_es", "man_int"]}$j$::jsonb);

COMMIT;

-- PostgREST ricarica la struttura
NOTIFY pgrst, 'reload schema';

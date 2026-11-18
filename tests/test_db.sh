#!/usr/bin/env bash
# Test del livello database, eseguendo le richieste ESATTAMENTE come PostgREST:
# connessione come authenticator, impostazioni request.*, SET LOCAL ROLE, db-pre-request, query.
# Prerequisito: tests/installa_test.sh
set -uo pipefail
export PGHOST=127.0.0.1 PGPORT=5433
OK=0; KO=0
verde(){ printf '\033[32m%s\033[0m\n' "$*"; }; rosso(){ printf '\033[31m%s\033[0m\n' "$*"; }

gw(){ PGPASSWORD=gw_test psql -X -At -U api_gateway -d api -c "$1" 2>&1; }
su(){ PGPASSWORD=postgres psql -X -At -U postgres -d "${2:-api}" -c "$1" 2>&1; }

# richiesta come PostgREST: req <ruolo> <claims-json> <metodo> <percorso> <sql>
req(){
  local ruolo=$1 claims=$2 metodo=$3 percorso=$4 sql=$5
  PGPASSWORD=auth_test psql -X -At -U authenticator -d api -v ON_ERROR_STOP=1 \
    -v claims="$claims" -v metodo="$metodo" -v perc="$percorso" -v ruolo="$ruolo" 2>&1 <<EOF
BEGIN;
SELECT set_config('role', :'ruolo', true), set_config('request.jwt.claims', :'claims', true),
       set_config('request.method', :'metodo', true), set_config('request.path', :'perc', true),
       set_config('request.headers', '{"x-request-id":"test-req"}', true) \gset x_
SELECT api_fn.pre_request() \gset x_
$sql;
COMMIT;
EOF
}
# atteso: prova <descrizione> <regex-atteso> <output>
prova(){
  if grep -qE -- "$2" <<<"$3"; then verde "OK  $1"; OK=$((OK+1)); else rosso "KO  $1"; echo "    atteso /$2/ ottenuto:"; sed 's/^/    | /' <<<"$3" | head -6; KO=$((KO+1)); fi
}
claims(){ # claims <login> <nome> <email> <gruppi-json> [extra-json]
  python3 -c "import json,sys,time; d={'iss':'prosit-lizmap','aud':'prosit-api','sub':sys.argv[1],'nome':sys.argv[2],'email':sys.argv[3],'gruppi':json.loads(sys.argv[4]),'auth':'sessione','exp':int(time.time())+60}; d.update(json.loads(sys.argv[5] if len(sys.argv)>5 else '{}')); print(json.dumps(d))" "$@"
}

echo "== utenti (come li allinea il modulo Lizmap)"
R_ADMIN=$(gw "SELECT api_auth.gateway_utente('admin','Anna Admin','admin@example.it',ARRAY['admins','tecnici_api'],'sessione')")
R_VIG=$(gw "SELECT api_auth.gateway_utente('vigile','Vito Vigile','vigile@example.it',ARRAY['vigili','Polizia Municipale'],'sessione')")
R_COOP=$(gw "SELECT api_auth.gateway_utente('coop','Carla Coop','coop@example.it',ARRAY['man_verde_es','Manutentori verde esterni'],'sessione')")
R_MARIO=$(gw "SELECT api_auth.gateway_utente('mario.rossi','Mario Rossi','',ARRAY['urp'],'sessione')")
prova "ruolo utente creato" '^lz_admin_[0-9a-f]{6}$' "$R_ADMIN"
prova "login con caratteri speciali" '^lz_mario_rossi_[0-9a-f]{6}$' "$R_MARIO"
prova "gruppi Lizmap -> ruoli" 'grp_admins,grp_tvcc,grp_utenti' "$(su "SELECT array_to_string(ruoli, ',') FROM api_auth.utenti WHERE login='admin'")"
prova "nome di gruppo Lizmap (non id) riconosciuto" 'grp_tvcc' "$(su "SELECT array_to_string(ruoli, ',') FROM api_auth.utenti WHERE login='vigile'")"
prova "modulo Lizmap (api_gateway) non legge le tabelle" 'permission denied' "$(gw "SELECT * FROM api_auth.utenti")"
prova "login non valido rifiutato" 'login non valido' "$(gw "SELECT api_auth.gateway_utente(E'a\\nb','x','',ARRAY[]::text[],'sessione')")"

C_ADMIN=$(claims admin "Anna Admin" admin@example.it '["admins","tecnici_api"]')
C_VIG=$(claims vigile "Vito Vigile" vigile@example.it '["vigili","polizia municipale"]')
C_COOP=$(claims coop "Carla Coop" coop@example.it '["man_verde_es","manutentori verde esterni"]')
C_MARIO=$(claims mario.rossi "Mario Rossi" "" '["urp"]')

echo "== lettura"
prova "utente legge segnalazioni" '^3$' "$(req $R_MARIO "$C_MARIO" GET /segnalazioni 'SELECT count(*) FROM api.segnalazioni')"
prova "colonna esclusa (geom) non esposta" 'column "geom" does not exist' "$(req $R_MARIO "$C_MARIO" GET /segnalazioni 'SELECT geom FROM api.segnalazioni')"
prova "utente senza gruppo tvcc: vietato" 'permission denied for view tvcc_apparati' "$(req $R_MARIO "$C_MARIO" GET /tvcc_apparati 'SELECT * FROM api.tvcc_apparati')"
prova "vigile legge tvcc (array e json)" 'TLC-01\|\{Assegnata\}\|\[\{"seg_id"' "$(req $R_VIG "$C_VIG" GET /tvcc_apparati "SELECT id_app, stati, issues FROM api.tvcc_apparati WHERE id_app='TLC-01'")"
prova "tabelle esterne non raggiungibili dagli utenti" 'permission denied for schema fdw_segn_segn' "$(req $R_ADMIN "$C_ADMIN" GET /x 'SELECT * FROM fdw_segn_segn.segn_id')"
prova "api_auth non raggiungibile" 'permission denied for schema api_auth' "$(req $R_ADMIN "$C_ADMIN" GET /x 'SELECT * FROM api_auth.chiavi')"

echo "== scrittura e campi forzati"
prova "vigile scrive il registro, insert_by dal token, id dal db esterno" '^[0-9]+\|Tutto funzionante\|Vito Vigile\|20[0-9-]+ ' "$(req $R_VIG "$C_VIG" POST /tvcc_log "INSERT INTO api.tvcc_log (note) VALUES ('Tutto funzionante') RETURNING id, note, insert_by, insert_date")"
prova "campo forzato inviato dal client: vietato" 'permission denied for view tvcc_log' "$(req $R_VIG "$C_VIG" POST /tvcc_log "INSERT INTO api.tvcc_log (note, insert_by) VALUES ('x','Falso')")"
prova "colonna non scrivibile (id): vietata" 'permission denied for view tvcc_log' "$(req $R_VIG "$C_VIG" POST /tvcc_log "INSERT INTO api.tvcc_log (id, note) VALUES (99,'x')")"
prova "nessuna modifica senza GRANT UPDATE" 'permission denied for view tvcc_log' "$(req $R_VIG "$C_VIG" PATCH /tvcc_log "UPDATE api.tvcc_log SET note='x' WHERE id=1")"
OUT=$(req $R_VIG "$C_VIG" POST /tvcc_ticket "INSERT INTO api.tvcc_ticket (seg_o_ogg, seg_o_desc, segn_ogg_gen) VALUES ('Registro controllo TLC','Immagine sfocata','TLC-03')")
prova "inserimento su vista remota con trigger" 'INSERT 0 1|^$' "$OUT"
prova "operatore impostato dal database sul db esterno" 'Vito Vigile\|Immagine sfocata' "$(su "SELECT seg_s_ac_op, seg_o_desc FROM segn.segn_id WHERE seg_o_desc='Immagine sfocata'" segnalazioni_23)"
prova "messaggio del trigger remoto riportato" 'Descrizione troppo corta' "$(req $R_VIG "$C_VIG" POST /tvcc_ticket "INSERT INTO api.tvcc_ticket (seg_o_ogg, seg_o_desc, segn_ogg_gen) VALUES ('x','a','TLC-03')")"
prova "inserimento multiplo tutto-o-niente" '^0$' "$(req $R_VIG "$C_VIG" POST /tvcc_ticket "INSERT INTO api.tvcc_ticket (seg_o_ogg, seg_o_desc, segn_ogg_gen) VALUES ('x','buona','TLC-01'),('x','b','TLC-01')" >/dev/null; su "SELECT count(*) FROM segn.segn_id WHERE seg_o_desc='buona'" segnalazioni_23)"

echo "== limite per riga (filtro + CHECK OPTION)"
prova "manutentore inserisce nel proprio ambito" 'Cooperativa orizzonti\|su Programmazione' "$(req $R_COOP "$C_COOP" POST /interventi_verde "INSERT INTO api.interventi_verde (id_zona, ty_int, date_int, manteiner) VALUES (12,'potature siepi','2026-11-03','Cooperativa orizzonti') RETURNING manteiner, planned_int")"
prova "manutentore non inserisce per altri" 'violates check option' "$(req $R_COOP "$C_COOP" POST /interventi_verde "INSERT INTO api.interventi_verde (id_zona, ty_int, date_int, manteiner) VALUES (13,'potature siepi','2026-11-03','Manutentori interni')")"
req $R_ADMIN "$C_ADMIN" POST /interventi_verde "INSERT INTO api.interventi_verde (id_zona, ty_int, date_int, manteiner) VALUES (14,'potature siepi','2026-11-04','Manutentori interni')" >/dev/null
prova "manutentore vede solo i suoi" '^1$' "$(req $R_COOP "$C_COOP" GET /interventi_verde 'SELECT count(*) FROM api.interventi_verde')"
prova "admin vede tutto" '^2$' "$(req $R_ADMIN "$C_ADMIN" GET /interventi_verde 'SELECT count(*) FROM api.interventi_verde')"
prova "manutentore non modifica record altrui" 'UPDATE 0' "$(req $R_COOP "$C_COOP" PATCH /interventi_verde "UPDATE api.interventi_verde SET execution=true WHERE id_zona=14")"
prova "manutentore modifica il proprio" 'UPDATE 1' "$(req $R_COOP "$C_COOP" PATCH /interventi_verde "UPDATE api.interventi_verde SET execution=true, date_int_ex='2026-11-03' WHERE id_zona=12")"
prova "colonna non modificabile" 'permission denied' "$(req $R_COOP "$C_COOP" PATCH /interventi_verde "UPDATE api.interventi_verde SET manteiner='Manutentori interni' WHERE id_zona=12")"
prova "cancellazione solo admins" 'permission denied' "$(req $R_COOP "$C_COOP" DELETE /interventi_verde "DELETE FROM api.interventi_verde WHERE id_zona=12")"
prova "admin cancella" 'DELETE 1' "$(req $R_ADMIN "$C_ADMIN" DELETE /interventi_verde "DELETE FROM api.interventi_verde WHERE id_zona=14")"

echo "== pre-request"
prova "token non emesso da Lizmap rifiutato" 'solo tramite Lizmap' "$(req $R_ADMIN '{"sub":"admin","iss":"altro"}' GET /segnalazioni 'SELECT 1')"
prova "audit delle modifiche" 'vigile\|POST\|/tvcc_log\|test-req' "$(su "SELECT login, metodo, percorso, request_id FROM api_auth.audit WHERE login='vigile' ORDER BY id LIMIT 1")"
prova "audit: niente letture" '^0$' "$(su "SELECT count(*) FROM api_auth.audit WHERE metodo='GET'")"

echo "== ruoli: nessuna scorciatoia"
prova "authenticator non puo' diventare un gruppo" 'permission denied to set role' "$(PGPASSWORD=auth_test psql -X -At -U authenticator -d api -c 'SET ROLE grp_admins' 2>&1)"
prova "authenticator non puo' diventare proprietario" 'permission denied to set role' "$(PGPASSWORD=auth_test psql -X -At -U authenticator -d api -c 'SET ROLE api_scrittore' 2>&1)"
prova "anonimo: nessun accesso" 'permission denied' "$(PGPASSWORD=auth_test psql -X -At -U authenticator -d api -c 'SET ROLE web_anon; SELECT * FROM api.segnalazioni' 2>&1)"
prova "anonimo: nessuna funzione" 'permission denied' "$(PGPASSWORD=auth_test psql -X -At -U authenticator -d api -c 'SET ROLE web_anon; SELECT api.io()' 2>&1)"

echo "== informazioni utente"
prova "io(): ruoli PostgreSQL effettivi" '"ruoli": \["tvcc", "utenti"\]' "$(req $R_VIG "$C_VIG" GET /rpc/io 'SELECT api.io()')"
prova "risorse(): operazioni dai GRANT" 'tvcc-log\|Registro giornaliero dei controlli\|id\|\{lettura,inserimento\}' "$(req $R_VIG "$C_VIG" GET /risorse "SELECT * FROM api.risorse WHERE nome='tvcc-log'")"
prova "risorse(): mario non vede tvcc" '^0$' "$(req $R_MARIO "$C_MARIO" GET /risorse "SELECT count(*) FROM api.risorse WHERE nome LIKE 'tvcc%'")"

echo "== servizi"
prova "mail: messa in coda" '"queued": true.*"recipients": 2' "$(req $R_ADMIN "$C_ADMIN" POST /rpc/segnalazione_mail 'SELECT api.segnalazione_mail(1)')"
prova "mail: destinatari e copia sul db esterno" 'capo@example.it.*verde@example.it.*admin@example.it' "$(su "SELECT recipient::text || carbon_copy::text FROM audit.mail_queue" segnalazioni_23)"
prova "mail: assegnatario non invia a se stesso" 'gruppo assegnatario' "$(req $R_COOP "$C_COOP" POST /rpc/segnalazione_mail 'SELECT api.segnalazione_mail(1)')"
prova "mail: utente senza email" 'non ha un indirizzo email' "$(req $R_MARIO "$C_MARIO" POST /rpc/segnalazione_mail 'SELECT api.segnalazione_mail(1)')"
C_PRG=$(claims admin "Anna Admin" admin@example.it '["admins"]' '{"auth":"programma"}')
prova "mail: da programma non consentita" 'solo da Lizmap' "$(req $R_ADMIN "$C_PRG" POST /rpc/segnalazione_mail 'SELECT api.segnalazione_mail(1)')"
prova "calendario: contesto manutentore" '"role": "editor".*' "$(req $R_COOP "$C_COOP" GET /rpc/calendario_contesto 'SELECT api.calendario_contesto()')"
prova "calendario: contesto urp = viewer" '"role": "viewer"' "$(req $R_MARIO "$C_MARIO" GET /rpc/calendario_contesto 'SELECT api.calendario_contesto()')"
prova "calendario: crea con ripetizione (lun, mer)" '"creati": 4' "$(req $R_COOP "$C_COOP" POST /rpc/calendario_crea "SELECT api.calendario_crea(tipo => 'potature siepi', data => '2026-11-02', id_zona => 12, ripeti => '{\"fino_a\":\"2026-11-12\",\"giorni\":[1,3]}')")"
prova "calendario: strade" '"fonte": "strade"' "$(req $R_COOP "$C_COOP" POST /rpc/calendario_crea "SELECT api.calendario_crea(tipo => 'Pulizia Strade, Piazze, Parcheggi...', data => '2026-11-05', strada => 'Via Roma')")"
prova "calendario: tipo non gestito" 'non gestito' "$(req $R_COOP "$C_COOP" POST /rpc/calendario_crea "SELECT api.calendario_crea(tipo => 'x', data => '2026-11-02')")"
prova "calendario: elenco per giorno" '"2026-11-04": \{"interventi"' "$(req $R_COOP "$C_COOP" GET /rpc/calendario_interventi "SELECT api.calendario_interventi('2026-11-01','2026-11-30')")"
IDC=$(su "SELECT min(id) FROM gestione.pian_int WHERE date_int='2026-11-04'" vp)
prova "calendario: modifica" '"fonte": "verde"' "$(req $R_COOP "$C_COOP" POST /rpc/calendario_modifica "SELECT api.calendario_modifica($IDC, 'verde', '{\"execution\":true}')")"
prova "calendario: viewer non cancella" 'non abilitato' "$(req $R_MARIO "$C_MARIO" POST /rpc/calendario_elimina "SELECT api.calendario_elimina($IDC, 'verde')")"
prova "calendario: cancella" '"id": '"$IDC" "$(req $R_COOP "$C_COOP" POST /rpc/calendario_elimina "SELECT api.calendario_elimina($IDC, 'verde')")"
prova "calendario: fonte non valida" 'Fonte non valida' "$(req $R_COOP "$C_COOP" POST /rpc/calendario_elimina "SELECT api.calendario_elimina(1, 'x; drop table')")"

echo "== allineamento continuo dei gruppi"
gw "SELECT api_auth.gateway_utente('coop','Carla Coop','coop@example.it',ARRAY[]::text[],'sessione')" >/dev/null
prova "gruppo tolto in Lizmap -> permesso tolto subito" 'permission denied for view interventi_verde' "$(req $R_COOP "$C_COOP" GET /interventi_verde 'SELECT count(*) FROM api.interventi_verde')"
gw "SELECT api_auth.gateway_utente('coop','Carla Coop','coop@example.it',ARRAY['man_verde_es'],'sessione')" >/dev/null
prova "gruppo ridato -> permesso ridato" '^[0-9]+$' "$(req $R_COOP "$C_COOP" GET /interventi_verde 'SELECT count(*) FROM api.interventi_verde')"

echo "== controlli di sicurezza"
prova "api_admin.verifica() senza errori" '^OK' "$(su "SELECT esito FROM api_admin.verifica() WHERE esito <> 'AVVISO'" | sort -u | tr '\n' ' ')"

echo; echo "Superati: $OK   Falliti: $KO"; [ $KO -eq 0 ]

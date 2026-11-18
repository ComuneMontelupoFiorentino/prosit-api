#!/usr/bin/env bash
# Installa la Prosit API v2 su un PostgreSQL DI PROVA con i database esterni finti.
# uso: tests/installa_test.sh <cartella_di_lavoro>   (PG su 127.0.0.1:5433, superuser postgres/postgres)
set -euo pipefail
QUI=$(cd "$(dirname "$0")/.." && pwd)
W=${1:?cartella di lavoro}
mkdir -p "$W"
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres
P="psql -X -q -v ON_ERROR_STOP=1"

# configurazione di prova: stessi contenuti, database sulla porta di prova, + una risorsa CRUD con filtro
python3 - "$QUI/config/api.yaml" "$W/api.yaml" <<'EOF'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
for d in c["database"].values():
    d["host"], d["port"] = "127.0.0.1", 5433
c["risorse"]["interventi-verde"] = {
    "descrizione": "Interventi programmati sul verde (prova CRUD con filtro)",
    "sorgente": "vp.gestione.pian_int", "chiave": "id",
    "lettura": ["manutentori_verde", "admins"], "inserimento": ["manutentori_verde", "admins"],
    "modifica": ["manutentori_verde", "admins"], "cancellazione": ["admins"],
    "scrivibili": ["id_zona", "ty_int", "date_int", "execution", "date_int_ex", "manteiner"],
    "modificabili": ["execution", "date_int_ex", "date_int"],
    "forzati": {"planned_int": {"valore": "su Programmazione"}},
    "filtro": "api_fn.ha_ruolo('admins') OR manteiner = CASE WHEN api_fn.in_gruppo_lizmap('man_verde_es') THEN 'Cooperativa orizzonti' WHEN api_fn.in_gruppo_lizmap('man_int') THEN 'Manutentori interni' END",
}
c["api"]["server_pubblico"] = "http://127.0.0.1:8090"
yaml.safe_dump(c, open(sys.argv[2], "w"), sort_keys=False, allow_unicode=True)
EOF

python3 "$QUI/bin/genera_api.py" --config "$W/api.yaml" --uscita "$W/gen"

$P -d postgres -f "$QUI/tests/sorgenti.sql"
$P -d postgres -v authenticator_pass=auth_test -v gateway_pass=gw_test -f "$QUI/sql/00_ruoli.sql"
$P -d postgres -v ro_pass=ro_test -v rw_pass=rw_test -v base_ro=prosit_ro -v base_rw=prosit_rw -f "$QUI/sql/05_utenti_fdw.sql"
$P -d postgres -f "$QUI/sql/10_database.sql"
for f in 20_struttura 30_auth 40_admin; do $P -d api -f "$QUI/sql/$f.sql"; done
$P -d api -v pw_prosit_api_ro=ro_test -v pw_prosit_api_rw=rw_test -f "$W/gen/sql/generato/50_risorse.sql"
$P -d api -f "$QUI/sql/60_servizi.sql"
python3 "$QUI/bin/genera_api.py" --config "$W/api.yaml" --uscita "$W/gen" --solo-openapi --psql "psql -h 127.0.0.1 -p 5433 -U postgres -d api"
echo "== verifica"
psql -X -At -d api -c "SELECT esito || ' | ' || controllo || ' | ' || dettaglio FROM api_admin.verifica()"

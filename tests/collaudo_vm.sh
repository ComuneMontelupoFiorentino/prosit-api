#!/usr/bin/env bash
# =============================================================================
# Collaudo sulla VM, con Lizmap e PostgREST VERI (dopo "prosit-api installa").
#   tests/collaudo_vm.sh https://gis.example.it/lizmap  utente_tecnico:password  [cookie PHPSESSID]
# L'utente tecnico: utente Lizmap in un gruppo a cui e' assegnato il diritto
# "Accesso alle API da programmi" (Amministrazione -> Diritti). Basta la sola lettura.
# =============================================================================
set -uo pipefail
SITO=${1:?indirizzo di Lizmap, es. https://gis.example.it/lizmap}; CRED=${2:?utente:password}; SESS=${3:-}
B=$SITO/api.php/prosit/v2
OK=0; KO=0
t(){ # t <descrizione> <stato> <regex> curl-args...
  local d=$1 s=$2 r=$3; shift 3
  local out; out=$(curl -s -w '\n%{http_code}' "$@"); local c=${out##*$'\n'} b=${out%$'\n'*}
  if [[ $c =~ ^($s)$ ]] && grep -qE -- "$r" <<<"$b"; then echo "OK  $d"; OK=$((OK+1)); else echo "KO  $d (stato $c, atteso $s): ${b:0:200}"; KO=$((KO+1)); fi
}
U=(-u "$CRED")

echo "== modulo Lizmap"
t "Lizmap risponde" 200 '' "$SITO/index.php"
t "status" 200 '"stato":"ok"' "$B/status"
t "senza credenziali: 401 problem+json" 401 '"status":401' "$B/segnalazioni"
t "auth/me utente tecnico" 200 '"tipo_accesso":"programma"' "${U[@]}" "$B/auth/me"
t "password errata: 401" 401 'Credenziali' -u "${CRED%%:*}:sbagliata" "$B/auth/me"
t "rpc/io: ruoli PostgreSQL" 200 '"ruoli"' "${U[@]}" "$B/rpc/io"
t "risorse consentite" 200 '"operazioni"' "${U[@]}" "$B/risorse"
t "lettura con filtri PostgREST" 200 '^\[' "${U[@]}" "$B/segnalazioni?select=seg_id,stato_segn&order=seg_id.desc&limit=3"
# PostgREST risponde 206 (Partial Content) quando il conteggio supera il limite
t "conteggio: 200 o 206" '200|206' '' "${U[@]}" -H "Prefer: count=exact" "$B/segnalazioni?select=seg_id&limit=1"
curl -s -o /dev/null -D - "${U[@]}" -H "Prefer: count=exact" "$B/segnalazioni?select=seg_id&limit=1" | grep -qiE '^content-range: 0-0/[0-9]+' \
  && { echo "OK  intestazione Content-Range con il totale"; OK=$((OK+1)); } || { echo "KO  manca Content-Range con il totale"; KO=$((KO+1)); }
t "colonna inesistente: 400" 400 '' "${U[@]}" "$B/segnalazioni?select=non_esiste"
t "percorso non previsto: 404" 404 '' "${U[@]}" "$B/api_auth.utenti"
t "PATCH senza filtro: 400" 400 'filtro' -X PATCH "${U[@]}" -H 'Content-Type: application/json' -d '{}' "$B/tvcc-log"
if [[ $SITO == https://* ]]; then
  t "Basic su HTTP in chiaro: rifiutata" 403 'HTTPS' "${U[@]}" "http://${SITO#https://}/api.php/prosit/v2/auth/me"
else
  echo "!!  Lizmap e' su HTTP: gli utenti tecnici (Basic) funzionano solo su HTTPS"
fi
H=$(curl -s -o /dev/null -D - "${U[@]}" "$B/auth/me" | tr -d '\r')
grep -qi '^set-cookie' <<<"$H" && { echo "KO  Basic non deve creare sessioni"; KO=$((KO+1)); } || { echo "OK  Basic senza cookie di sessione"; OK=$((OK+1)); }
if [ -n "$SESS" ]; then
  t "sessione Lizmap" 200 '"tipo_accesso":"sessione"' -H "Cookie: PHPSESSID=$SESS" "$B/auth/me"
  t "modifica con sessione senza Origin: 403 (CSRF)" 403 'CSRF' -X POST -H "Cookie: PHPSESSID=$SESS" -H 'Content-Type: application/json' -d '{"note":"x"}' "$B/tvcc-log"
fi
H=$(curl -s -o /dev/null -D - "${U[@]}" "$B/segnalazioni?limit=1" | tr -d '\r')
for x in 'x-content-type-options: nosniff' 'cache-control: no-store' 'x-request-id'; do
  grep -qi "^$x" <<<"$H" && { echo "OK  intestazione $x"; OK=$((OK+1)); } || { echo "KO  manca $x"; KO=$((KO+1)); }
done

if curl -s -o /dev/null --max-time 2 http://127.0.0.1:3100/ 2>/dev/null; then
  echo "== PostgREST diretto (solo dalla VM)"
  b64(){ printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
  RUOLO=$(psql -h 127.0.0.1 -U "${PG_ADMIN:-postgres}" -w -d api -XAtc "SELECT ruolo FROM api_auth.utenti ORDER BY ultimo_accesso DESC LIMIT 1")
  P=$(b64 "{\"role\":\"$RUOLO\",\"aud\":\"prosit-api\",\"iss\":\"prosit-lizmap\",\"sub\":\"x\",\"exp\":$(( $(date +%s)+60 ))}")
  t "token senza firma (alg none): 401" 401 '' -H "Authorization: Bearer $(b64 '{"alg":"none","typ":"JWT"}').$P." http://127.0.0.1:3100/segnalazioni
  t "token HS256 con chiave inventata: 401" 401 '' -H "Authorization: Bearer $(b64 '{"alg":"HS256","typ":"JWT"}').$P.$(b64 firmafalsa)" http://127.0.0.1:3100/segnalazioni
  t "senza token: 401 (anonimo senza permessi)" 401 '' http://127.0.0.1:3100/segnalazioni
fi
echo; echo "Superati: $OK   Falliti: $KO"; [ $KO -eq 0 ]

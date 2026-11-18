#!/usr/bin/env bash
# =============================================================================
# Collaudo del modulo Lizmap "prositapi" su un Lizmap 3.9 VERO (jAuth, jAcl2, jDb, php-jwt).
#   tests/test_lizmap.sh <url di Lizmap>
# Prerequisiti (vedi tests/LEGGIMI.md): utenti di prova creati con console.php, PostgREST
# (o tests/finto_postgrest.php) su 127.0.0.1:3100/3101, database "api" di prova, e lo script
# di sola prova www/_test_login.php per aprire una vera sessione Lizmap.
# =============================================================================
set -uo pipefail
SITO=${1:-http://127.0.0.1:8091}
B=$SITO/api.php/prosit/v2
ORIGINE=$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$SITO")   # Origin non ha mai un percorso
O="Origin: $ORIGINE"; J="Content-Type: application/json"
OK=0; KO=0
t(){ # t <descrizione> <stato> <regex> curl-args...
  local d=$1 s=$2 r=$3; shift 3
  local out; out=$(curl -s -w '\n%{http_code}' "$@"); local c=${out##*$'\n'} b=${out%$'\n'*}
  if [ "$c" = "$s" ] && grep -qE -- "$r" <<<"$b"; then printf '\033[32mOK\033[0m  %s\n' "$d"; OK=$((OK+1))
  else printf '\033[31mKO\033[0m  %s (stato %s, atteso %s)\n      %s\n' "$d" "$c" "$s" "${b:0:300}"; KO=$((KO+1)); fi
}
v(){ if eval "$2"; then printf '\033[32mOK\033[0m  %s\n' "$1"; OK=$((OK+1)); else printf '\033[31mKO\033[0m  %s\n' "$1"; KO=$((KO+1)); fi; }
sess(){ curl -s "$SITO/_test_login.php?u=$1&p=$2"; }

VIG="Cookie: $(sess vigile Vigile.2026)"
MARIO="Cookie: $(sess mario.rossi Mario.2026)"
COOP="Cookie: $(sess coop Coop.2026)"
ADMIN="Cookie: $(sess anna Anna.2026)"
SVC=(-u svc_tvcc:Servizio.2026)

echo "== stato e autenticazione"
t "status senza autenticazione" 200 '"stato":"ok"' "$B/status"
t "senza credenziali: 401 problem+json" 401 '"status":401.*"request_id"' "$B/segnalazioni"
H=$(curl -s -o /dev/null -D - "$B/segnalazioni" | tr -d '\r')
v "errori in application/problem+json" "grep -qi '^content-type: application/problem+json' <<<\"\$H\""
v "401 con WWW-Authenticate Basic" "grep -qi '^www-authenticate: Basic' <<<\"\$H\""
t "sessione Lizmap: auth/me" 200 '"tipo_accesso":"sessione".*"programmi":false' -H "$VIG" "$B/auth/me"
t "gruppi Lizmap (id e nomi)" 200 '"Polizia Municipale"' -H "$VIG" "$B/auth/me"
t "Basic: password errata" 401 'Credenziali non valide' -u svc_tvcc:sbagliata "$B/auth/me"
t "Basic: utente inesistente" 401 'Credenziali non valide' -u nessuno:x "$B/auth/me"
t "Basic: utente senza il diritto prosit.api.programmi" 403 'prosit.api.programmi' -u vigile:Vigile.2026 "$B/auth/me"
t "Basic: utente disattivato in Lizmap (pur col diritto)" 401 'Credenziali non valide' -u spento:Spento.2026 "$B/auth/me"
t "Basic: utente tecnico abilitato" 200 '"tipo_accesso":"programma".*"programmi":true' "${SVC[@]}" "$B/auth/me"
H=$(curl -s -o /dev/null -D - "${SVC[@]}" "$B/auth/me" | tr -d '\r')
v "Basic: nessun cookie di sessione restituito" "! grep -qi '^set-cookie' <<<\"\$H\""

echo "== permessi (GRANT PostgreSQL dai gruppi Lizmap)"
t "rpc/io: ruoli PostgreSQL" 200 '"ruoli": \["tvcc", "utenti"\]|"ruoli":\["tvcc","utenti"\]' -H "$VIG" "$B/rpc/io"
t "lettura consentita" 200 '"seg_id"' -H "$MARIO" "$B/segnalazioni?select=seg_id,stato_segn&order=seg_id.desc&limit=2"
t "risorsa vietata al gruppo: 403 senza dettagli interni" 403 '^\{[^}]*"detail":"Permessi insufficienti' -H "$MARIO" "$B/tvcc-apparati"
B403=$(curl -s -H "$MARIO" "$B/tvcc-apparati")
v "nessun nome interno/SQL nella risposta" "! grep -q 'permission denied\|tvcc_apparati\|hint\|details' <<<\"\$B403\""
t "risorse visibili all'utente" 200 'tvcc-log' -H "$VIG" "$B/risorse"
t "utente tecnico legge" 200 'TLC-01' "${SVC[@]}" "$B/tvcc-apparati?select=id_app"

echo "== scritture"
t "sessione: POST senza Origin bloccato (CSRF)" 403 'CSRF' -X POST -H "$VIG" -H "$J" -d '{"note":"x"}' "$B/tvcc-log"
t "sessione: POST da altro sito bloccato" 403 'CSRF' -X POST -H "$VIG" -H "$J" -H "Origin: http://malevolo.example" -d '{"note":"x"}' "$B/tvcc-log"
t "sessione: POST con Origin, campo forzato dal db" 201 '"insert_by":"Vito Vigile"' -X POST -H "$VIG" -H "$J" -H "$O" -H "Prefer: return=representation" -d '{"note":"ok"}' "$B/tvcc-log"
t "campo forzato inviato dal client: 403" 403 'Permessi insufficienti' -X POST -H "$VIG" -H "$J" -H "$O" -d '{"note":"x","insert_by":"Falso"}' "$B/tvcc-log"
t "programma: POST (niente CSRF, non e' un browser)" 201 '"insert_by":"svc_tvcc"' -X POST "${SVC[@]}" -H "$J" -H "Prefer: return=representation" -d '{"note":"da script"}' "$B/tvcc-log"
t "Content-Type non JSON: 415" 415 'JSON' -X POST -H "$VIG" -H "$O" -H "Content-Type: text/plain" -d 'x' "$B/tvcc-log"
t "messaggio del trigger remoto: 422" 422 'Descrizione troppo corta' -X POST -H "$VIG" -H "$J" -H "$O" -d '{"seg_o_ogg":"x","seg_o_desc":"a","segn_ogg_gen":"TLC-03"}' "$B/tvcc-ticket"
t "PATCH senza filtro: 400" 400 'almeno un filtro' -X PATCH -H "$ADMIN" -H "$J" -H "$O" -d '{"execution":true}' "$B/interventi-verde"
t "limite per riga (CHECK OPTION): 403" 403 'non rientra' -X POST -H "$COOP" -H "$J" -H "$O" -d '{"id_zona":3,"ty_int":"potature siepi","date_int":"2026-11-03","manteiner":"Manutentori interni"}' "$B/interventi-verde"
t "metodo PUT non consentito" 405 'Metodo' -X PUT -H "$ADMIN" -H "$J" -H "$O" -d '{}' "$B/tvcc-log"

echo "== funzioni (RPC)"
t "mail del ticket da sessione" 200 '"queued": ?true' -X POST -H "$ADMIN" -H "$J" -H "$O" -d '{"seg_id":1}' "$B/rpc/segnalazione-mail"
t "mail da programma: non consentita" 403 'solo da Lizmap' -X POST "${SVC[@]}" -H "$J" -d '{"seg_id":1}' "$B/rpc/segnalazione-mail"
t "calendario (kebab-case)" 200 '"role": ?"editor"' -H "$COOP" "$B/rpc/calendario-contesto"

echo "== percorsi e intestazioni"
t "percorso non previsto dalle URL del modulo" 404 '' -H "$MARIO" "$B/api_auth.utenti"
H=$(curl -s -o /dev/null -D - -H "$MARIO" "$B/segnalazioni?limit=1" | tr -d '\r')
# x-frame-options: DENY dal modulo, o SAMEORIGIN se Apache lo impone (anti-clickjacking: c'e' comunque CSP frame-ancestors 'none')
for x in 'x-content-type-options: nosniff' 'cache-control: no-store' 'x-frame-options: (deny|sameorigin)' 'content-security-policy: default-src' 'x-request-id:'; do
  v "intestazione $x" "grep -qiE '^$x' <<<\"\$H\""
done
v "nessun CORS" "! grep -qi '^access-control-allow-origin' <<<\"\$H\""

echo; echo "Superati: $OK   Falliti: $KO"; [ $KO -eq 0 ]

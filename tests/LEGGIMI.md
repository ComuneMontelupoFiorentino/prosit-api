# Collaudi

| File | Dove si lancia | Cosa serve |
|---|---|---|
| `collaudo_vm.sh` | **sulla VM**, dopo `prosit-api installa` | un utente tecnico Lizmap col diritto "Accesso alle API da programmi" |
| `installa_test.sh` | ambiente di prova | PostgreSQL 16 su 127.0.0.1:5433 (superuser `postgres`/`postgres`) |
| `test_db.sh` | ambiente di prova | dopo `installa_test.sh`, su un database `api` appena creato (alcuni test contano righe) |
| `test_lizmap.sh` | ambiente di prova | un Lizmap 3.9 di prova con il modulo e gli utenti sotto |
| `test_client.mjs` | ambiente di prova | Node 18+, un cookie di sessione del Lizmap di prova |
| `finto_postgrest.php` | ambiente di prova | sostituto di PostgREST (verifica RS256 con la chiave pubblica in `FINTO_PUB`) |
| `sorgenti.sql` | ambiente di prova | database esterni finti con gli stessi nomi di quelli reali |

## Sulla VM

```bash
/opt/prosit-api/bin/prosit-api verifica
/opt/prosit-api/tests/collaudo_vm.sh https://<server>/lizmap svc_prova:<password> [<PHPSESSID>]
```

## Ambiente di prova usato per lo sviluppo

1. PostgreSQL 16 su 127.0.0.1:5433; `tests/installa_test.sh <cartella>` crea i database finti,
   i ruoli (password di prova: authenticator `auth_test`, api_gateway `gw_test`,
   prosit_ro `ro_test`, prosit_rw `rw_test`) e il database `api`; poi `tests/test_db.sh`.
2. `php -S 127.0.0.1:3100 tests/finto_postgrest.php` (e 3101 per `/ready`) con `FINTO_PUB`
   = chiave pubblica di prova.
3. Lizmap 3.9.0 (`composer install` in `lizmap/`), configurato con `install/configurator.php`
   e `install/installer.php`; modulo installato con `prosit-api lizmap`
   (`LIZMAP_DIR`, `PROSIT_API_LOCALE`, `PHP_JWT`, `LIZMAP_URL` puntati all'ambiente di prova);
   in `var/config/localconfig.ini.php`: `[prositapi] config="<percorso>/prositapi.ini.php"`
   (solo in prova: in produzione il file e' `/etc/prosit-api/prositapi.ini.php` e non serve
   toccare la configurazione di Lizmap).
4. Utenti creati con `php console.php jcommunity:user:create` e gruppi con
   `acl2group:create` / `acl2user:addgroup`:

   | utente | gruppi | note |
   |---|---|---|
   | vigile | vigili, Polizia Municipale | sessione |
   | mario.rossi | utenti | sessione, solo lettura segnalazioni |
   | coop | man_verde_es | filtro per manutentore |
   | anna | admins | amministratrice |
   | svc_tvcc | vigili, tecnici_api | utente tecnico; `tecnici_api` ha il diritto `prosit.api.programmi` |
   | spento | tecnici_api | stato -1 (disattivato) |

5. `lizmap/www/_test_login.php` — **solo in prova, mai in produzione**: apre una vera
   sessione Lizmap (`jAuth::login`) e stampa il cookie, per non dover automatizzare il
   modulo di login. Attenzione: se e' la prima pagina chiamata dopo aver svuotato la cache, Jelix compila
   la configurazione di `index` con il nome di script sbagliato e `index.php` risponde 404 finche'
   non si svuota `temp/lizmap` (difetto solo di questo script di prova).
6. `tests/test_lizmap.sh http://127.0.0.1:8091` e
   `node tests/test_client.mjs "$(curl -s 'http://127.0.0.1:8091/_test_login.php?u=vigile&p=Vigile.2026')" http://127.0.0.1:8091 /api.php/prosit/v2`
   (dietro Apache: `tests/test_lizmap.sh http://127.0.0.1/lizmap` e `node tests/test_client.mjs "<cookie>"`).

Aggiornamento simulato: `install/backup.sh` → copia pulita di Lizmap 3.9.0 →
`install/restore.sh` → `install/installer.php` → `prosit-api lizmap` → `test_lizmap.sh` (37/37).
Modulo mancante dopo un aggiornamento fatto male → Lizmap 500 → `prosit-api lizmap` → 200.

## Prova "come sulla VM" (utente senza sudo, Apache + PHP-FPM, systemd)

Stessa disposizione della VM: utente `operatore` senza sudo, nel gruppo `www-data`;
`/opt/prosit-api` e `/etc/prosit-api` create una volta "dall'amministratore" (proprieta' di
`operatore`); Lizmap in `/var/www/lizmap-web-client-3.9.12` pubblicato da **Apache 2.4 +
PHP-FPM 8.3** con le configurazioni di `apache/`; `~/.pgpass` per il superuser; PostgREST
sostituito da un finto (`/usr/local/bin/prosit/postgrest-v16.5`), avviato come farebbe systemd:
variabili lette "da root" da `postgrest.env`, processo con l'utente `nobody` (come `DynamicUser`).
In questo contenitore systemd non gira: le unita' sono validate con `systemd-analyze verify`.

| Prova | Esito |
|---|---|
| `prosit-api installa` da `operatore` (Lizmap trovato dall'Alias di Apache, collegamento `postgrest` creato) | OK; istruzioni per l'amministratore stampate |
| permessi in `/etc/prosit-api`: `nobody` legge solo `postgrest.conf` e la chiave pubblica; `www-data` legge la configurazione del modulo; nessuno elenca la cartella | OK |
| `test_lizmap.sh` dietro Apache + PHP-FPM | 38/38 |
| `collaudo_vm.sh` / `test_client.mjs` | 19/19 · 10/10 |
| Basic su HTTP da un indirizzo non locale | 403 "solo su HTTPS" |
| Basic su HTTPS, certificato autofirmato verificato con `--cacert` | 200 |
| `apachectl configtest` con `apache/000-default.conf` e `apache/default-ssl.conf` | Syntax OK |
| `ruota-jwt` (ricarica via `NOTIFY pgrst`), `manutenzione` (backup + pulizia), `postgrest riavvia` senza regola sudo | OK; il riavvio spiega cosa chiedere |
| aggiornamento 3.9.12 → "3.9.13" con collegamento `/var/www/lizmap-web-client` (backup.sh, restore.sh, installer.php, `ln -sfn`, `prosit-api lizmap`) | 37/37 |
| cache di Lizmap scritta da `www-data` (cartelle 755) | `clean_vartmp.sh` ufficiale non riesce a cancellarla (in silenzio) e cancella i log di Lizmap; `prosit-api lizmap` ora la svuota davvero e non tocca i log |
| modulo dimenticato → Lizmap 500 → `verifica` lo segnala → `prosit-api lizmap` | 200 |

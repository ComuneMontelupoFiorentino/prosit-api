# Prosit API v2 — PostgREST con autenticazione Lizmap

API REST dei servizi Prosit (schede, registro TVCC, calendario verde, manomissioni,
illuminazione) generate da **PostgREST** su un unico database `api`, con utenti, gruppi e
sessioni **di Lizmap** e permessi gestiti **in PostgreSQL**.

Indirizzo: **`https://<server>/lizmap/api.php/prosit/v2/`** — il punto di ingresso `api.php`
che Lizmap ha gia' (nessuna modifica alle URL di Apache). La v1 (`/lizmap/prosit/api/v1/`)
resta attiva durante la migrazione.

| Documento | Contenuto |
|---|---|
| [INSTALLAZIONE.md](INSTALLAZIONE.md) | **installazione sulla VM passo per passo**, con i comandi per l'amministratore |
| questo file | architettura, installazione, Apache, **aggiornamento di Lizmap**, esercizio |
| [docs/NUOVE-API.md](docs/NUOVE-API.md) | come aggiungere risorse e funzioni in futuro |
| [docs/MIGRAZIONE.md](docs/MIGRAZIONE.md) | da v1 a v2: endpoint e modifiche ai servizi |
| [docs/SICUREZZA-AGID.md](docs/SICUREZZA-AGID.md) | verifica rispetto alle linee guida AgID/ACN |
| [config/api.yaml](config/api.yaml) | **unico file** di risorse, gruppi, database e servizi |
| [openapi/prosit-api-v2.yaml](openapi/prosit-api-v2.yaml) | contratto OpenAPI 3 (generato) |
| [tests/LEGGIMI.md](tests/LEGGIMI.md) | come sono stati eseguiti i collaudi |

## 1. Architettura

```
 Browser (cookie di Lizmap)            Programma (utente tecnico Lizmap, HTTP Basic su HTTPS)
            │                                       │
            ▼                                       ▼
 Apache ─► /lizmap/api.php/prosit/v2/...   (punto di ingresso "api" di Lizmap, gia' esistente)
            │
            ▼
 MODULO LIZMAP "prositapi"  (lizmap/lizmap-modules/prositapi, ~350 righe, solo componenti Jelix)
   1. chi sei:   jAuth  — sessione di Lizmap, oppure login Basic (stesse password, stesso
                          blocco degli utenti disattivati)
   2. puo' farlo: jAcl2  — Basic solo per chi ha il diritto "prosit.api.programmi"
                          (Amministrazione → Diritti)
   3. gruppi:    jAcl2DbUserGroup — i gruppi Lizmap dell'utente, a OGNI richiesta
   4. ruolo:     api_auth.gateway_utente() → ruolo PostgreSQL lz_<utente> membro dei grp_*
   5. token RS256 di 60 s firmato con firebase/php-jwt (mai visto dal client)
            │  http://127.0.0.1:3100
            ▼
 POSTGREST  → verifica il token → SET ROLE lz_<utente> → db-pre-request
            │
            ▼
 DATABASE "api"
   api.*      viste e funzioni pubblicate (GRANT ai grp_*)
   fdw_*      tabelle esterne (postgres_fdw), utenti prosit_ro / prosit_rw
            │
            ▼
 segnalazioni_23 · llpp · vp · ip_2020_2022 (database esistenti, invariati)
```

**Codice nostro al minimo.** Autenticazione, sessioni, password, utenti disattivati, gruppi
e diritti sono **componenti standard di Lizmap/Jelix** (`jAuth`, `jAcl2`, punto di ingresso
`api.php`, `jIRestController`); la firma del token e' **firebase/php-jwt** (libreria
standard, caricata via FTP); REST, filtri, paginazione e transazioni sono **PostgREST**; i
permessi sono **GRANT di PostgreSQL** (si leggono con `\dp api.*`, si verificano con
`api_admin.verifica()`). Il modulo traduce soltanto "utente Lizmap" in "ruolo PostgreSQL".

**Un solo database, dati dove sono.** Il database `api` non copia dati: le viste leggono e
scrivono le tabelle originali con `postgres_fdw`. Filtri e ordinamenti vengono eseguiti sul
database di origine.

**Due modi di autenticarsi** (entrambi verificati a ogni richiesta):

| | Sessione Lizmap | Utente tecnico (programmi) |
|---|---|---|
| chi | utente collegato a Lizmap, dal browser | programma/script con un proprio utente Lizmap |
| come | cookie di Lizmap (automatico) | `Authorization: Basic` (utente e password Lizmap), **solo HTTPS** |
| abilitazione | qualunque utente attivo | l'amministratore assegna il diritto **"Accesso alle API da programmi"** (sezione "Prosit API") a un gruppo, da *Amministrazione → Diritti* |
| permessi sui dati | quelli dei suoi gruppi | quelli dei suoi gruppi |
| CSRF | modifiche solo con `Origin` dello stesso sito | non applicabile; non crea sessioni |
| revoca | logout / scadenza sessione | utente disattivato, password cambiata, gruppo o diritto tolto in Lizmap: effetto immediato |

## 2. Dove va ogni cosa sulla VM

Cartelle secondo lo standard Linux (FHS): software in `/opt`, configurazione e segreti in
`/etc`, backup in `/var/backups`. **`/srv` resta ai progetti e ai dati QGIS** (e' fatta per i
dati che il server pubblica, non per programmi e segreti).

| Cartella | Contenuto | Chi la scrive |
|---|---|---|
| `/opt/prosit-api` | questo pacchetto (software) | il tuo utente (FTP) |
| `/opt/prosit-api/lib/php-jwt` | libreria firebase/php-jwt 7.2.1, **inclusa nel pacchetto** (rilascio ufficiale, licenza BSD) | — |
| `/etc/prosit-api` | segreti e configurazione, generati dall'installazione: **mai nel pacchetto** | `prosit-api` |
| `/usr/local/bin/prosit/` | `postgrest` (binario, o collegamento a `postgrest-v16.x`) e il collegamento `prosit-api` | il tuo utente (FTP) / `prosit-api` |
| `/var/www/lizmap-web-client` | collegamento alla versione di Lizmap in uso (`lizmap-web-client-3.9.12`) | l'amministratore |
| `…/lizmap/lizmap-modules/prositapi` | il modulo Lizmap (copiato da `prosit-api lizmap`) | `prosit-api` |
| `/var/backups/prosit-api` | backup settimanali (segreti + database `api`, ultimi 8) | timer systemd |
| `/etc/systemd/system/` | `postgrest-prosit-api.service`, `prosit-api-manutenzione.{service,timer}` | l'amministratore, una volta |

I log di PostgREST vanno nel journal di sistema: `journalctl -u postgrest-prosit-api`.

```
config/api.yaml               risorse, gruppi, database esterni, servizi
bin/genera_api.py             YAML -> SQL, postgrest.conf, OpenAPI
bin/prosit-api                installa | applica | lizmap | rimuovi-modulo | verifica | systemd | postgrest | manutenzione | backup | ruota-jwt | pulizia
bin/jwk.php                   chiave pubblica PEM -> JWK per PostgREST
lizmap-module/prositapi/      il modulo Lizmap (viene COPIATO in lizmap/lizmap-modules)
etc/prositapi.ini.php.esempio modello della configurazione del modulo
systemd/                      modelli delle unita' systemd (prosit-api systemd li compila)
apache/                       proposta di 000-default.conf e default-ssl.conf (vedi §4)
sql/00..40_*.sql              ruoli, database "api", struttura, utenti/audit, procedure di amministrazione
sql/60_servizi.sql            RPC: segnalazione-mail, calendario-*
sql/generato/50_risorse.sql   GENERATO da api.yaml
postgrest/prosit-api.conf     configurazione di PostgREST (generata)
assets/prosit-api-v2.js       client JS (stessi metodi di Prosit.api v1)
openapi/prosit-api-v2.yaml    contratto OpenAPI 3.0 (GENERATO)
tests/                        collaudi
```

## 3. Installazione sulla VM

Passo per passo, con i comandi esatti: **[INSTALLAZIONE.md](INSTALLAZIONE.md)**. In sintesi:

1. **Tu, senza root**: pacchetto in `~/prosit-api`, `~/.pgpass` per il superuser, poi
   `PG_ADMIN=<superuser> ~/prosit-api/bin/prosit-api installa`. Finche' `/etc/prosit-api` non
   esiste l'installazione lavora "in preparazione": segreti e configurazione in
   `~/prosit-api-config` (gia' con i percorsi definitivi), database `api` completo, **prova di
   PostgREST** (avvio temporaneo, collegamento al database, token del modulo accettati, token
   falsi rifiutati), modulo in Lizmap, e lo script **`per-amministratore.sh`**.
2. **Amministratore, una volta**: `sudo bash ~<utente>/prosit-api-config/per-amministratore.sh`.
   Mette il tuo utente in `www-data`, copia software in `/opt/prosit-api` e configurazione in
   `/etc/prosit-api` con i permessi giusti, aggiunge in `pg_hba.conf` la password obbligatoria solo per
   gli utenti dei collegamenti tra database (`prosit_api_ro`/`prosit_api_rw`, se serve) e completa il
   database `api`, installa e avvia il servizio PostgREST e il timer di
   manutenzione (systemd), aggiunge ad Apache `CGIPassAuth On` e `SSLProtocol`, fa
   `apachectl configtest` e ricarica Apache (se il test fallisce rimette i file e non ricarica;
   se PostgREST non parte si ferma prima di toccare Apache).
3. **Tu**: esci e rientri da SSH, `/opt/prosit-api/bin/prosit-api verifica`, cancelli
   `~/prosit-api-config`, assegni il diritto in Lizmap e lanci il collaudo (§3.4).

Il servizio `postgrest-prosit-api` usa un **utente di sistema temporaneo** creato da systemd
(`DynamicUser`), file system in sola lettura, nessun privilegio, riavvio automatico; la password
del database la legge systemd da `/etc/prosit-api/postgrest.env` (0600), non il servizio. Le
modifiche successive (`applica`, `ruota-jwt`) PostgREST le rilegge da solo tramite il database
(`NOTIFY pgrst`), senza privilegi. Facoltativi, commentati in fondo allo script: lettura dei log
(`systemd-journal`) e regola sudo per riavviare solo PostgREST (poi `SUDO_SYSTEMCTL=1` in
`/etc/prosit-api/impostazioni.env`).

### 3.4 Lizmap e collaudo

1. **Lizmap → Amministrazione → Gruppi di utenti**: creare un gruppo, es. `tecnici_api`;
   **Amministrazione → Diritti**: a `tecnici_api` assegnare "*Accesso alle API da programmi*"
   (sezione "Prosit API"). Creare gli utenti tecnici (uno per programma) e metterli in
   `tecnici_api` **e** nei gruppi funzionali che determinano cosa possono fare (es. `vigili`).
   Non assegnare il diritto a gruppi di persone.
2. `/opt/prosit-api/bin/prosit-api verifica` — nessun `ERR`.
3. `/opt/prosit-api/tests/collaudo_vm.sh http://127.0.0.1/lizmap utente_tecnico:password`
   (dalla VM; da un altro PC con `https://`).

`pg_hba.conf`: la riga predefinita `host all all 127.0.0.1/32 scram-sha-256` basta.

**Aggiornare questo pacchetto**: sostituire via FTP i file di `/opt/prosit-api`, poi `prosit-api applica` e, se e' cambiato il modulo, `prosit-api lizmap`.

## 4. Apache

Le configurazioni attuali (`000-default.conf`, `default-ssl.conf`) vanno gia' bene: pubblicano solo
`lizmap/www`, HTTPS e' attivo. **Per le URL della API non serve nulla** (`/lizmap/api.php` esiste gia').
Le due modifiche necessarie (punti 2 e 3) le fa **`per-amministratore.sh`** sui file attuali,
senza toccare altro. In `apache/` ci sono anche le due configurazioni complete con tutte le modifiche
proposte (comprese quelle facoltative), ognuna preceduta da `# <<< PROSIT`; collaudate con
`apachectl configtest` e con Apache 2.4 + PHP-FPM 8.3 reali. **Attenzione**: quei file usano il
percorso del collegamento `/var/www/lizmap-web-client` (punto 1): copiarli solo dopo averlo creato.

1. **Percorso stabile di Lizmap** (facoltativo, non serve alla API). Oggi l'Alias punta a
   `/var/www/lizmap-web-client-3.9.12/…`: a ogni aggiornamento andrebbe cambiato Apache. Con un
   collegamento lo si cambia una volta sola:
   ```bash
   ln -sfn lizmap-web-client-3.9.12 /var/www/lizmap-web-client       # amministratore (/var/www e' di root)
   ```
   e in entrambi i file `Alias` e `<Directory>` su `/var/www/lizmap-web-client/lizmap/www`.
   Da li' in poi un aggiornamento e' "nuova cartella + cambio del collegamento" (§5), e tornare
   indietro e' rimettere il collegamento. (Se si preferisce non farlo, `prosit-api` segue comunque
   l'Alias di Apache.)
2. **`CGIPassAuth On`** nel blocco `<Directory …/lizmap/www>` di entrambi i file: garantisce che
   l'intestazione `Authorization` (utenti tecnici) arrivi a PHP anche con PHP-FPM. Nella prova con
   PHP-FPM di Debian arrivava anche senza; e' innocua e protegge da configurazioni diverse.
3. **`SSLProtocol -all +TLSv1.2 +TLSv1.3`** nel 443 (raccomandazioni AgID/ACN su TLS).
4. **Certificato**: oggi e' quello autofirmato (`snakeoil`). Il browser funziona dopo l'avviso; i
   programmi devono **verificare** il certificato, non ignorarlo (`curl --cacert <certificato>`,
   mai `-k`). Appena c'e' il certificato dell'ente: togliere il commento a `Redirect permanent`
   nel :80 (tutto su HTTPS) e a `Strict-Transport-Security` nel 443. **Non** attivare HSTS con il
   certificato autofirmato: i browser non permetterebbero piu' di proseguire.

Volutamente **non** c'e' un redirect da HTTP a HTTPS solo per la API: un programma configurato
male manderebbe comunque la password in chiaro alla prima richiesta. Il modulo invece risponde
403 "Le credenziali si inviano solo su HTTPS", cosi' l'errore si vede subito.

Dopo le modifiche: `apachectl configtest` e ricaricare Apache.

## 5. Aggiornamento di Lizmap — cosa fare perche' non si rompa nulla

Cosa sta dove (e perche' un aggiornamento non lo tocca):

| Cosa | Dove | Nell'aggiornamento |
|---|---|---|
| modulo `prositapi` | `lizmap/lizmap-modules/prositapi` (copia) | conservato da `backup.sh`/`restore.sh` ufficiali; altrimenti lo reinstalla `prosit-api lizmap` |
| registrazione delle URL e attivazione | `lizmap/var/config/localurls.xml`, `localconfig.ini.php` | conservati da `backup.sh`/`restore.sh` |
| diritto `prosit.api.programmi` e sue assegnazioni | database di Lizmap (`var/db/jauth.db`) | conservati |
| configurazione e segreti del modulo | `/etc/prosit-api` | fuori da Lizmap: mai toccati |
| software, php-jwt, PostgREST, servizio | `/opt/prosit-api`, `/usr/local/bin/prosit`, systemd | fuori da Lizmap: mai toccati |
| profilo database | creato in memoria dal modulo | nessuna modifica a `profiles.ini.php` |
| autoload | nessuno | se php-jwt mancasse risponderebbe 503 **solo la API**, Lizmap no |

**Procedura** (quella ufficiale di Lizmap, piu' un comando). Su questa VM `/var/www` e' di root:
la nuova cartella e il cambio del collegamento li fa l'amministratore, il resto il tuo utente.
Esempio da 3.9.12 a 3.9.13, con il collegamento di §4:

```bash
D=/var/backups/lizmap-$(date +%Y%m%d); mkdir -p $D
/var/www/lizmap-web-client/lizmap/install/backup.sh $D               # 1. backup ufficiale
# 2. nuova versione scompattata in /var/www/lizmap-web-client-3.9.13 (FTP o unzip)
/var/www/lizmap-web-client-3.9.13/lizmap/install/restore.sh $D       # 3. ripristino ufficiale
php /var/www/lizmap-web-client-3.9.13/lizmap/install/installer.php   # 4. aggiornamento ufficiale
ln -sfn lizmap-web-client-3.9.13 /var/www/lizmap-web-client          #    passaggio alla nuova versione
/opt/prosit-api/bin/prosit-api lizmap                                # 5. modulo + cache + permessi + prova
```

Il passo 5 rimette i permessi che Apache richiede su `var/config`, `var/db`, `temp` (quello che
farebbe `install/set_rights.sh`, che serve root) e svuota la cache compilata di Lizmap anche
quando i file sono di `www-data` (lo script ufficiale `clean_vartmp.sh` in quel caso fallisce in
silenzio e, in piu', cancella i log di Lizmap: non lo usiamo). Tenere `lizmap-web-client-3.9.12`
finche' tutto e' controllato: tornare indietro e' `ln -sfn lizmap-web-client-3.9.12 …`.

Il passo 5 e' rilanciabile e innocuo. Va lanciato **anche se l'aggiornamento e' stato fatto in
altro modo**: se `localurls.xml` cita il modulo ma la cartella non c'e', **tutto Lizmap** risponde
500 — `prosit-api lizmap` lo ripara in pochi secondi, e `prosit-api verifica` lo segnala.

**Per togliere il modulo** non cancellare la cartella a mano: usare
`prosit-api rimuovi-modulo` (disattiva con `configurator.php -r`, poi cancella).
Lizmap continua a funzionare; i dati e il database `api` restano.

**Salti di versione importanti** (nuovo Jelix, es. Lizmap 4): il modulo dichiara solo
"Jelix ≥ 1.8", quindi non blocca l'installer; dopo l'aggiornamento `prosit-api lizmap`
e `tests/collaudo_vm.sh` dicono subito se la API funziona. In caso di problemi:
`prosit-api rimuovi-modulo` e Lizmap torna come prima, senza la API v2.

## 6. Uso

```bash
B=https://<server>/lizmap/api.php/prosit/v2
U="-u svc_tvcc:password"           # utente tecnico
curl $U "$B/segnalazioni?stato_segn=eq.Assegnata&select=seg_id,seg_o_ogg&order=seg_id.desc&limit=20"
curl $U -H "Prefer: count=exact" "$B/segnalazioni?limit=1"     # totale in Content-Range
curl $U "$B/rpc/io"                                             # chi sono e che ruoli ho
curl $U -H "Content-Type: application/json" -d '{"note":"ok"}' "$B/tvcc-log"
curl $U "$B/rpc/calendario-interventi?dal=2026-11-01&al=2026-11-30"
```

Dal browser (pagine sotto `/lizmap/prosit/`, sessione di Lizmap):

```html
<script src="../assets/prosit.js"></script>
<script src="../assets/prosit-api-v2.js"></script>
```
```js
const aperte = await Prosit.api.list('segnalazioni', { segn_ogg_gen: 'TLC-01', stato_segn__not: 'Verificata e chiusa' });
const t = await Prosit.api.one('segnalazioni', 123);
await Prosit.api.create('tvcc-log', { note: 'Tutto funzionante' });
await Prosit.api.rpc('segnalazione-mail', { seg_id: 123 });
```

Gli errori sono `application/problem+json` (RFC 7807) con `detail` leggibile e `request_id`;
gli accessi Basic rifiutati finiscono nel log di Lizmap (`lizmap/var/log/`).

## 7. Esercizio

`prosit-api` e' anche in `/usr/local/bin/prosit/prosit-api`. Tutto con il tuo utente.

| Operazione | Comando |
|---|---|
| modificare risorse, gruppi, servizi | modificare `config/api.yaml` → `prosit-api applica` |
| dopo un aggiornamento di Lizmap | `prosit-api lizmap` |
| controlli di sicurezza e funzionamento | `prosit-api verifica` |
| stato di PostgREST | `prosit-api postgrest stato` (o `systemctl status postgrest-prosit-api`) |
| errori | log di Lizmap (`lizmap/var/log`), `journalctl -u postgrest-prosit-api` |
| chi ha modificato cosa | `SELECT * FROM api_auth.audit ORDER BY ts DESC` (database `api`) |
| backup | automatico la domenica in `/var/backups/prosit-api` (ultimi 8); a mano: `prosit-api backup` |
| abilitare un programma | utente tecnico in un gruppo col diritto "Accesso alle API da programmi" |
| togliere l'accesso a un programma | disattivare l'utente o toglierlo dal gruppo, in Lizmap (immediato) |
| ruotare le chiavi del token interno | `prosit-api ruota-jwt` (nessun disservizio), poi `tests/collaudo_vm.sh` |
| aggiornare PostgREST | nuovo file in `/usr/local/bin/prosit`, `ln -sfn postgrest-v16.6 /usr/local/bin/prosit/postgrest`, riavvio (amministratore, o `prosit-api postgrest riavvia` con la regola sudo), `tests/collaudo_vm.sh` |
| aggiornare php-jwt | sostituire `/opt/prosit-api/lib/php-jwt/src`, `prosit-api verifica` |
| modificare il modulo | modificare `lizmap-module/prositapi`, alzare la versione in `module.xml`, `prosit-api lizmap` |

## 8. Collaudi eseguiti

Su Lizmap 3.9.0 reale (Jelix 1.8, jcommunity), PostgreSQL 16 con database finti con gli
stessi nomi di quelli reali, firebase/php-jwt 7.2.1:

| Suite | Cosa verifica | Esito |
|---|---|---|
| `tests/test_db.sh` | richieste eseguite come PostgREST (authenticator, SET ROLE, claims, pre-request): GRANT per gruppo, colonne forzate, CHECK OPTION, audit, RPC, nessuna scorciatoia tra ruoli | 57/57 |
| `tests/test_lizmap.sh` | modulo in Lizmap **dietro Apache 2.4 + PHP-FPM 8.3** con le configurazioni di `apache/`: sessione vera, Basic, utente disattivato, diritto jAcl2, gruppi Lizmap → GRANT, CSRF, errori senza dettagli interni, intestazioni, nessun cookie per Basic | 38/38 |
| Basic su HTTP da un altro indirizzo / su HTTPS con certificato verificato | 403 "solo su HTTPS" / 200 | OK |
| `tests/test_client.mjs` | client JS: filtri, `me()`, `one()`, `create()`, `rpc()`, errori | 10/10 |
| `tests/collaudo_vm.sh` | collaudo da lanciare sulla VM | 19/19 (in prova) |
| installazione "come sulla VM" | utente senza sudo nel gruppo `www-data`, `/opt` e `/etc/prosit-api` create dall'"amministratore", Lizmap in cartella versionata con Alias in Apache: `installa`, permessi dei file letti dall'utente del servizio (`nobody` come `DynamicUser`), `ruota-jwt`, `manutenzione`, unita' systemd validate con `systemd-analyze verify` | OK |
| aggiornamento di Lizmap 3.9.12 → "3.9.13" | procedura di §5 con il collegamento, cache scritta da `www-data` | 37/37, cache svuotata |

Il binario di PostgREST non era scaricabile nell'ambiente di prova: e' stato usato un
sostituto (`tests/finto_postgrest.php`) che verifica la firma RS256 come PostgREST, e systemd non
gira nel contenitore di prova (le unita' sono state validate, non avviate). Sulla VM
`prosit-api verifica` e `tests/collaudo_vm.sh` ripetono i controlli con PostgREST vero e systemd,
compresi i token non firmati e, dopo `ruota-jwt`, la rilettura della chiave.


## Parte di Prosit

Questo componente fa parte di **[Prosit](https://github.com/ComuneMontelupoFiorentino/prosit)**,
il Sistema Informativo Territoriale del Comune di Montelupo Fiorentino. Nel repository
[prosit](https://github.com/ComuneMontelupoFiorentino/prosit) ci sono l'architettura, l'elenco
di tutti i componenti (topic [`prosit`](https://github.com/search?q=org%3AComuneMontelupoFiorentino+topic%3Aprosit&type=repositories))
e le versioni che funzionano insieme.

## Licenza

Rilasciato dal Comune di Montelupo Fiorentino con licenza [EUPL-1.2](LICENSE) (Licenza Pubblica dell'Unione Europea).
La libreria firebase/php-jwt in `lib/php-jwt/` mantiene la propria licenza (BSD-3-Clause).

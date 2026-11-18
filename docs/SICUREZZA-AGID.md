# Verifica di sicurezza rispetto alle linee guida AgID (e ACN)

Riferimenti usati:

- **AgID — Linee guida per lo sviluppo del software sicuro** (2017), con gli allegati sul ciclo
  di sviluppo sicuro, sullo sviluppo sicuro di codice, sulla configurazione del software di base e
  sulla modellazione delle minacce. <https://www.agid.gov.it/it/sicurezza/cert-pa/linee-guida-sviluppo-del-software-sicuro>
- **AgID — Linee guida Tecnologie e standard per la sicurezza dell'interoperabilita' tramite API**
  (Determinazione 547/2021): HTTPS obbligatorio, JWT secondo RFC 8725, OAuth2 per i casi
  machine-to-machine tra enti.
- **AgID — Linee guida sull'interoperabilita' tecnica (ModI)**, Allegato 4 "Raccomandazioni di
  implementazione" (codici RAC_*).
- **ACN e Garante privacy — Linee guida funzioni crittografiche: conservazione delle password** (dicembre 2023).
- OWASP API Security Top 10 (2023), come riferimento tecnico comune.

Legenda: ✅ soddisfatto nel codice · ⚠️ da fare sulla VM o a livello organizzativo · ➖ non applicabile, motivato.

**Principio seguito: codice nostro al minimo.** Le parti delicate (password, sessioni, utenti
disattivati, gruppi, diritti, firma dei token, REST, SQL) sono svolte da componenti standard e
mantenuti: Lizmap/Jelix (`jAuth`, `jAcl2`, punto di ingresso `api.php`), firebase/php-jwt,
PostgREST, PostgreSQL. Il codice nostro e' un controller di ~350 righe
(`lizmap-module/prositapi/controllers/v2.classic.php`) e le funzioni SQL che traducono i
gruppi Lizmap in ruoli PostgreSQL.

## 1. Autenticazione e sessioni

| Requisito | Come | Dove | |
|---|---|---|---|
| Identita' da una fonte unica | utenti, password e gruppi sono quelli di Lizmap, letti a ogni richiesta con le API di Jelix; nessuna seconda anagrafica | `jAuth`, `jAcl2DbUserGroup` | ✅ |
| Sessione del browser | la stessa sessione di Lizmap (punto di ingresso `api.php` con il plugin `auth` di Jelix): scadenza, logout e rigenerazione li gestisce Lizmap | `jAuth::isConnected` | ✅ |
| Utente disattivato/rimosso = accesso negato subito | il login Basic usa `jAuth::login`, che applica i controlli di jCommunity (stato disattivato o cancellato → rifiutato); testato | `tests/test_lizmap.sh` | ✅ |
| Credenziali per programmi | utenti tecnici Lizmap, uno per programma, con HTTP Basic **solo su HTTPS** (RFC 7617); niente credenziali nuove da custodire: valgono password, scadenze e politiche di Lizmap | `v2.classic.php::autentica` | ✅ |
| Abilitazione controllata dall'amministratore | diritto jAcl2 `prosit.api.programmi`, assegnato dal pannello *Amministrazione → Diritti*; verificato a ogni richiesta | `install/install.php`, `jAcl2::check` | ✅ |
| Le richieste Basic non creano sessioni | dopo ogni richiesta Basic: `jAuth::logout()` e nessun `Set-Cookie` (testato) | `v2.classic.php` | ✅ |
| Conservazione delle password (ACN/Garante) | gestita da Lizmap: `password_hash_method = 1` → `password_hash()` di PHP (bcrypt), con riconversione automatica dei vecchi hash al login | `auth.coord.ini.php` di Lizmap | ✅ |
| Protezione da tentativi ripetuti | ogni Basic errato: ritardo di 0,5 s, risposta 401 uguale per utente inesistente e password errata, riga nel log di Lizmap. Per un blocco per IP: **fail2ban** sul log (vedi §6) | `v2.classic.php` | ✅ + ⚠️ fail2ban |
| Password degli utenti tecnici | lunghe e casuali (≥ 20 caratteri), una per programma, cambiate quando cambia chi gestisce il programma | — | ⚠️ processo |

## 2. Autorizzazione (OWASP API1, API3, API5)

| Requisito | Come | |
|---|---|---|
| Privilegio minimo, gestito in PostgreSQL | ogni utente diventa il ruolo `lz_<utente>`, membro solo dei `grp_*` dei suoi gruppi Lizmap; i permessi sono `GRANT` sulle viste e sulle colonne | ✅ |
| Gruppi Lizmap → ruoli PostgreSQL allineati | `api_auth.gateway_utente` concede/revoca i `grp_*` a ogni richiesta (tolto un gruppo in Lizmap, il permesso sparisce alla richiesta successiva) | ✅ |
| Nessuna scorciatoia tra ruoli | `authenticator` NOINHERIT; appartenenze `SET FALSE` (non si puo' `SET ROLE` a un gruppo); `api_rolemgr` solo CREATEROLE su PostgreSQL 16 | ✅ |
| Proprieta' degli oggetti (API3) | colonne esposte elencate una per una; colonne scrivibili con GRANT per colonna; chi ha inserito/modificato e' imposto dal database (`DEFAULT` della vista), se il client lo invia → 403 | ✅ |
| Righe per ufficio/manutentore (API1) | `filtro` + `WITH CASCADED CHECK OPTION` + `security_barrier` | ✅ |
| Funzioni | `SECURITY DEFINER`, `search_path` fisso, `REVOKE ... FROM PUBLIC`, `GRANT` a un gruppo | ✅ |
| Modulo Lizmap con privilegi minimi | l'utente `api_gateway` puo' solo eseguire `api_auth.gateway_utente`; non legge tabelle | ✅ |
| Database esterni | letti con `prosit_api_ro`, scritti con `prosit_api_rw`: utenti propri della Prosit API, con password casuali, membri di `prosit_ro` / `prosit_rw` (stessi permessi, senza poterne assumere l'identita'); scelti dal proprietario della vista; riconoscibili in `pg_stat_activity` | ✅ |
| `pg_hba.conf` della VM | oggi **`trust` per tutti gli utenti da 127.0.0.1 e ::1**: qualunque processo locale (anche PHP di Apache) puo' collegarsi come qualunque utente, superuser compresi, senza password. La Prosit API non ne dipende (password obbligatoria per i suoi utenti, aggiunta da `per-amministratore.sh`). Consigliato passare a `scram-sha-256` anche per gli altri, dopo aver controllato quali servizi si collegano senza password (`log_connections = on` per qualche giorno) | ⚠️ **da sistemare (esistente)** |
| Verifica automatica | `api_admin.verifica()`: viste senza proprietario corretto, funzioni eseguibili da PUBLIC, ruoli con privilegi eccessivi | ✅ |

## 3. Input, output, errori (Linee guida sviluppo sicuro — allegato codice)

| Requisito | Come | |
|---|---|---|
| Nessuna SQL injection | PostgREST usa query parametrizzate; nel modulo una sola query, con parametri (`jDb::prepare`); nelle funzioni solo `format(%I/%L)` e `EXECUTE ... USING` | ✅ |
| Percorsi ammessi | solo `/<risorsa>` e `/rpc/<funzione>` in kebab-case (espressione regolare in `urls.xml`): schemi interni non raggiungibili (testato) | ✅ |
| Metodi e intestazioni | `PUT` rifiutato; `PATCH`/`DELETE` solo con un filtro; `Accept` e `Prefer` da elenco chiuso; `Content-Type` JSON obbligatorio; corpo massimo 1 MB | ✅ |
| CSRF | modifiche con la sessione del browser solo se `Origin`/`Referer` e' lo stesso sito (o in `origini_consentite`); nessun CORS | ✅ |
| Errori senza dettagli interni (API8) | `application/problem+json` (RFC 7807) con messaggio generico e `request_id`; mai SQL, nomi di tabelle o tracce | ✅ |
| Intestazioni di sicurezza | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'none'`, `Cache-Control: no-store` | ✅ |
| Limiti di risorse (API4) | `db-max-rows` 5000, `statement_timeout` 30 s per ruolo, pool limitato, `CONNECTION LIMIT` | ✅ |

## 4. Tracciabilita'

| Requisito | Come | |
|---|---|---|
| Tracciabilita' delle modifiche | `api_auth.audit`: utente, ruolo, tipo di accesso (sessione/programma), metodo, percorso; conservazione con `pulisci_audit` (365 gg) | ✅ |
| Accessi rifiutati | log di Lizmap (`lizmap/var/log/`), senza password | ✅ |
| Log senza segreti | mai password, token o cookie | ✅ |
| Monitoraggio | controllare periodicamente gli accessi Basic rifiutati (log di Lizmap) e `journalctl -u postgrest-prosit-api` | ⚠️ processo |

## 5. Crittografia e token interno

| Requisito | Come | |
|---|---|---|
| JWT secondo RFC 8725 | firmato con **firebase/php-jwt** (libreria standard), algoritmo fisso RS256 (3072 bit); PostgREST verifica con la sola chiave pubblica, `aud` e `exp`; `alg:none` e HS256 rifiutati (`tests/collaudo_vm.sh`) | ✅ |
| Token mai esposti | il token vive 60 s, solo tra modulo e PostgREST su 127.0.0.1; il client non lo vede | ✅ |
| Generazione casuale | `random_bytes` (CSPRNG) per `jti` e id richiesta; segreti con `openssl rand` | ✅ |
| Segreti fuori dal codice e da Lizmap | `/etc/prosit-api`, fuori dalle cartelle pubblicate da Apache: cartella 0711 (attraversabile, non elencabile), segreti 0600 (la password di PostgREST la legge solo systemd), i due file che servono a PHP 0640 con gruppo `www-data`, l'utente del servizio PostgREST legge solo configurazione e chiave pubblica (verificato); nessun segreto nel pacchetto. `prosit-api verifica` controlla i permessi | ✅ |
| Rotazione | `prosit-api ruota-jwt` senza disservizio | ✅ |

## 6. Configurazione del server (allegato "software di base")

| Requisito | Come | |
|---|---|---|
| HTTPS obbligatorio per le API (LG sicurezza API, ModI ID_AUTH_CHANNEL_01) | il modulo rifiuta Basic su HTTP (tranne da localhost) | ✅ nel codice |
| TLS sul server | **Lizmap oggi risponde su `http://<server>`**: configurare un certificato e HTTPS (TLS 1.2 minimo, 1.3 preferito), reindirizzare HTTP→HTTPS e aggiungere in Apache `Header always set Strict-Transport-Security "max-age=31536000"` | ⚠️ **bloccante per gli utenti tecnici** |
| PHP-FPM | `CGIPassAuth On` sulla cartella `lizmap/www` (vedi README §4), altrimenti il Basic non arriva a PHP | ⚠️ se si usa FPM |
| Blocco dei tentativi per IP | fail2ban con un filtro sulla riga `prositapi: accesso Basic rifiutato` del log di Lizmap (es. 10 errori in 10 minuti → blocco 1 ora) | ⚠️ consigliato |
| PostgREST isolato | solo 127.0.0.1; servizio systemd con utente temporaneo senza privilegi (`DynamicUser`), `ProtectSystem=strict`, `NoNewPrivileges`, nessuna capability, `MemoryMax`; riavvio automatico | ✅ |
| TLS | `SSLProtocol -all +TLSv1.2 +TLSv1.3` (proposta in `apache/default-ssl.conf`) | ⚠️ da applicare |
| Database | PostgreSQL ≥ 16 obbligatorio (controllato), `pg_hba` solo da 127.0.0.1 con scram-sha-256 | ✅ |
| Aggiornamenti | procedura documentata (README §5); il modulo non blocca l'installer di Lizmap; `prosit-api verifica` controlla che tutto sia allineato | ✅ |

## 7. Raccomandazioni ModI (Allegato 4)

| Codice | Raccomandazione | Stato |
|---|---|---|
| RAC_GEN_001 | contratto OpenAPI 3 | ✅ `openapi/prosit-api-v2.yaml` (generato, validato) |
| RAC_GEN_002 | versione nell'URL | ✅ `/v2` |
| RAC_REST_NAME_002 | percorsi in kebab-case | ✅ il modulo traduce in snake_case per il database |
| RAC_REST_NAME_003 | intestazioni Hyphenated-Pascal-Case | ✅ `X-Request-Id` |
| RAC_REST_NAME_008 | errori RFC 7807 | ✅ |
| RAC_REST_NAME_011 | stato del servizio | ✅ `/status` |
| RAC_ROBUSTEZZA_002 | 503 con `Retry-After` se il servizio non e' disponibile | ✅ |
| RAC_ROBUSTEZZA_001 | limiti d'uso con 429 | ➖ non nel codice (si e' scelto di non aggiungere codice nostro): per uso interno bastano i limiti del database; se servisse, `mod_ratelimit`/`mod_evasive` di Apache o fail2ban |
| RAC_REST_FORMAT_002 / RAC_REST_NAME_006 | elenchi dentro un oggetto e link di paginazione nel corpo | ➖ scostamento: PostgREST restituisce array e usa `Content-Range`. Sono raccomandazioni; il formato e' documentato nell'OpenAPI |
| Pattern ModI (ID_AUTH_*, INTEGRITY_*) e PDND | ➖ le API sono per uso interno dell'ente. Se fossero erogate ad altre amministrazioni andrebbero pubblicate tramite PDND con voucher OAuth2 e profilo ModI; il database resta uguale |

## 8. Ciclo di sviluppo

| Requisito | Come | |
|---|---|---|
| Componenti mantenuti, poche dipendenze | Lizmap/Jelix, PostgREST (binario ufficiale), firebase/php-jwt (unica libreria, senza dipendenze), PostgreSQL | ✅ |
| Configurazione dichiarativa | risorse e permessi in `config/api.yaml`, applicati da `prosit-api applica`: niente modifiche a mano in produzione | ✅ |
| Test automatici di sicurezza | 104 controlli (`tests/`), incluse prove negative (permessi, CSRF, utente disattivato, diritto mancante, token falsi) | ✅ |
| Aggiornare le dipendenze | controllare i rilasci di Lizmap, PostgREST e firebase/php-jwt almeno ogni 6 mesi | ⚠️ processo |

## 9. Minacce considerate

| Scenario | Effetto |
|---|---|
| Password di un utente tecnico rubata | funziona solo su HTTPS, solo con i permessi dei suoi gruppi; si revoca disattivando l'utente in Lizmap (immediato). Gli accessi restano nell'audit |
| Sito malevolo che usa la sessione di un utente | lettura impossibile (nessun CORS), modifiche bloccate dal controllo `Origin` |
| Configurazione del modulo sottratta (`prositapi.ini.php`) | contiene la password di `api_gateway`, che puo' solo allineare utenti a ruoli; la chiave privata del token e' in un file separato: va comunque ruotata (`ruota-jwt`) e cambiata la password |
| Database `api` sottratto | nessuna password di utenti (stanno in Lizmap); password remote solo nel catalogo riservato al superuser |
| Accesso diretto a PostgREST | solo da 127.0.0.1; senza token firmato → ruolo anonimo senza permessi |
| Aggiornamento di Lizmap | procedura in README §5; un modulo mancante e' segnalato da `prosit-api verifica` e riparato da `prosit-api lizmap` |

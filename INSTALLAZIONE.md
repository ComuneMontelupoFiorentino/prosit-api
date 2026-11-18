# Installazione sulla VM di Lizmap — passo per passo

Valori di questa VM: utente `<utente>` (gruppo `prosit`), superuser PostgreSQL `<superuser-postgres>`,
PostgreSQL 16 su 127.0.0.1:5432, Lizmap in `/var/www/lizmap-web-client-3.9.12`, PostgREST in
`/usr/local/bin/prosit/postgrest-16.5/`, Apache con PHP-FPM 8.3.

Prima si fa **tutto quello che si puo' senza root**; poi l'amministratore lancia **un solo
script**, preparato dall'installazione, che mette i file al loro posto, avvia i servizi e
sistema Apache. I dettagli sono nel README.

## 1. Tu: pacchetto e accesso a PostgreSQL

```bash
cd ~ && rm -rf ~/prosit-api && unzip -q prosit-api-v2.zip     # zip caricato in home via FTP
echo '127.0.0.1:5432:*:<superuser-postgres>:<password>' > ~/.pgpass && chmod 600 ~/.pgpass
```

Controllare `~/prosit-api/config/api.yaml` (in particolare `server_pubblico`).

## 2. Tu: installazione senza root

```bash
chmod 755 ~/prosit-api/bin/prosit-api ~/prosit-api/tests/*.sh
PG_ADMIN=<superuser-postgres> ~/prosit-api/bin/prosit-api installa 2>&1 | tee ~/prosit-api-installa.log
```

Non chiede password: i collegamenti ai database esterni usano due utenti propri, `prosit_api_ro` e
`prosit_api_rw`, creati con password casuali e membri di `prosit_ro` / `prosit_rw` (stessi permessi). Cosa fa:

- controlli (PostgreSQL, PHP, PostgREST, Lizmap); crea `/usr/local/bin/prosit/postgrest` →
  `postgrest-16.5/postgrest`;
- segreti, chiavi e configurazione in `~/prosit-api-config` (cartella provvisoria, solo tua),
  gia' scritti con i percorsi definitivi (`/etc/prosit-api`, `/opt/prosit-api`);
- ruoli, database `api`, risorse e funzioni in PostgreSQL. Su questa VM PostgreSQL non chiede la
  password per i collegamenti da 127.0.0.1 (`trust` in `pg_hba.conf`), e `postgres_fdw` in quel caso
  si rifiuta di collegarsi: l'importazione delle tabelle esterne viene rimandata al passo 3 (avviso,
  non errore);
- **prova PostgREST**: lo avvia per qualche secondo con il tuo utente, controlla collegamento al
  database, rifiuto delle richieste senza token, token firmati dal modulo accettati e token
  firmati con un'altra chiave rifiutati; poi lo spegne;
- installa il modulo in Lizmap (se ha i permessi; altrimenti lo dice e si fa dopo, passo 4);
  fino al passo 3 la API risponde 503, il resto di Lizmap non cambia;
- scrive **`~/prosit-api-config/per-amministratore.sh`**.

Se qualcosa non va si ferma e dice cosa fare: mandami `~/prosit-api-installa.log`.

## 3. Amministratore: una sola volta (root), poi tu

**3a. Amministratore** — tutti i comandi in una volta. Le unita' systemd si possono installare
subito: PostgREST non parte finche' non c'e' la sua configurazione e poi parte da solo
(`postgrest-prosit-api.path`).

```bash
# cartelle del software e della configurazione, intestate a <utente>
install -d -o <utente> -g prosit   -m 0755 /opt/prosit-api
install -d -o <utente> -g www-data -m 0711 /etc/prosit-api
install -d -o <utente> -g prosit   -m 0700 /var/backups/prosit-api     # backup settimanali
# pg_hba.conf: copia di sicurezza, poi due regole con password SOLO per prosit_api_ro/rw
cp -a /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_hba.conf.prima-di-prosit-api
sed -i '1i # Prosit API v2: i collegamenti tra database (postgres_fdw) richiedono la password.\nhost    all    prosit_api_ro,prosit_api_rw    127.0.0.1/32    scram-sha-256\nhost    all    prosit_api_ro,prosit_api_rw    ::1/128         scram-sha-256\n' /etc/postgresql/16/main/pg_hba.conf
# servizio PostgREST, avvio automatico, manutenzione settimanale
install -m 0644 /home/<utente>/prosit-api-config/systemd/postgrest-prosit-api.service \
                /home/<utente>/prosit-api-config/systemd/postgrest-prosit-api.path \
                /home/<utente>/prosit-api-config/systemd/prosit-api-manutenzione.service \
                /home/<utente>/prosit-api-config/systemd/prosit-api-manutenzione.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now postgrest-prosit-api.path postgrest-prosit-api prosit-api-manutenzione.timer
# per il futuro: <utente> legge i log e puo' riavviare/ricaricare SOLO questo servizio
usermod -aG systemd-journal <utente>
echo '<utente> ALL=(root) NOPASSWD: /usr/bin/systemctl restart postgrest-prosit-api, /usr/bin/systemctl reload postgrest-prosit-api' > /tmp/prosit-api.sudoers
visudo -cf /tmp/prosit-api.sudoers && install -m 0440 /tmp/prosit-api.sudoers /etc/sudoers.d/prosit-api
```

Il `sed` va eseguito una sola volta (rilanciato, duplicherebbe le righe: innocuo ma inutile).
La modifica a `pg_hba.conf` non ha effetto finche' non si ricarica PostgreSQL (passo 3b).
Apache non va toccato.

**3b. Tu** (uscire e rientrare da SSH prima, per il gruppo `systemd-journal`)

```bash
# pg_hba: le due righe nuove per prime, nessun errore, poi attivazione
psql -h 127.0.0.1 -U <superuser-postgres> -w -d postgres -c "SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules ORDER BY rule_number LIMIT 4"
psql -h 127.0.0.1 -U <superuser-postgres> -w -d postgres -At -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL"   # 0
psql -h 127.0.0.1 -U <superuser-postgres> -w -d postgres -At -c "SELECT pg_reload_conf()"                                          # t
# installazione definitiva (la preparazione non serve piu')
rm -rf ~/prosit-api-config
cp -a ~/prosit-api/. /opt/prosit-api/
PG_ADMIN=<superuser-postgres> SUDO_SYSTEMCTL=1 /opt/prosit-api/bin/prosit-api installa 2>&1 | tee ~/prosit-api-installa.log
```

L'installazione scrive configurazione e segreti in `/etc/prosit-api`, completa il database `api`,
e systemd avvia PostgREST appena trova la configurazione. Se la tabella non mostra le due righe
per prime o il conteggio non e' 0: non ricaricare e chiedere di rimettere la copia di `pg_hba.conf`.

## 3-bis. In alternativa: tutto con uno script (amministratore)


```bash
sudo bash /home/<utente>/prosit-api-config/per-amministratore.sh
```

Lo script e' leggibile (conviene darci un'occhiata prima) e rilanciabile. In ordine:

1. `<utente>` nel gruppo `www-data`;
2. software in `/opt/prosit-api` (copia di `~/prosit-api`);
3. configurazione e segreti in `/etc/prosit-api` con i permessi giusti (segreti 0600, i due file
   letti da PHP 0640 gruppo `www-data`, configurazione di PostgREST e chiave pubblica 0644);
4. `pg_hba.conf`: due righe in testa che chiedono la password **solo** a `prosit_api_ro` e
   `prosit_api_rw` (tutti gli altri collegamenti restano come prima); copia del file accanto,
   controllo di validita' (se non valido lo ripristina), ricarica di PostgreSQL; poi completa il
   database `api` (`prosit-api applica-db` con il tuo utente);
5. servizio `postgrest-prosit-api` e timer settimanale di backup e pulizia (systemd), avvio e
   controllo che PostgREST risponda: **se non risponde si ferma e Apache non viene toccato**;
6. Apache: copia delle configurazioni in `/var/backups/apache-prosit-api-<data>/`, aggiunta di
   `CGIPassAuth On` nel blocco di Lizmap e di `SSLProtocol -all +TLSv1.2 +TLSv1.3` nel 443,
   `apachectl configtest` e **ricarica di Apache**; se il test fallisce rimette i file originali
   e non ricarica.

In fondo allo script ci sono, commentati, i due permessi facoltativi (leggere i log di
PostgREST; riavviare PostgREST con sudo solo per quel servizio).

## 4. Tu: verifica e Lizmap

Uscire e rientrare da SSH (per il nuovo gruppo), poi:

```bash
/opt/prosit-api/bin/prosit-api verifica
```

Se dice "modulo non installato": `/opt/prosit-api/bin/prosit-api lizmap`. Se tutto e' OK,
cancellare la copia provvisoria dei segreti: `rm -rf ~/prosit-api-config`.

In Lizmap, da amministratore:

1. **Amministrazione → Gruppi di utenti**: nuovo gruppo `tecnici_api` ("Utenti tecnici API").
2. **Amministrazione → Diritti**, gruppo `tecnici_api`: "*Accesso alle API da programmi*"
   (sezione "Prosit API"). Solo a questo gruppo.
3. Un utente tecnico di prova (es. `svc_prova`, password lunga e casuale) in `tecnici_api`
   e in un gruppo funzionale (es. `vigili`).

Collaudo:

```bash
PG_ADMIN=<superuser-postgres> /opt/prosit-api/tests/collaudo_vm.sh http://127.0.0.1/lizmap svc_prova:<password>
```

E dal browser, collegati a Lizmap: `https://<server>/lizmap/api.php/prosit/v2/auth/me`.

## Dopo

- Modifiche a risorse e permessi: `/opt/prosit-api/config/api.yaml` → `prosit-api applica`.
- Aggiornamento di Lizmap: README §5; dopo l'installer di Lizmap, `prosit-api lizmap`.
- Certificato dell'ente: README §4 (redirect su HTTPS e HSTS).
- Facoltativo: percorso stabile di Lizmap con collegamento simbolico (README §4).
- Utenti di Lizmap in PostgreSQL: `prosit-api utenti-pg` (docs/UTENTI-POSTGRESQL.md).

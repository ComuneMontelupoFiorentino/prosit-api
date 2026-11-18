# Utenti di Lizmap in PostgreSQL

Lizmap salva utenti, gruppi, diritti e segnalibri nel profilo jdb `jauth`, e il registro degli accessi nel profilo `lizlog`. Normalmente sono i file SQLite `var/db/jauth.db` e `var/db/logs.db`.

`prosit-api utenti-pg` sposta **utenti, gruppi, diritti e segnalibri** in un database PostgreSQL dedicato, **`lizmap`**, con proprietario l'utente **`lizmap_app`**. Lo fa con il comando ufficiale di Lizmap `database:migrateusers`.

Il **registro degli accessi** resta in `logs.db`. In Lizmap 3.9.12 il comando `database:migratelog` è difettoso: si interrompe su `log_timestamp`, come si è visto sulla VM. Il registro non è indispensabile, e chi vuole spostarlo comunque può usare `LIZMAP_LOG_PG=1`.

## Perché un database separato da `api`

- **Minimo privilegio.** PostgREST lavora nel database `api` e non deve poter arrivare agli hash delle password, nemmeno per un `GRANT` sbagliato.
- **Cicli di vita diversi.** Gli aggiornamenti di Lizmap modificano le sue tabelle, mentre `prosit-api applica` rigenera lo schema `api`.
- **Backup e ripristino indipendenti.** Il backup settimanale (`prosit-api backup`) salva entrambi i database.

## Prima di cominciare

1. **`prosit-web` non deve leggere più `jauth.db`.** Dall'aggiornamento del 2 novembre 2026 ricava l'utente da Lizmap con la API v2: `auth.source = lizmap_api`, che è il valore predefinito.
2. **Altri programmi che leggono `jauth.db` vanno fermati o adattati.** Esempi: lo script di sincronizzazione SQLite → PostgreSQL, i controlli nello scheduler. Il comando seguente mostra quali sono:
   ```bash
   grep -rIl --exclude-dir='lizmap-web-client*' -e 'jauth\.db' -e 'jlx_user' /usr/local/bin/prosit /var/www /etc/apache2
   ```
3. **Scegliere un momento tranquillo.** Le modifiche fatte a utenti e password durante la migrazione, che dura pochi secondi, andrebbero perse.

## Migrazione

```bash
PG_ADMIN=<superuser-postgres> /opt/prosit-api/bin/prosit-api utenti-pg
```

Il comando esegue questi passi:

1. **Copia di sicurezza.** Salva `profiles.ini.php`, `jauth.db` e `logs.db` in `~/backup/lizmap-utenti-<data>/`.
2. **Utente e database.** Crea l'utente `lizmap_app` con una password casuale di 32 caratteri, e il database `lizmap` di sua proprietà. Toglie il diritto di collegamento a tutti gli altri utenti.
3. **Configurazione di Lizmap.** In `var/config/profiles.ini.php` imposta `[jdb:jauth]` con `driver=pgsql`. Il file resta lo stesso, con gli stessi permessi.
4. **Copia dei dati.** Esegue `database:migrateusers`, poi confronta tabella per tabella il numero di righe tra SQLite e PostgreSQL.
5. **Controllo finale.** Svuota la cache di Lizmap e verifica che Lizmap e la API rispondano.

**Se uno dei controlli fallisce**, il comando rimette il `profiles.ini.php` di prima e Lizmap torna a SQLite. Il database `lizmap` resta invece com'è: va cancellato (`DROP DATABASE lizmap`) prima di riprovare.

**Dopo la migrazione:**

- **Verifiche dal browser:**
  - l'accesso a Lizmap;
  - la pagina Amministrazione → Utenti, con la modifica di un utente di prova;
  - una mappa riservata;
  - una scheda e un'app di Prosit.
- **Controllo da riga di comando:**
  ```bash
  /opt/prosit-api/bin/prosit-api verifica
  ```
  Deve comparire la riga "utenti di Lizmap in PostgreSQL".
- **`jauth.db` e `logs.db`** restano al loro posto per qualche settimana, come riserva. Lizmap non li usa più.

## Tornare indietro

```bash
/opt/prosit-api/bin/prosit-api utenti-sqlite
```

Il comando rimette il `profiles.ini.php` dell'ultima copia in `~/backup/lizmap-utenti-*`. **Le modifiche a utenti, gruppi e password fatte dopo la migrazione non tornano in SQLite.**

## Sicurezza: da completare con l'amministratore

La password di `lizmap_app` è scritta in `profiles.ini.php`. Il file deve restare leggibile solo dal tuo utente e da `www-data`.

Su questa VM `pg_hba.conf` accetta in `trust` i collegamenti da 127.0.0.1, quindi oggi la password non viene nemmeno controllata. In produzione, l'amministratore aggiunge in testa a `pg_hba.conf` una riga uguale a quelle della Prosit API e poi ricarica PostgreSQL:

```
host    lizmap    lizmap_app    127.0.0.1/32    scram-sha-256
host    lizmap    lizmap_app    ::1/128         scram-sha-256
```

## Aggiornamenti di Lizmap

`backup.sh` e `restore.sh` di Lizmap conservano `var/config/profiles.ini.php`, quindi dopo un aggiornamento Lizmap continua a usare PostgreSQL. Le tabelle sono di `lizmap_app`, che è anche l'utente con cui l'installer di Lizmap si collega: le eventuali modifiche alle tabelle, introdotte da una nuova versione, si applicano normalmente.

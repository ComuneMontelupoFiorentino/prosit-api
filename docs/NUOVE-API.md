# Aggiungere API in futuro

Regola generale: **si descrive in `config/api.yaml`, si applica con `prosit-api applica`**.
Il comando rigenera l'SQL, lo applica, fa ricaricare PostgREST, rigenera l'OpenAPI con le
colonne reali e riesegue i controlli di sicurezza. Niente codice PHP, nessun riavvio di Apache.

Nomi: le risorse sono in kebab-case nell'URL (`tvcc-log`), la vista corrispondente in
PostgreSQL e' in snake_case (`api.tvcc_log`); lo stesso per le funzioni
(`/rpc/calendario-crea` → `api.calendario_crea`).

---

## 1. Esporre una tabella o vista in lettura

Esempio: elenco dei parchi del db `vp`.

1. **Permesso sul database di origine** (una volta): l'utente remoto deve poterla leggere.
   ```sql
   -- su vp, da superuser
   GRANT USAGE ON SCHEMA verde TO prosit_ro, prosit_rw;
   GRANT SELECT ON verde.parchi TO prosit_ro, prosit_rw;
   ```
   (oppure aggiungere la riga in `/opt/prosit/sql/10_grant_prosit.sql` e rilanciarlo).
2. **`config/api.yaml`**:
   ```yaml
   risorse:
     parchi:
       descrizione: Parchi e giardini
       sorgente: vp.verde.parchi        # alias.schema.tabella
       chiave: id
       escludi: [geom]                  # oppure colonne: [id, nome, superficie]
       lettura: [utenti]                # tutti gli utenti Lizmap autenticati
   ```
3. `/opt/prosit-api/bin/prosit-api applica`
4. Prova: `GET /lizmap/api.php/prosit/v2/parchi?select=id,nome&order=nome`

## 2. Risorsa scrivibile, con valori impostati dal database e limite per riga

```yaml
risorse:
  interventi-verde:
    descrizione: Interventi programmati sul verde
    sorgente: vp.gestione.pian_int
    chiave: id
    lettura: [manutentori_verde, admins]
    inserimento: [manutentori_verde, admins]
    modifica: [manutentori_verde, admins]
    cancellazione: [admins]
    scrivibili: [id_zona, ty_int, date_int, execution, date_int_ex, manteiner]   # cosa puo' inviare il client
    modificabili: [execution, date_int_ex, date_int]                            # cosa puo' cambiare dopo
    forzati:
      planned_int: {valore: su Programmazione}     # o: utente.login | utente.nome | utente.email | adesso | oggi
    filtro: >-
      api_fn.ha_ruolo('admins')
      OR manteiner = CASE WHEN api_fn.in_gruppo_lizmap('man_verde_es') THEN 'Cooperativa orizzonti'
                          WHEN api_fn.in_gruppo_lizmap('man_int') THEN 'Manutentori interni' END
```

Cosa ottieni, tutto in PostgreSQL:
- `GRANT INSERT (colonne scrivibili)` e `GRANT UPDATE (colonne modificabili)`: una colonna non
  elencata e' rifiutata (403), comprese quelle "forzate";
- le colonne forzate sono `DEFAULT` della vista: le riempie il database con l'utente del token;
- `filtro` limita le righe visibili **e**, con `WITH CHECK OPTION`, quelle che si possono creare
  o modificare (un manutentore non puo' scrivere record di un altro: 403);
- id `serial`/`identity` e altri default del database di origine funzionano (li ricrea
  `api_admin.importa`, le sequenze sono lette dal database di origine);
- l'utente remoto `prosit_rw` deve avere `INSERT/UPDATE/DELETE` sulla tabella e `USAGE` sulla sequenza.

Funzioni utili nei filtri: `api_fn.login()`, `api_fn.nome()`, `api_fn.email()`,
`api_fn.ha_ruolo('admins')` (ruolo PostgreSQL `grp_admins`), `api_fn.in_gruppo_lizmap('urp')`
(gruppo Lizmap, id o nome), `api_fn.tipo_accesso()` (`sessione` | `programma`).

## 3. Nuovo gruppo di utenti

```yaml
gruppi:
  ufficio_tecnico:
    lizmap: [utc, Ufficio Tecnico]   # id o nomi dei gruppi Lizmap
    descrizione: Ufficio tecnico comunale
```
Diventa il ruolo `grp_ufficio_tecnico`. Chi entra o esce dal gruppo in Lizmap acquista o perde
i permessi alla richiesta successiva. Un gruppo puo' raccogliere piu' gruppi Lizmap.

## 4. Un altro database

```yaml
database:
  catasto:
    dbname: catasto_2026
    host: localhost
    port: 5432
    utente_lettura: prosit_ro
    utente_scrittura: prosit_rw
    postgis: true
```
Se l'utente remoto e' diverso, aggiungere la sua password in `/etc/prosit-api/segreti.env`
come `PW_<UTENTE>=...` (es. `PW_CATASTO_RO=...`). Per un server PostgreSQL remoto: `host`
con il nome del server e una regola in `pg_hba.conf` di quel server per l'IP della VM.

## 5. Dati che richiedono join o aggregazioni

Conviene una **vista nel database di origine** (cosi' join e aggregazioni vengono eseguiti la',
non trasferiti) ed esporla come risorsa:

```sql
-- su segnalazioni_23
CREATE VIEW segn.scheda_completa_v AS
  SELECT s.seg_id, s.stato_segn, a.alias_name AS assegnatario,
         (SELECT jsonb_agg(c ORDER BY c.action_date) FROM segn.reporting_ticket_deleted c WHERE c.id_prosit = s.seg_id) AS cronologia
    FROM segn.segn_id s LEFT JOIN administration.assignee_list a ON a.man_es = s.man_es;
GRANT SELECT ON segn.scheda_completa_v TO prosit_ro, prosit_rw;
```
```yaml
  segnalazione-scheda:
    sorgente: segn.segn.scheda_completa_v
    chiave: seg_id
    lettura: [utenti]
```
La scheda fa una sola chiamata: `GET /segnalazione-scheda?seg_id=eq.123`.

## 6. Operazioni con logica (funzioni RPC)

Per operazioni che non sono un CRUD (invio mail, calcoli, piu' tabelle insieme) si scrive una
funzione in un nuovo file `sql/7x_<nome>.sql`: `prosit-api applica` esegue da solo tutti i file
`sql/6x_*.sql` e `sql/7x_*.sql`. Modello:

```sql
-- sql/70_parchi.sql
CREATE OR REPLACE FUNCTION api.parco_segnala_chiusura(id integer, motivo text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER                       -- usa la connessione di prosit_rw (proprietario api_scrittore)
SET search_path = pg_catalog           -- obbligatorio con SECURITY DEFINER
AS $$
DECLARE
  t text := api_auth.tabella_esterna('vp.verde.parchi');   -- tabella esterna importata
BEGIN
  IF length(trim(COALESCE(motivo, ''))) < 5 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Motivo obbligatorio (almeno 5 caratteri).';  -- 422 al client
  END IF;
  EXECUTE format('UPDATE %s SET chiuso = true, motivo_chiusura = $1, chiuso_da = $2 WHERE id = $3', t)
    USING motivo, api_fn.nome(), parco_segnala_chiusura.id;
  RETURN jsonb_build_object('id', parco_segnala_chiusura.id, 'chiuso', true);
END $$;
COMMENT ON FUNCTION api.parco_segnala_chiusura(integer, text) IS 'Segnala la chiusura di un parco';
ALTER FUNCTION api.parco_segnala_chiusura(integer, text) OWNER TO api_scrittore;
REVOKE ALL ON FUNCTION api.parco_segnala_chiusura(integer, text) FROM PUBLIC;     -- SEMPRE
GRANT EXECUTE ON FUNCTION api.parco_segnala_chiusura(integer, text) TO grp_ufficio_tecnico;
```
Le tabelle usate solo dalle funzioni vanno in `importa:` di `config/api.yaml`.
Chiamata: `POST /rpc/parco-segnala-chiusura {"id": 5, "motivo": "Lavori"}`.
Funzioni di sola lettura: dichiararle `STABLE` e chiamarle in `GET`. Una funzione che deve
essere usata solo da persone collegate a Lizmap (non da programmi) controlla
`api_fn.tipo_accesso() = 'sessione'` (esempio: `api.segnalazione_mail` in `sql/60_servizi.sql`).

Messaggi d'errore per il client: `RAISE EXCEPTION USING ERRCODE = '22023'` (→ 422),
`'42501'` (→ 403), `'P0002'` (→ 404), con `MESSAGE` in italiano: e' l'unico testo che arriva
al client; tutto il resto resta nel log.

## 7. Percorsi che non sono tabelle o funzioni

Tutto passa da PostgREST: il modulo Lizmap non contiene regole sui dati e **non va
modificato** per aggiungere API. I percorsi ammessi sono `/<risorsa>` e `/rpc/<funzione>`
(in kebab-case, al massimo due livelli: vedi `lizmap-module/prositapi/urls.xml`).
Cio' che il database non puo' fare (es. passare file da un altro server) va lasciato a un
servizio a parte, non dentro la API.

Se un giorno si dovesse cambiare il modulo: modificare `lizmap-module/prositapi`, alzare la
versione in `module.xml`, `prosit-api lizmap`, `tests/collaudo_vm.sh`.

## 8. Controlli prima di pubblicare

- [ ] nella risorsa ci sono solo le colonne necessarie (`colonne`/`escludi`): niente dati personali superflui;
- [ ] gruppi minimi: `utenti` solo per dati che ogni utente Lizmap puo' gia' vedere;
- [ ] `scrivibili`/`modificabili` ridotte al necessario; chi ha inserito/modificato e' `forzato`;
- [ ] righe limitate con `filtro` se i dati sono per ufficio/manutentore;
- [ ] funzioni: `SECURITY DEFINER` + `SET search_path` + `REVOKE ... FROM PUBLIC` + GRANT a un gruppo;
- [ ] `prosit-api verifica` senza ERRORE; prova con un utente che **non** deve vedere i dati (403);
- [ ] `openapi/prosit-api-v2.yaml` rigenerato (lo fa `applica`) e condiviso con chi usa le API.

## 9. Modifiche incompatibili

Togliere colonne o cambiare il significato di una risorsa usata da altri: crearne una nuova
(`segnalazioni-v3`) o, per un cambio generale, una nuova versione dell'API (`/v3`), tenendo la
precedente finche' i client non sono migrati (raccomandazione AgID RAC_GEN_002: versione nell'URL).

# Migrazione dalla API v1 (PHP) alla v2 (PostgREST)

> I file dei servizi gia' migrati e collaudati (schede, registro TVCC, calendario verde) sono nel
> pacchetto a parte `servizi-prosit-v2.zip`, con le istruzioni e le differenze riga per riga.
> La risorsa `todo` (audit.todo_queue), usata dalle schede, e' in `config/api.yaml`.

La v1 (`/lizmap/prosit/api/v1`, e la compatibilita' `/lizmap/API/index.php`) resta attiva:
si migra un servizio alla volta, si controlla, si passa al successivo. Quando i log della v1
(`/opt/prosit/var/log/access-*.log`, `legacy-*.log`) non mostrano piu' chiamate, la si spegne.

## 1. Corrispondenza degli endpoint

| v1 | v2 |
|---|---|
| `GET /v1/health` | `GET /v2/status` |
| `GET /v1/auth/me` | `GET /v2/auth/me` (forma diversa: il client JS v2 restituisce anche quella v1) |
| `GET /v1/resources` | `GET /v2/risorse` (operazioni: lettura, inserimento, modifica, cancellazione) |
| `GET /v1/{risorsa}?col=v` | `GET /v2/{risorsa}?col=eq.v` |
| `?col__not=v` / `__gt` `__gte` `__lt` `__lte` | `?col=isdistinct.v` / `gt.` `gte.` `lt.` `lte.` |
| `?col__like=abc` | `?col=ilike.*abc*` |
| `?col__in=a,b` / `__notin` | `?col=in.(a,b)` / `not.in.(a,b)` |
| `?col__null=true` | `?col=is.null` (`not.is.null`) |
| `_select=a,b` `_order=-d,id` `_limit` `_offset` | `select=a,b` `order=d.desc,id` `limit` `offset` |
| `_count=1` → `meta.total` | intestazione `Prefer: count=exact` → `Content-Range: 0-49/1234` |
| `GET /v1/{risorsa}/{id}` | `GET /v2/{risorsa}?{chiave}=eq.{id}` (oggetto singolo: `Accept: application/vnd.pgrst.object+json`) |
| `POST /v1/{risorsa}` (restituiva il record) | `POST /v2/{risorsa}`; per avere il record: `Prefer: return=representation` (serve il permesso di lettura) |
| `PATCH /v1/{risorsa}/{id}` | `PATCH /v2/{risorsa}?{chiave}=eq.{id}` (senza filtro: 400) |
| `DELETE /v1/{risorsa}/{id}` | `DELETE /v2/{risorsa}?{chiave}=eq.{id}` |
| `POST /v1/segnalazioni/{id}/mail` | `POST /v2/rpc/segnalazione-mail` `{"seg_id": id}` |
| `GET /v1/documenti/rekla?post_id&file` | resta sulla v1 (e' un proxy di file, non dati: vedi §5) |
| `GET /v1/calendario/context` | `GET /v2/rpc/calendario-contesto` |
| `GET /v1/calendario/interventi?dal&al` | `GET /v2/rpc/calendario-interventi?dal&al` |
| `POST /v1/calendario/interventi` | `POST /v2/rpc/calendario-crea` (stesso corpo) |
| `PUT /v1/calendario/interventi?id&fonte` + corpo | `POST /v2/rpc/calendario-modifica` `{"id", "fonte", "dati": {corpo}}` |
| `DELETE /v1/calendario/interventi?id&fonte` | `POST /v2/rpc/calendario-elimina` `{"id", "fonte"}` |

Formato delle risposte:
- v1: `{"success":true,"status":200,"data":...,"meta":{...}}`; v2: direttamente l'array o l'oggetto.
- errori v1: `{"success":false,"error":"..."}`; v2: `application/problem+json` con `detail` e `request_id`.
- date: v2 in ISO 8601 (`2026-10-31T15:00:00+01:00`); numeri `numeric` come numeri JSON (v1: stringhe).
  `Prosit.fmt.date` gestisce entrambi i formati.

I nomi delle risorse sono gli stessi della v1.

## 2. Schede popup (disservizio, disservizio-bit, manomissioni, pali-luce)

1. Nell'HTML, dopo `prosit.js`:
   ```html
   <script src="../assets/prosit-api-v2.js"></script>
   ```
   `Prosit.api.list / one / first / me / safe` restano uguali (i filtri sono tradotti).
2. Solo `disservizio.js`, invio mail:
   ```js
   // prima
   const r = await api.post(`segnalazioni/${encodeURIComponent(segId)}/mail`);
   // dopo
   const r = await api.rpc('segnalazione-mail', { seg_id: Number(segId) });
   ```
3. Aprire la scheda con un utente normale e una con un utente senza permessi, controllare la console.

## 3. Registro controlli TVCC (`app/registro-tvcc`)

In `index.html`, prima di `app.js`: `<script src="../../assets/prosit-api-v2.js"></script>`.
In `app.js` sostituire le `fetch` verso `${API}/...` con il client (gestisce errori, Origin e formati):

| Prima (v1) | Dopo (v2) |
|---|---|
| `fetch(DATA_ENDPOINT)` → `data.data` | `await Prosit.api.list('tvcc-apparati', { _order: 'id_app' })` |
| `fetch(\`${API}/auth/me\`)` → `user.name` | `const me = await Prosit.api.me()` → `me.nome` (anche `me.user.name`) |
| `fetch(\`${API}/segnalazioni?${params}\`)` | `await Prosit.api.list('segnalazioni', { segn_ogg_gen: id, stato_segn__not: 'Verificata e chiusa', _select: 'seg_id,seg_i_rek_alias,insert_timestamp,seg_o_desc', _order: 'insert_timestamp' })` |
| `POST ${API}/tvcc-ticket` (oggetto o lista) | `await Prosit.api.create('tvcc-ticket', body)` |
| `POST ${API}/tvcc-log` `{note}` | `await Prosit.api.create('tvcc-log', { note: statusValue })` |

L'operatore (`seg_s_ac_op`, `insert_by`) continua a impostarlo il server: ora e' il `DEFAULT`
della vista con il nome dal token, e se il browser prova a inviarlo riceve 403.

## 4. Calendario verde (`app/calendario-verde`)

In `index.html`: `<script src="../../assets/prosit-api-v2.js"></script>` prima di `app.js`. In `app.js`:

| Prima (v1) | Dopo (v2) |
|---|---|
| `(await jget(\`${API}/calendario/context\`)).data` | `await Prosit.api.rpc('calendario-contesto', {}, 'GET')` |
| `jget(\`${API}/calendario/interventi?dal=..&al=..\`)` → `j.data.giorni` | `(await Prosit.api.rpc('calendario-interventi', { dal, al }, 'GET')).giorni` |
| `LZ.types` (`/vp-tipi-intervento`) | `await Prosit.api.list('vp-tipi-intervento')` |
| `LZ.objects` (`/vp-oggetti-manutentore`) | `await Prosit.api.list('vp-oggetti-manutentore')` |
| `POST /calendario/interventi` body | `await Prosit.api.rpc('calendario-crea', body)` |
| `PUT /calendario/interventi?id=X&fonte=F` body | `await Prosit.api.rpc('calendario-modifica', { id: X, fonte: F, dati: body })` |
| `DELETE /calendario/interventi?id=X&fonte=F` | `await Prosit.api.rpc('calendario-elimina', { id: X, fonte: F })` |

Le risposte hanno gli stessi campi della v1 (`ids`, `creati`, `fonte`, `giorni`, `role`, ...).

## 5. Cosa NON cambia

- report ticket (`app/report-ticket`), pannello open data, hook QField, stazione meteo e
  web service sopralluoghi: lavorano lato server con il core Prosit, non con l'API.
- proxy documenti Rekla: resta sulla v1 (`/v1/documenti/rekla`), che per questo endpoint
  non va spenta; e' un passaggio di file, non una tabella, e non rientra in PostgREST.

## 6. Spegnimento della v1

1. Nessuna chiamata nei log della v1 per almeno due settimane.
2. In `/opt/prosit/deploy/apache/prosit.inc` limitare il blocco `<Directory /opt/prosit/public/api>`
   al solo proxy documenti (o `Require all denied` se non serve piu'), ricaricare Apache.
   La v2 sta in Lizmap (`/lizmap/api.php/prosit/v2`) e non e' toccata.
3. La v2 usa gli stessi utenti remoti (`prosit_ro`, `prosit_rw`): i loro permessi restano.

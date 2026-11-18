// Collaudo di assets/prosit-api-v2.js contro il Lizmap di prova (vedi tests/LEGGIMI.md)
//   node tests/test_client.mjs "<cookie di sessione Lizmap>" [origine] [percorso della API]
//   es. node tests/test_client.mjs "$C" http://127.0.0.1 /lizmap/api.php/prosit/v2
import { readFileSync } from 'node:fs';
const cookie = process.argv[2];
const ORIG = process.argv[3] || 'http://127.0.0.1';
const API_PATH = process.argv[4] || '/lizmap/api.php/prosit/v2';
globalThis.location = { origin: ORIG };
globalThis.document = { currentScript: { src: ORIG + '/lizmap/prosit/assets/prosit-api-v2.js', dataset: { api: API_PATH } } };
globalThis.window = globalThis;
const realFetch = fetch;
globalThis.fetch = (url, opt = {}) => realFetch(url, { ...opt, headers: { ...opt.headers, Cookie: cookie, Origin: ORIG } });
eval(readFileSync(new URL('../assets/prosit-api-v2.js', import.meta.url), 'utf8'));
const { api } = globalThis.Prosit;
let ok = 0, ko = 0;
const prova = (d, c) => { if (c) { ok++; console.log('OK  ' + d); } else { ko++; console.log('KO  ' + d); } };

const p = api._parametri({ a: 1, b__not: 'x', c__in: 'p,"q', d__like: 'ra', e__null: true, _order: '-data,id', _select: 'a,b', _count: 1 });
prova('traduzione filtri', p.params.toString() === 'a=eq.1&b=isdistinct.x&c=in.%28%22p%22%2C%22%5C%22q%22%29&d=ilike.*ra*&e=is.null&order=data.desc.nullslast%2Cid.asc&select=a%2Cb' && p.conta);
const me = await api.me();
prova('me() con forma v1', me.groups.ids.includes('vigili') && me.user.login === 'vigile');
const lista = await api.listMeta('segnalazioni', { _select: 'seg_id', _order: 'seg_id', _limit: 2 });
prova('listMeta', lista.data.length === 2 && lista.data[0].seg_id === 1);
prova('one() con chiave da /risorse', (await api.one('segnalazioni', 2)).seg_id === 2);
prova('one() inesistente -> null', (await api.one('segnalazioni', 99999)) === null);
prova('first()', (await api.first('tvcc-apparati', { id_app: 'TLC-02' })).id_app === 'TLC-02');
prova('create() minimale', (await api.create('tvcc-log', { note: 'dal client' })) === null);
const r = await api.create('tvcc-log', { note: 'con ritorno' }, { ritorna: true });
prova('create() con ritorno e campo forzato', r && r.insert_by === 'Vito Vigile');
prova('rpc GET', (await api.rpc('io', {}, 'GET')).login === 'vigile');
try { await api.list('segnalazioni-inesistente'); prova('errore problem+json', false); }
catch (e) { prova('errore problem+json -> ApiError', e.name === 'ApiError' && e.status >= 400 && e.message.length > 0); }
console.log(`\nSuperati: ${ok}   Falliti: ${ko}`);
process.exit(ko ? 1 : 0);

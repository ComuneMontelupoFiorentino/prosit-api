#!/usr/bin/env python3
"""
Generatore della Prosit API v2 a partire da config/api.yaml.

  genera_api.py [--config config/api.yaml] [--uscita DIR] [--catalogo catalogo.json | --psql "psql -d api ..."]

Scrive (dentro DIR, predefinito: la cartella del progetto):
  sql/generato/50_risorse.sql   gruppi, database esterni, importazioni, viste e GRANT
  postgrest/prosit-api.conf     configurazione di PostgREST
  openapi/prosit-api-v2.yaml    contratto OpenAPI 3.0 (con le colonne reali se c'e' il catalogo)

Nessuna password viene letta o scritta: nell'SQL compaiono come variabili psql
:'pw_<utente>' che l'installatore passa leggendo /etc/prosit-api/segreti.env.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

RADICE = Path(__file__).resolve().parent.parent

RE_NOME_RISORSA = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
RE_GRUPPO = re.compile(r"^[a-z][a-z0-9_]{0,58}$")
RE_ALIAS = re.compile(r"^[a-z][a-z0-9_]{0,20}$")
RE_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")
FORZATI = {"utente.login", "utente.nome", "utente.email", "adesso", "oggi"}
OPERAZIONI = ("lettura", "inserimento", "modifica", "cancellazione")
CHIAVI_RISORSA = {"descrizione", "sorgente", "chiave", "colonne", "escludi", "filtro", "scrivibili",
                  "modificabili", "forzati", *OPERAZIONI}


class ErroreConfig(Exception):
    pass


# --------------------------------------------------------------------------- utilita'

def sql_lit(v: str | None) -> str:
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def sql_array(vals) -> str:
    return "ARRAY[" + ", ".join(sql_lit(v) for v in vals) + "]::text[]"


def dollar(s: str) -> str:
    tag = "$j$"
    i = 0
    while tag in s:
        i += 1
        tag = f"$j{i}$"
    return f"{tag}{s}{tag}"


def var_pw(utente: str) -> str:
    return "pw_" + re.sub(r"[^a-z0-9_]", "_", utente.lower())


def lista(v, nome: str) -> list:
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    if not isinstance(v, list):
        raise ErroreConfig(f"{nome}: atteso un elenco")
    return [str(x) for x in v]


# --------------------------------------------------------------------------- validazione

def valida(cfg: dict) -> dict:
    if not isinstance(cfg, dict):
        raise ErroreConfig("il file non contiene una mappa YAML")
    for k in ("api", "gruppi", "database", "risorse"):
        if k not in cfg:
            raise ErroreConfig(f"sezione mancante: {k}")

    gruppi = cfg["gruppi"] or {}
    for g, d in gruppi.items():
        if not RE_GRUPPO.match(str(g)) or g == "utenti":
            raise ErroreConfig(f"gruppi.{g}: nome non valido (minuscole, cifre, _; 'utenti' e' riservato)")
        if not lista((d or {}).get("lizmap"), f"gruppi.{g}.lizmap"):
            raise ErroreConfig(f"gruppi.{g}: indicare almeno un gruppo Lizmap in 'lizmap'")
    noti = set(gruppi) | {"utenti"}

    dbs = cfg["database"] or {}
    for a, d in dbs.items():
        if not RE_ALIAS.match(str(a)):
            raise ErroreConfig(f"database.{a}: alias non valido")
        for k in ("dbname", "host", "port", "utente_lettura"):
            if k not in (d or {}):
                raise ErroreConfig(f"database.{a}: manca '{k}'")

    risorse = cfg["risorse"] or {}
    for nome, r in risorse.items():
        ctx = f"risorse.{nome}"
        if not RE_NOME_RISORSA.match(str(nome)):
            raise ErroreConfig(f"{ctx}: nome non valido (minuscole, cifre, trattino)")
        if nome.replace("-", "_") in ("chiavi", "risorse"):
            raise ErroreConfig(f"{ctx}: nome riservato")
        r = r or {}
        extra = set(r) - CHIAVI_RISORSA
        if extra:
            raise ErroreConfig(f"{ctx}: chiavi sconosciute: {', '.join(sorted(extra))}")
        src = str(r.get("sorgente", "")).split(".")
        if len(src) != 3 or src[0] not in dbs or not all(RE_IDENT.match(x) for x in src[1:]):
            raise ErroreConfig(f"{ctx}: sorgente deve essere alias.schema.tabella con alias in 'database'")
        if not any(r.get(op) for op in OPERAZIONI):
            raise ErroreConfig(f"{ctx}: nessuna operazione (lettura/inserimento/modifica/cancellazione)")
        for op in OPERAZIONI:
            for g in lista(r.get(op), f"{ctx}.{op}"):
                if g not in noti:
                    raise ErroreConfig(f"{ctx}.{op}: gruppo sconosciuto '{g}' (definirlo in 'gruppi')")
        if r.get("inserimento") and not r.get("scrivibili"):
            raise ErroreConfig(f"{ctx}: 'inserimento' richiede 'scrivibili'")
        if (r.get("modifica") or r.get("cancellazione")) and not r.get("chiave"):
            raise ErroreConfig(f"{ctx}: 'modifica'/'cancellazione' richiedono 'chiave'")
        if r.get("colonne") and r.get("escludi"):
            raise ErroreConfig(f"{ctx}: usare 'colonne' oppure 'escludi', non entrambi")
        for col, val in (r.get("forzati") or {}).items():
            ok = (isinstance(val, str) and val in FORZATI) or (isinstance(val, dict) and set(val) == {"valore"})
            if not ok:
                raise ErroreConfig(f"{ctx}.forzati.{col}: valore non ammesso ({', '.join(sorted(FORZATI))} o {{valore: ...}})")
            if col in lista(r.get("scrivibili"), "") + lista(r.get("modificabili"), ""):
                raise ErroreConfig(f"{ctx}.forzati.{col}: una colonna forzata non puo' essere anche scrivibile")
    for s in lista(cfg.get("importa"), "importa"):
        p = s.split(".")
        if len(p) != 3 or p[0] not in dbs:
            raise ErroreConfig(f"importa: '{s}' deve essere alias.schema.tabella")
    return cfg


# --------------------------------------------------------------------------- SQL

def genera_sql(cfg: dict, sorgente_cfg: str) -> str:
    out = [
        "-- ============================================================================",
        f"-- GENERATO da bin/genera_api.py ({sorgente_cfg}) il {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC",
        "-- NON MODIFICARE: cambiare config/api.yaml e rigenerare.",
        "-- Uso (da superuser):  psql -d api -v pw_<utente>=... -f sql/generato/50_risorse.sql",
        "-- ============================================================================",
        "\\set ON_ERROR_STOP on",
        "SET client_min_messages = warning;",
        "BEGIN;",
        "",
    ]
    out += ["", "-- gruppi: ruolo PostgreSQL <- gruppi Lizmap"]
    for g, d in cfg["gruppi"].items():
        out.append(f"CALL api_admin.gruppo({sql_lit(g)}, {sql_array(lista(d.get('lizmap'), ''))}, {sql_lit((d or {}).get('descrizione'))});")

    out += ["", "-- database esterni (postgres_fdw)"]
    if any((d or {}).get("postgis") for d in cfg["database"].values()):
        out.append("CREATE EXTENSION IF NOT EXISTS postgis SCHEMA public;")
    for a, d in cfg["database"].items():
        ro = d["utente_lettura"]
        rw = d.get("utente_scrittura") or ro
        out.append(
            f"CALL api_admin.database({sql_lit(a)}, {sql_lit(d['dbname'])}, {sql_lit(d['host'])}, {int(d['port'])}, "
            f"{sql_lit(ro)}, :'{var_pw(ro)}', {sql_lit(rw)}, :'{var_pw(rw)}', "
            f"{sql_lit('postgis') if d.get('postgis') else 'NULL'});")

    # importazioni: sorgenti delle risorse + tabelle usate dai servizi
    imp_tab: dict[tuple[str, str], list[str]] = {}
    fonti = [r["sorgente"] for r in cfg["risorse"].values()] + lista(cfg.get("importa"), "")
    cal = ((cfg.get("servizi") or {}).get("calendario") or {})
    fonti += list((cal.get("tab") or {}).values())
    for s in fonti:
        a, sch, t = s.split(".")
        lst = imp_tab.setdefault((a, sch), [])
        if t not in lst:
            lst.append(t)
    out += ["", "-- tabelle esterne"]
    for (a, sch), tabs in imp_tab.items():
        out.append(f"CALL api_admin.importa({sql_lit(a)}, {sql_lit(sch)}, {sql_array(tabs)});")

    out += ["", "-- risorse (viste in schema api + GRANT)"]
    nomi = []
    for nome, r in cfg["risorse"].items():
        d = {"nome": nome}
        for k in ("descrizione", "sorgente", "chiave", "filtro"):
            if r.get(k) is not None:
                d[k] = str(r[k])
        for k in ("colonne", "escludi", "scrivibili", "modificabili", *OPERAZIONI):
            if r.get(k) is not None:
                d[k] = lista(r[k], k)
        if r.get("forzati"):
            d["forzati"] = r["forzati"]
        out.append(f"CALL api_admin.risorsa({dollar(json.dumps(d, ensure_ascii=False))}::jsonb);")
        nomi.append(nome)

    out += ["", "-- risorse non piu' presenti nella configurazione",
            "DO $$ DECLARE n text; BEGIN",
            f"  FOR n IN SELECT nome FROM api_auth.risorse WHERE nome <> ALL ({sql_array(nomi)}) LOOP",
            "    CALL api_admin.rimuovi_risorsa(n); RAISE NOTICE 'Rimossa risorsa %', n;",
            "  END LOOP;",
            "END $$;"]

    out += ["", "-- configurazione dei servizi"]
    for nome, s in (cfg.get("servizi") or {}).items():
        if nome == "calendario":
            out.append(f"CALL api_admin.impostazione('calendario', {dollar(json.dumps(s, ensure_ascii=False))}::jsonb);")

    out += ["", "COMMIT;", "", "-- PostgREST ricarica la struttura", "NOTIFY pgrst, 'reload schema';", ""]
    return "\n".join(out)


# --------------------------------------------------------------------------- postgrest

def genera_postgrest(cfg: dict) -> str:
    api = cfg["api"]
    porta = int(str(api.get("postgrest", "http://127.0.0.1:3100")).rsplit(":", 1)[-1].strip("/"))
    return f"""# PostgREST per Prosit API v2 — GENERATO da bin/genera_api.py (modificare config/api.yaml)
# La password di authenticator NON e' qui: PGRST_DB_URI in /etc/prosit-api/postgrest.env
db-schemas = "api"
db-anon-role = "web_anon"
db-pre-request = "api_fn.pre_request"
db-extra-search-path = "public"
db-max-rows = {int(api.get('righe_massime', 5000))}
db-pool = 10
db-pool-acquisition-timeout = 10
db-plan-enabled = false
db-aggregates-enabled = false
db-tx-end = "commit"

# Token firmati dal modulo Lizmap (RS256): qui solo la chiave PUBBLICA
jwt-secret = "@/etc/prosit-api/jwt-pubblica.jwk"
jwt-aud = "{api.get('audience', 'prosit-api')}"
jwt-role-claim-key = ".role"

# Solo in locale: dall'esterno si passa sempre da Lizmap
server-host = "127.0.0.1"
server-port = {porta}
admin-server-host = "127.0.0.1"
admin-server-port = {porta + 1}
server-timing-enabled = false

# La documentazione e' openapi/prosit-api-v2.yaml (curata): niente OpenAPI automatico
openapi-mode = "disabled"
log-level = "error"
"""


# --------------------------------------------------------------------------- OpenAPI

TIPI_JSON = {
    "N": {"type": "number"}, "B": {"type": "boolean"}, "D": {"type": "string", "format": "date-time"},
    "S": {"type": "string"}, "U": {"type": "string"}, "A": {"type": "array", "items": {}},
}


def schema_colonna(c: dict) -> dict:
    udt, cat, tipo = c.get("udt", ""), c.get("categoria", "S"), c.get("tipo", "")
    if udt in ("int2", "int4", "int8"):
        s = {"type": "integer"}
    elif udt in ("json", "jsonb"):
        s = {}
    elif udt == "date":
        s = {"type": "string", "format": "date"}
    elif udt in ("geometry", "geography"):
        s = {"type": "string", "description": "geometria (EWKB esadecimale; GeoJSON con Accept: application/geo+json)"}
    elif udt == "uuid":
        s = {"type": "string", "format": "uuid"}
    else:
        s = dict(TIPI_JSON.get(cat, {"type": "string"}))
    s["x-tipo-postgresql"] = tipo
    s["nullable"] = True
    return s


def genera_openapi(cfg: dict, catalogo: dict | None) -> dict:
    api = cfg["api"]
    cat_ris = {r["nome"]: r for r in (catalogo or {}).get("risorse", [])}
    cat_fun = {f["nome"]: f for f in (catalogo or {}).get("funzioni", [])}
    gruppi_desc = "\n".join(
        f"- `{g}`: {(d or {}).get('descrizione', '')} (Lizmap: {', '.join(lista(d.get('lizmap'), ''))})"
        for g, d in cfg["gruppi"].items())

    def problema(desc):
        return {"description": desc, "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/Problema"}}}}

    errori = {"400": problema("Richiesta non valida"), "401": problema("Non autenticato"),
              "403": problema("Permessi insufficienti"), "429": problema("Troppe richieste")}

    doc: dict = {
        "openapi": "3.0.3",
        "info": {
            "title": "Prosit API",
            "version": "2.0.0",
            "description": (
                "API REST dei servizi Prosit (segnalazioni, videosorveglianza, manomissioni, verde, illuminazione).\n\n"
                "Esposte da PostgREST tramite il modulo Lizmap prositapi. I permessi sono GRANT di PostgreSQL sui ruoli di "
                "gruppo, assegnati in base ai gruppi Lizmap dell'utente.\n\n"
                "**Autenticazione**: sessione Lizmap (cookie, dal browser) oppure HTTP Basic con un utente Lizmap che ha il "
                "diritto `prosit.api.programmi` (Amministrazione -> Diritti). Solo HTTPS.\n\n"
                "**Filtri** (sintassi PostgREST): `?colonna=eq.valore`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, "
                "`in.(a,b)`, `is.null`; `select=a,b`, `order=data.desc`, `limit`, `offset`. Totale: `Prefer: count=exact` "
                "(intestazione `Content-Range`).\n\n"
                f"**Gruppi**:\n{gruppi_desc}\n- `utenti`: qualunque utente Lizmap autenticato"),
            "contact": {"name": "Prosit"},
        },
        "servers": [{"url": api.get("server_pubblico", "").rstrip("/") + api["percorso"].rstrip("/")}],
        "security": [{"sessioneLizmap": []}, {"basic": []}],
        "tags": [{"name": "stato"}, {"name": "autenticazione"}, {"name": "risorse"}, {"name": "servizi"}],
        "paths": {},
        "components": {
            "securitySchemes": {
                "sessioneLizmap": {"type": "apiKey", "in": "cookie", "name": "PHPSESSID",
                                   "description": "Sessione di Lizmap (browser). Le modifiche richiedono l'intestazione Origin dello stesso sito."},
                "basic": {"type": "http", "scheme": "basic",
                          "description": "Utente Lizmap con il diritto prosit.api.programmi. Solo HTTPS."},
            },
            "parameters": {
                "select": {"name": "select", "in": "query", "schema": {"type": "string"}, "description": "Colonne da restituire, es. `a,b`"},
                "order": {"name": "order", "in": "query", "schema": {"type": "string"}, "description": "Ordinamento, es. `data.desc,id`"},
                "limit": {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1}},
                "offset": {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
                "prefer": {"name": "Prefer", "in": "header", "schema": {"type": "string"},
                           "description": "`count=exact`, `return=representation`"},
            },
            "schemas": {
                "Problema": {
                    "type": "object", "description": "RFC 7807 Problem Details",
                    "properties": {
                        "type": {"type": "string"}, "title": {"type": "string"}, "status": {"type": "integer"},
                        "detail": {"type": "string"}, "instance": {"type": "string"},
                        "codice": {"type": "string", "description": "codice PostgREST/PostgreSQL"},
                        "request_id": {"type": "string"},
                    },
                    "required": ["title", "status"],
                },
            },
        },
    }
    P = doc["paths"]
    ok_json = lambda desc, schema=None: {"description": desc, "content": {"application/json": {"schema": schema or {"type": "object"}}}}

    P["/status"] = {"get": {"tags": ["stato"], "summary": "Stato del servizio", "security": [],
                            "responses": {"200": ok_json("Servizio funzionante"), "503": problema("Servizio non disponibile")}}}
    P["/auth/me"] = {"get": {"tags": ["autenticazione"], "summary": "Utente corrente letto da Lizmap (utente, gruppi, tipo di accesso, diritto programmi)",
                             "responses": {"200": ok_json("Utente"), **errori}}}
    P["/rpc/io"] = {"get": {"tags": ["autenticazione"], "summary": "Utente, gruppi Lizmap e ruoli PostgreSQL effettivi",
                            "responses": {"200": ok_json("Profilo"), **errori}}}
    P["/risorse"] = {"get": {"tags": ["risorse"], "summary": "Risorse accessibili all'utente e operazioni consentite",
                             "responses": {"200": ok_json("Elenco", {"type": "array", "items": {"type": "object"}}), **errori}}}

    for nome, r in cfg["risorse"].items():
        cr = cat_ris.get(nome, {})
        perm = cr.get("permessi") or {op: lista(r.get(op), op) for op in OPERAZIONI}
        sch_nome = "R_" + nome.replace("-", "_")
        props, ins_props, upd_props = {}, {}, {}
        for c in cr.get("colonne") or []:
            props[c["nome"]] = schema_colonna(c)
            if c.get("scrivibile"):
                ins_props[c["nome"]] = schema_colonna(c)
            if c.get("modificabile"):
                upd_props[c["nome"]] = schema_colonna(c)
        if not props:
            props = {"(colonne)": {"description": "Generare con il catalogo del database per l'elenco delle colonne"}}
            ins_props = {c: {} for c in lista(r.get("scrivibili"), "")}
            upd_props = {c: {} for c in lista(r.get("modificabili") or r.get("scrivibili"), "")}
        doc["components"]["schemas"][sch_nome] = {"type": "object", "description": r.get("descrizione", nome), "properties": props}
        item: dict = {}
        desc = (r.get("descrizione") or nome)
        if perm.get("lettura"):
            item["get"] = {"tags": ["risorse"], "summary": desc, "x-gruppi": perm["lettura"],
                           "parameters": [{"$ref": f"#/components/parameters/{p}"} for p in ("select", "order", "limit", "offset", "prefer")],
                           "responses": {"200": ok_json("Righe", {"type": "array", "items": {"$ref": f"#/components/schemas/{sch_nome}"}}), **errori}}
        if perm.get("inserimento"):
            forz = ", ".join(f"`{k}`" for k in (r.get("forzati") or {}))
            item["post"] = {"tags": ["risorse"], "summary": f"Inserimento: {desc}", "x-gruppi": perm["inserimento"],
                            "description": f"Colonne ammesse: {', '.join(ins_props)}." + (f" Impostate dal database: {forz}." if forz else ""),
                            "parameters": [{"$ref": "#/components/parameters/prefer"}],
                            "requestBody": {"required": True, "content": {"application/json": {"schema": {"oneOf": [
                                {"type": "object", "properties": ins_props, "additionalProperties": False},
                                {"type": "array", "items": {"type": "object", "properties": ins_props, "additionalProperties": False}}]}}}},
                            "responses": {"201": {"description": "Creato"}, **errori}}
        if perm.get("modifica"):
            item["patch"] = {"tags": ["risorse"], "summary": f"Modifica: {desc}", "x-gruppi": perm["modifica"],
                             "description": f"Filtro obbligatorio sulla chiave, es. `?{r.get('chiave')}=eq.123`.",
                             "parameters": [{"$ref": "#/components/parameters/prefer"}],
                             "requestBody": {"required": True, "content": {"application/json": {"schema": {
                                 "type": "object", "properties": upd_props, "additionalProperties": False}}}},
                             "responses": {"204": {"description": "Modificato"}, "200": ok_json("Modificato (return=representation)"), **errori}}
        if perm.get("cancellazione"):
            item["delete"] = {"tags": ["risorse"], "summary": f"Cancellazione: {desc}", "x-gruppi": perm["cancellazione"],
                              "description": f"Filtro obbligatorio sulla chiave, es. `?{r.get('chiave')}=eq.123`.",
                              "responses": {"204": {"description": "Cancellato"}, **errori}}
        P["/" + nome] = item

    # RPC dei servizi
    rpc = {
        "segnalazione_mail": ("post", "Mette in coda la mail del ticket verso il gruppo assegnatario", {"seg_id": {"type": "integer"}}),
        "calendario_contesto": ("get", "Calendario: ruolo dell'utente e configurazione", None),
        "calendario_interventi": ("get", "Calendario: interventi nel periodo (dal, al)", None),
        "calendario_crea": ("post", "Calendario: nuovo intervento",
                            {"tipo": {"type": "string"}, "data": {"type": "string", "format": "date"}, "id_zona": {"type": "integer"},
                             "strada": {"type": "string"}, "execution": {"type": "boolean"},
                             "ripeti": {"type": "object", "properties": {"fino_a": {"type": "string", "format": "date"},
                                                                         "giorni": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 7}}}}}),
        "calendario_modifica": ("post", "Calendario: modifica intervento",
                                {"id": {"type": "integer"}, "fonte": {"type": "string", "enum": ["verde", "strade"]}, "dati": {"type": "object"}}),
        "calendario_elimina": ("post", "Calendario: cancella intervento",
                               {"id": {"type": "integer"}, "fonte": {"type": "string", "enum": ["verde", "strade"]}}),
    }
    for fn, (metodo, summary, body) in rpc.items():
        f = cat_fun.get(fn, {})
        op = {"tags": ["servizi"], "summary": f.get("descrizione") or summary, "x-gruppi": f.get("gruppi", ["utenti"]),
              "responses": {"200": ok_json("Risultato"), **errori}}
        if metodo == "get" and fn == "calendario_interventi":
            op["parameters"] = [{"name": n, "in": "query", "schema": {"type": "string", "format": "date"}} for n in ("dal", "al")]
        if body:
            op["requestBody"] = {"required": True, "content": {"application/json": {"schema": {"type": "object", "properties": body}}}}
        P["/rpc/" + fn.replace("_", "-")] = {metodo: op}

    return doc


# --------------------------------------------------------------------------- main

def leggi_catalogo(args) -> dict | None:
    if args.catalogo:
        return json.loads(Path(args.catalogo).read_text(encoding="utf-8"))
    if args.psql:
        cmd = args.psql.split() + ["-XAtq", "-c", "SELECT api_admin.catalogo()"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            print(f"ATTENZIONE: catalogo non letto ({r.stderr.strip()}); OpenAPI senza colonne", file=sys.stderr)
            return None
        return json.loads(r.stdout)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Genera SQL, configurazioni e OpenAPI della Prosit API v2")
    ap.add_argument("--config", default=str(RADICE / "config" / "api.yaml"))
    ap.add_argument("--uscita", default=str(RADICE))
    ap.add_argument("--catalogo", help="file JSON di api_admin.catalogo()")
    ap.add_argument("--psql", help='comando psql per leggere il catalogo, es. "psql -d api"')
    ap.add_argument("--solo-openapi", action="store_true")
    args = ap.parse_args()

    try:
        cfg = valida(yaml.safe_load(Path(args.config).read_text(encoding="utf-8")))
    except (ErroreConfig, yaml.YAMLError, OSError) as e:
        print(f"ERRORE in {args.config}: {e}", file=sys.stderr)
        return 2

    out = Path(args.uscita)
    if not args.solo_openapi:
        (out / "sql/generato").mkdir(parents=True, exist_ok=True)
        (out / "sql/generato/50_risorse.sql").write_text(genera_sql(cfg, Path(args.config).name), encoding="utf-8")
        (out / "postgrest").mkdir(parents=True, exist_ok=True)
        (out / "postgrest/prosit-api.conf").write_text(genera_postgrest(cfg), encoding="utf-8")
    catalogo = leggi_catalogo(args)
    (out / "openapi").mkdir(parents=True, exist_ok=True)
    (out / "openapi/prosit-api-v2.yaml").write_text(
        "# GENERATO da bin/genera_api.py — modificare config/api.yaml\n"
        + yaml.safe_dump(genera_openapi(cfg, catalogo), sort_keys=False, allow_unicode=True, width=120),
        encoding="utf-8")
    print(f"OK: {len(cfg['risorse'])} risorse, {len(cfg['gruppi'])} gruppi, {len(cfg['database'])} database"
          + (" (OpenAPI con catalogo)" if catalogo else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

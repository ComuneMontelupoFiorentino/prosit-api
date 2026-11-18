<?php
/**
 * Prosit API v2 dentro Lizmap:  https://<server>/lizmap/api.php/prosit/v2/<percorso>
 *
 * Usa solo componenti standard:
 *   - jAuth / jAcl2 di Lizmap   chi e' l'utente, i suoi gruppi, il diritto "prosit.api.programmi"
 *   - jDb di Jelix              allineamento del ruolo PostgreSQL (api_auth.gateway_utente)
 *   - firebase/php-jwt          firma del token RS256 per PostgREST
 *   - estensione curl di PHP    inoltro a PostgREST (solo 127.0.0.1)
 * Tutti i permessi sui dati sono GRANT di PostgreSQL: qui non c'e' nessuna regola sui dati.
 *
 * Autenticazione:
 *   - browser: sessione di Lizmap (stesso cookie); le modifiche richiedono Origin dello stesso sito;
 *   - programmi: HTTP Basic con un utente Lizmap (consigliato un utente tecnico) che ha il diritto
 *     "prosit.api.programmi" (Amministrazione -> Diritti). Solo su HTTPS.
 *
 * Configurazione: /etc/prosit-api/prositapi.ini.php (fuori da Lizmap: sopravvive agli aggiornamenti).
 */
class v2Ctrl extends jController implements jIRestController
{
    /** @var array */
    private $cfg;
    /** @var string */
    private $rid;

    public function get()    { return $this->esegui(); }
    public function post()   { return $this->esegui(); }
    public function put()    { return $this->esegui(); }
    public function delete() { return $this->esegui(); }
    public function patch()  { return $this->esegui(); }
    public function head()   { return $this->esegui(); }

    private function esegui()
    {
        $this->rid = bin2hex(random_bytes(8));
        $tipo = null;
        try {
            $this->cfg = $this->configurazione();
            $percorso = (string) $this->param('percorso');
            if ($percorso === 'status') {
                return $this->stato();
            }
            $tipo = $this->autentica();
            $utente = jAuth::getUserSession();
            $gruppi = $this->gruppiLizmap($utente->login);

            if ($percorso === 'auth/me') {
                return $this->json(200, array(
                    'login' => $utente->login,
                    'nome' => $this->nome($utente),
                    'nome_proprio' => (string) ($utente->firstname ?? ''),
                    'cognome' => (string) ($utente->lastname ?? ''),
                    'email' => (string) ($utente->email ?? ''),
                    'organizzazione' => (string) ($utente->organization ?? ''),
                    'gruppi' => $gruppi,
                    'tipo_accesso' => $tipo,
                    'programmi' => jAcl2::check('prosit.api.programmi'),
                ));
            }
            $ruolo = $this->ruoloPostgres($utente, $gruppi, $tipo);
            return $this->inoltra($percorso, $utente, $gruppi, $ruolo, $tipo);
        } catch (Exception $e) {
            return $this->errore($e);
        } finally {
            if ($tipo === 'programma' || isset($_SERVER['PHP_AUTH_USER'])) {
                // la sessione creata per la richiesta Basic (riuscita o no) non deve restare
                jAuth::logout();
                header_remove('Set-Cookie');
            }
        }
    }

    /* ------------------------------------------------------------------ autenticazione */

    /** @return string 'sessione' | 'programma' */
    private function autentica()
    {
        if (isset($_SERVER['PHP_AUTH_USER'])) {
            if ($this->cfg['richiedi_https'] && !$this->https() && !$this->locale()) {
                throw new RuntimeException('Le credenziali si inviano solo su HTTPS.', 403);
            }
            // stesso metodo usato da Lizmap per le sue API e per WMS (eventi jAuth, utenti disattivati)
            if (!jAuth::login((string) $_SERVER['PHP_AUTH_USER'], (string) ($_SERVER['PHP_AUTH_PW'] ?? ''))) {
                jLog::log('prositapi: accesso Basic rifiutato per ' . substr((string) $_SERVER['PHP_AUTH_USER'], 0, 60)
                    . ' da ' . ($_SERVER['REMOTE_ADDR'] ?? '-'), 'warning');
                usleep(500000);   // rallenta i tentativi ripetuti
                throw new RuntimeException('Credenziali non valide.', 401);
            }
            jAcl2::clearCache();
            if (!jAcl2::check('prosit.api.programmi')) {
                throw new RuntimeException('Utente non abilitato all\'uso delle API da programma (diritto "prosit.api.programmi").', 403);
            }
            return 'programma';
        }
        if (!jAuth::isConnected()) {
            throw new RuntimeException('Sessione Lizmap assente o scaduta: accedere a Lizmap.', 401);
        }
        if (!in_array($_SERVER['REQUEST_METHOD'], array('GET', 'HEAD'), true)) {
            $this->verificaOrigine();   // protezione CSRF per le modifiche fatte dal browser
        }
        return 'sessione';
    }

    private function verificaOrigine()
    {
        $ammesse = array_merge(array(($this->https() ? 'https' : 'http') . '://' . strtolower($_SERVER['HTTP_HOST'] ?? '')),
            array_filter((array) $this->cfg['origini_consentite']));
        $o = $_SERVER['HTTP_ORIGIN'] ?? '';
        if ($o === '' && !empty($_SERVER['HTTP_REFERER'])) {
            $r = parse_url($_SERVER['HTTP_REFERER']);
            $o = ($r['scheme'] ?? '') . '://' . ($r['host'] ?? '') . (isset($r['port']) ? ':' . $r['port'] : '');
        }
        if (!in_array(strtolower(rtrim($o, '/')), $ammesse, true)) {
            throw new RuntimeException('Modifica da un\'origine non verificabile: operazione bloccata (CSRF).', 403);
        }
    }

    private function https()
    {
        return !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    }

    private function locale()
    {
        return in_array($_SERVER['REMOTE_ADDR'] ?? '', array('127.0.0.1', '::1'), true);
    }

    /** gruppi Lizmap dell'utente (esclusi i gruppi privati di Jelix) */
    private function gruppiLizmap($login)
    {
        $out = array('id' => array(), 'nome' => array());
        foreach (jAcl2DbUserGroup::getGroupList($login) as $g) {
            if ((int) $g->grouptype !== 2) {
                $out['id'][] = (string) $g->id_aclgrp;
                $out['nome'][] = (string) $g->name;
            }
        }
        return $out;
    }

    private function nome($u)
    {
        $n = trim(($u->firstname ?? '') . ' ' . ($u->lastname ?? ''));
        return $n !== '' ? $n : $u->login;
    }

    /* ------------------------------------------------------------------ PostgreSQL e token */

    private function ruoloPostgres($u, array $gruppi, $tipo)
    {
        jProfiles::createVirtualProfile('jdb', 'prositapi', array(
            'driver' => 'pgsql', 'host' => $this->cfg['db_host'], 'port' => $this->cfg['db_porta'],
            'database' => 'api', 'user' => $this->cfg['db_utente'], 'password' => $this->cfg['db_password'],
        ));
        $tutti = array_values(array_unique(array_merge($gruppi['id'], $gruppi['nome'])));
        $arr = '{' . implode(',', array_map(function ($x) { return '"' . addcslashes($x, '"\\') . '"'; }, $tutti)) . '}';
        $st = jDb::getConnection('prositapi')->prepare('SELECT api_auth.gateway_utente(:l, :n, :e, CAST(:g AS text[]), :t) AS ruolo');
        $st->execute(array('l' => $u->login, 'n' => $this->nome($u), 'e' => (string) ($u->email ?? ''), 'g' => $arr, 't' => $tipo));
        return $st->fetch()->ruolo;
    }

    private function token($u, array $gruppi, $ruolo, $tipo)
    {
        $lib = rtrim($this->cfg['php_jwt'], '/');
        if (!is_file($lib . '/JWT.php')) {
            throw new RuntimeException('Libreria firebase/php-jwt non trovata in ' . $lib, 503);
        }
        spl_autoload_register(function ($c) use ($lib) {
            if (strncmp($c, 'Firebase\\JWT\\', 13) === 0 && is_file($f = $lib . '/' . substr($c, 13) . '.php')) {
                require_once $f;
            }
        });
        $ora = time();
        $claims = array(
            'iss' => 'prosit-lizmap', 'aud' => $this->cfg['audience'], 'sub' => $u->login, 'role' => $ruolo,
            'iat' => $ora, 'nbf' => $ora - 5, 'exp' => $ora + (int) $this->cfg['durata_token'], 'jti' => bin2hex(random_bytes(12)),
            'auth' => $tipo, 'nome' => $this->nome($u), 'email' => (string) ($u->email ?? ''),
            'gruppi' => array_values(array_unique(array_map('mb_strtolower', array_merge($gruppi['id'], $gruppi['nome'])))),
        );
        return \Firebase\JWT\JWT::encode($claims, file_get_contents($this->cfg['jwt_privata']), 'RS256', $this->cfg['jwt_kid']);
    }

    /* ------------------------------------------------------------------ inoltro a PostgREST */

    private function inoltra($percorso, $u, array $gruppi, $ruolo, $tipo)
    {
        $metodo = $_SERVER['REQUEST_METHOD'];
        if (!in_array($metodo, array('GET', 'HEAD', 'POST', 'PATCH', 'DELETE'), true)) {
            throw new RuntimeException('Metodo non consentito.', 405);
        }
        $rpc = strncmp($percorso, 'rpc/', 4) === 0;
        if (!$rpc && strpos($percorso, '/') !== false) {
            throw new RuntimeException('Percorso non trovato.', 404);
        }
        $qs = (string) ($_SERVER['QUERY_STRING'] ?? '');
        if (in_array($metodo, array('PATCH', 'DELETE'), true) && !$rpc
            && !preg_match('/(^|&)(?!(select|order|limit|offset)=)[^=&]+=[^&]+/', $qs)) {
            throw new RuntimeException('Per modificare o cancellare serve almeno un filtro (es. ?id=eq.123).', 400);
        }
        $h = array('Authorization: Bearer ' . $this->token($u, $gruppi, $ruolo, $tipo), 'X-Request-Id: ' . $this->rid);
        $acc = strtolower(trim(explode(';', explode(',', $_SERVER['HTTP_ACCEPT'] ?? 'application/json')[0])[0]));
        $h[] = 'Accept: ' . (in_array($acc, array('application/json', 'application/geo+json', 'text/csv', 'application/vnd.pgrst.object+json'), true) ? $acc : 'application/json');
        $pref = array_filter(array_map('trim', explode(',', strtolower($_SERVER['HTTP_PREFER'] ?? ''))),
            function ($p) { return (bool) preg_match('/^(return=(representation|minimal)|count=(exact|planned|estimated)|missing=default)$/', $p); });
        if ($pref) {
            $h[] = 'Prefer: ' . implode(', ', $pref);
        }
        $ch = curl_init(rtrim($this->cfg['postgrest'], '/') . '/' . str_replace('-', '_', $percorso) . ($qs !== '' ? '?' . $qs : ''));
        if ($metodo === 'POST' || $metodo === 'PATCH') {
            if (stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== 0) {
                throw new RuntimeException('Il corpo deve essere JSON (Content-Type: application/json).', 415);
            }
            $corpo = (string) file_get_contents('php://input', false, null, 0, (int) $this->cfg['corpo_massimo'] + 1);
            if (strlen($corpo) > (int) $this->cfg['corpo_massimo']) {
                throw new RuntimeException('Corpo della richiesta troppo grande.', 413);
            }
            $h[] = 'Content-Type: application/json';
            curl_setopt($ch, CURLOPT_POSTFIELDS, $corpo);
        }
        $rh = array();
        curl_setopt_array($ch, array(
            CURLOPT_CUSTOMREQUEST => $metodo, CURLOPT_NOBODY => $metodo === 'HEAD', CURLOPT_HTTPHEADER => $h,
            CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_TIMEOUT => 60, CURLOPT_PROTOCOLS => CURLPROTO_HTTP,
            CURLOPT_HEADERFUNCTION => function ($c, $l) use (&$rh) {
                if (($p = strpos($l, ':')) !== false) {
                    $rh[strtolower(trim(substr($l, 0, $p)))] = trim(substr($l, $p + 1));
                }
                return strlen($l);
            },
        ));
        $corpo = curl_exec($ch);
        $stato = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        if ($corpo === false || $stato === 0) {
            throw new RuntimeException('Servizio dati non disponibile, riprovare tra poco.', 503);
        }
        if ($stato >= 400) {
            return $this->erroreDb($stato, (string) $corpo);
        }
        $rep = $this->risposta($stato, $rh['content-type'] ?? 'application/json');
        foreach (array('content-range' => 'Content-Range', 'preference-applied' => 'Preference-Applied') as $k => $n) {
            if (isset($rh[$k])) {
                $rep->addHttpHeader($n, $rh[$k]);
            }
        }
        $rep->content = (string) $corpo;
        return $rep;
    }

    /* ------------------------------------------------------------------ risposte */

    private function stato()
    {
        $ch = curl_init(rtrim($this->cfg['postgrest_admin'], '/') . '/ready');
        curl_setopt_array($ch, array(CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 3, CURLOPT_PROTOCOLS => CURLPROTO_HTTP));
        curl_exec($ch);
        $ok = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE) === 200;
        curl_close($ch);
        if (!$ok) {
            throw new RuntimeException('Servizio non disponibile.', 503);
        }
        return $this->json(200, array('stato' => 'ok', 'versione' => '2.0.1'));
    }

    private function risposta($stato, $tipo)
    {
        $rep = $this->getResponse('text');
        $rep->setHttpStatus((string) $stato, $stato < 400 ? 'OK' : 'Error');
        $rep->mimeType = preg_replace('/;.*$/', '', $tipo);
        $rep->addHttpHeader('X-Content-Type-Options', 'nosniff');
        $rep->addHttpHeader('X-Frame-Options', 'DENY');
        $rep->addHttpHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
        $rep->addHttpHeader('Cache-Control', 'no-store');
        $rep->addHttpHeader('X-Request-Id', $this->rid);
        return $rep;
    }

    private function json($stato, $dati, $tipo = 'application/json')
    {
        $rep = $this->risposta($stato, $tipo);
        $rep->content = json_encode($dati, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        return $rep;
    }

    /** Errori in application/problem+json (RFC 7807), senza dettagli interni */
    private function problema($stato, $dettaglio)
    {
        $rep = $this->json($stato, array('type' => 'about:blank', 'title' => $stato >= 500 ? 'Errore del servizio' : 'Errore della richiesta',
            'status' => $stato, 'detail' => $dettaglio, 'request_id' => $this->rid), 'application/problem+json');
        if ($stato === 401) {
            $rep->addHttpHeader('WWW-Authenticate', 'Basic realm="Prosit API", charset="UTF-8"');
        }
        if ($stato === 503) {
            $rep->addHttpHeader('Retry-After', '30');
        }
        return $rep;
    }

    private function errore(Exception $e)
    {
        $c = (int) $e->getCode();
        if ($e instanceof RuntimeException && $c >= 400 && $c < 600) {
            return $this->problema($c, $e->getMessage());
        }
        jLog::log('prositapi [' . $this->rid . '] ' . get_class($e) . ': ' . $e->getMessage(), 'error');
        return $this->problema(500, 'Errore interno: codice ' . $this->rid . '.');
    }

    /** Errori di PostgREST: si mostrano solo i messaggi scritti apposta nelle funzioni (RAISE) */
    private function erroreDb($stato, $corpo)
    {
        $e = json_decode($corpo, true);
        $cod = (string) ($e['code'] ?? '');
        $msg = trim((string) ($e['message'] ?? ''));
        jLog::log('prositapi [' . $this->rid . '] PostgREST ' . $stato . ' ' . $cod . ': ' . $msg . ' | ' . ($e['details'] ?? '') . ' | ' . ($e['hint'] ?? ''), 'warning');
        if (in_array($cod, array('P0001', '22023'), true)) {
            return $this->problema(422, $msg);
        }
        if ($cod === 'P0002') {
            return $this->problema(404, $msg);
        }
        if ($cod === '42501') {
            return $this->problema(403, stripos($msg, 'permission denied') === false ? $msg : 'Permessi insufficienti per questa operazione.');
        }
        if ($cod === '44000') {
            return $this->problema(403, 'Il record non rientra tra quelli che puoi creare o modificare.');
        }
        if ($stato >= 500) {
            return $this->problema(502, 'Errore del servizio dati: codice ' . $this->rid . '.');
        }
        if (strncmp($cod, 'PGRST1', 6) === 0 || in_array($cod, array('42703', '42883', 'PGRST204', 'PGRST205'), true)) {
            return $this->problema(400, $msg);   // filtri o colonne errati: messaggio utile, non interno
        }
        return $this->problema($stato, $stato === 409 ? 'Conflitto con dati esistenti.' : 'Richiesta non valida.');
    }

    /* ------------------------------------------------------------------ configurazione */

    private function configurazione()
    {
        $f = (string) (jApp::config()->prositapi['config'] ?? '/etc/prosit-api/prositapi.ini.php');
        $c = is_readable($f) ? parse_ini_file($f, false, INI_SCANNER_TYPED) : false;
        if (!$c || empty($c['db_password']) || empty($c['jwt_privata'])) {
            throw new RuntimeException('Prosit API non configurata (' . $f . ').', 503);
        }
        return array_merge(array(
            'postgrest' => 'http://127.0.0.1:3100', 'postgrest_admin' => 'http://127.0.0.1:3101',
            'audience' => 'prosit-api', 'jwt_kid' => 'prosit-lz-1', 'durata_token' => 60,
            'db_host' => '127.0.0.1', 'db_porta' => 5432, 'db_utente' => 'api_gateway',
            'php_jwt' => '/opt/prosit-api/lib/php-jwt/src', 'richiedi_https' => true,
            'origini_consentite' => array(), 'corpo_massimo' => 1048576,
        ), $c);
    }
}

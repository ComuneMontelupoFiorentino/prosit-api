<?php
/**
 * SOLO PER I TEST: un sostituto minimo di PostgREST, per collaudare il gateway quando il
 * binario di PostgREST non e' disponibile. Riproduce quello che conta per la sicurezza:
 *   - verifica del JWT RS256 con la chiave pubblica (firma, aud, exp, nbf, role);
 *   - connessione come authenticator, set_config di role / request.jwt.claims / request.method /
 *     request.path / request.headers, poi db-pre-request, poi la query;
 *   - errori PostgreSQL in JSON {code,message,details,hint} con gli stati HTTP di PostgREST.
 * Sintassi supportata: filtri col=eq|neq|gt|lt|gte|lte|isdistinct|ilike.valore, in.(...), is.null, select, order=col.desc, limit;
 * POST oggetto JSON; PATCH/DELETE con filtri; /rpc/funzione (GET con parametri, POST con JSON).
 * Sul server reale si usa PostgREST: vedi tests/collaudo_vm.sh.
 */
declare(strict_types=1);

$PUB = getenv('FINTO_PUB');
$DSN = getenv('FINTO_DSN');
$AUD = 'prosit-api';

function esci(int $s, array $b): never { http_response_code($s); header('Content-Type: application/json'); echo json_encode($b); exit; }
function b64d(string $s): string { return base64_decode(strtr($s, '-_', '+/') . str_repeat('=', (4 - strlen($s) % 4) % 4)); }
function qi(string $s): string { if (!preg_match('/^[a-z_][a-z0-9_]*$/', $s)) { esci(400, ['code' => 'PGRST100', 'message' => "nome non valido: $s"]); } return '"' . $s . '"'; }

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/ready') { http_response_code(200); exit; }

// --- JWT
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if (!preg_match('/^Bearer ([\w-]+)\.([\w-]+)\.([\w-]+)$/', $auth, $m)) esci(401, ['code' => 'PGRST301', 'message' => 'No JWT']);
$h = json_decode(b64d($m[1]), true); $c = json_decode(b64d($m[2]), true);
if (($h['alg'] ?? '') !== 'RS256') esci(401, ['code' => 'PGRST301', 'message' => 'alg']);
if (openssl_verify($m[1] . '.' . $m[2], b64d($m[3]), file_get_contents($PUB), OPENSSL_ALGO_SHA256) !== 1) esci(401, ['code' => 'PGRST301', 'message' => 'firma']);
if (($c['aud'] ?? '') !== $AUD || ($c['exp'] ?? 0) < time() || ($c['nbf'] ?? 0) > time()) esci(401, ['code' => 'PGRST303', 'message' => 'claims']);
$role = (string) ($c['role'] ?? '');

$metodo = $_SERVER['REQUEST_METHOD'];
$hdr = []; foreach ($_SERVER as $k => $v) if (str_starts_with($k, 'HTTP_')) $hdr[strtolower(str_replace('_', '-', substr($k, 5)))] = $v;
$pdo = new PDO($DSN, 'authenticator', getenv('FINTO_PASS') ?: 'auth_test', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
try {
    $pdo->beginTransaction();
    $pdo->prepare("SELECT set_config('role', ?, true), set_config('request.jwt.claims', ?, true), set_config('request.method', ?, true), set_config('request.path', ?, true), set_config('request.headers', ?, true), set_config('search_path', 'api, public', true)")
        ->execute([$role, json_encode($c), $metodo, $path, json_encode($hdr)]);
    $pdo->query('SELECT api_fn.pre_request()');

    $q = []; parse_str($_SERVER['QUERY_STRING'] ?? '', $q);
    $where = []; $par = [];
    $ops = ['eq' => '=', 'neq' => '<>', 'gt' => '>', 'lt' => '<', 'gte' => '>=', 'lte' => '<=', 'isdistinct' => 'IS DISTINCT FROM', 'ilike' => 'ILIKE'];
    foreach ($q as $k => $v) {
        if (in_array($k, ['select', 'order', 'limit', 'offset'], true)) continue;
        if (str_starts_with($path, '/rpc/')) continue;
        if (preg_match('/^(not\.)?is\.null$/', (string) $v, $mm)) { $where[] = qi($k) . ($mm[1] ? ' IS NOT NULL' : ' IS NULL'); continue; }
        if (preg_match('/^(not\.)?in\.\((.*)\)$/s', (string) $v, $mm)) {
            $vals = array_map(fn($x) => trim(stripslashes($x), '"'), str_getcsv($mm[2], ',', '"', '\\'));
            $where[] = qi($k) . ($mm[1] ? ' NOT IN (' : ' IN (') . implode(',', array_fill(0, count($vals), '?')) . ')'; array_push($par, ...$vals); continue;
        }
        if (!preg_match('/^(eq|neq|gt|lt|gte|lte|isdistinct|ilike)\.(.*)$/s', (string) $v, $mm)) esci(400, ['code' => 'PGRST100', 'message' => "failed to parse filter ($k=$v)"]);
        $where[] = qi($k) . ' ' . $ops[$mm[1]] . ' ?'; $par[] = $mm[1] === 'ilike' ? str_replace('*', '%', $mm[2]) : $mm[2];
    }
    $w = $where ? ' WHERE ' . implode(' AND ', $where) : '';
    $body = file_get_contents('php://input');
    $ret = str_contains($_SERVER['HTTP_PREFER'] ?? '', 'return=representation');

    if (preg_match('#^/rpc/([a-z_]+)$#', $path, $mm)) {
        $args = $metodo === 'GET' ? array_diff_key($q, array_flip(['select', 'order', 'limit'])) : (json_decode($body ?: '{}', true) ?? []);
        $named = []; $par = [];
        foreach ($args as $k => $v) { $named[] = qi($k) . ' => ?'; $par[] = is_array($v) ? json_encode($v) : $v; }
        $st = $pdo->prepare('SELECT api.' . qi($mm[1]) . '(' . implode(', ', $named) . ') AS r');
        $st->execute($par);
        $r = $st->fetchColumn();
        $pdo->commit();
        header('Content-Type: application/json'); echo $r; exit;
    }
    if (!preg_match('#^/([a-z_]+)$#', $path, $mm)) esci(404, ['code' => 'PGRST125', 'message' => 'Invalid path']);
    $rel = 'api.' . qi($mm[1]);
    if ($metodo === 'GET') {
        $sel = isset($q['select']) ? implode(', ', array_map('qi', explode(',', $q['select']))) : '*';
        $ord = '';
        if (isset($q['order'])) { [$oc, $od] = explode('.', $q['order'] . '.asc'); $ord = ' ORDER BY ' . qi($oc) . ($od === 'desc' ? ' DESC' : ''); }
        $lim = isset($q['limit']) ? ' LIMIT ' . (int) $q['limit'] : '';
        $st = $pdo->prepare("SELECT COALESCE(json_agg(t), '[]') FROM (SELECT $sel FROM $rel$w$ord$lim) t");
        $st->execute($par); $r = $st->fetchColumn(); $pdo->commit();
        header('Content-Type: application/json'); echo $r; exit;
    }
    if ($metodo === 'POST') {
        $d = json_decode($body, true);
        if (!is_array($d) || array_is_list($d)) esci(400, ['code' => 'PGRST102', 'message' => 'Empty or invalid json']);
        $cols = array_map('qi', array_keys($d));
        $st = $pdo->prepare("INSERT INTO $rel (" . implode(', ', $cols) . ') VALUES (' . implode(', ', array_fill(0, count($d), '?')) . ')' . ($ret ? ' RETURNING row_to_json(' . $rel . '.*)' : ''));
        $st->execute(array_map(static fn($v) => is_bool($v) ? ($v ? 'true' : 'false') : (is_array($v) ? json_encode($v) : $v), array_values($d)));
        $r = $ret ? '[' . $st->fetchColumn() . ']' : '';
        $pdo->commit();
        http_response_code(201); header('Content-Type: application/json'); echo $r; exit;
    }
    if ($metodo === 'PATCH') {
        $d = json_decode($body, true);
        $set = []; $p2 = [];
        foreach ($d as $k => $v) { $set[] = qi($k) . ' = ?'; $p2[] = is_bool($v) ? ($v ? 'true' : 'false') : $v; }
        $st = $pdo->prepare("UPDATE $rel SET " . implode(', ', $set) . $w);
        $st->execute(array_merge($p2, $par)); $pdo->commit(); http_response_code(204); exit;
    }
    if ($metodo === 'DELETE') {
        $st = $pdo->prepare("DELETE FROM $rel$w"); $st->execute($par); $pdo->commit(); http_response_code(204); exit;
    }
    esci(405, ['code' => 'PGRST117', 'message' => 'Unsupported HTTP method']);
} catch (PDOException $e) {
    if ($pdo->inTransaction()) $pdo->rollBack();
    $code = (string) ($e->errorInfo[0] ?? '');
    $msg = trim(strtok(preg_replace('/^(SQLSTATE\[[^\]]+\]:[^:]*:\s*\d*\s*)?(ERROR:\s*)?/i', '', $e->errorInfo[2] ?? $e->getMessage()), "\n"));
    // stati come PostgREST (docs/references/errors.rst)
    $s = match (true) {
        $code === '42501' => 403, in_array($code, ['23505', '23503'], true) => 409, $code === '23502' => 400,
        $code === 'P0001' => 400, $code === 'P0002' => 404, $code === '42P01' => 404, $code === '42883' => 404,
        str_starts_with($code, '22') || str_starts_with($code, '23') || str_starts_with($code, '42') => 400,
        $code === '44000' => 403, default => 500,
    };
    esci($s, ['code' => $code, 'message' => $msg, 'details' => 'dettaglio interno', 'hint' => 'suggerimento interno']);
}

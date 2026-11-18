<?php
/**
 * Converte la chiave PUBBLICA RSA (PEM) del modulo Lizmap in JWK per PostgREST (jwt-secret = "@file").
 *   php bin/jwk.php /etc/prosit-api/jwt-pubblica.pem prosit-lz-1 > /etc/prosit-api/jwt-pubblica.jwk
 */
declare(strict_types=1);

[$_, $pem, $kid] = $argv + [null, null, 'prosit-lz-1'];
if (!$pem || !is_readable($pem)) {
    fwrite(STDERR, "uso: php jwk.php <chiave-pubblica.pem> [kid]\n");
    exit(2);
}
$k = openssl_pkey_get_public('file://' . $pem);
$d = $k ? openssl_pkey_get_details($k) : false;
if (!$d || ($d['type'] ?? null) !== OPENSSL_KEYTYPE_RSA || ($d['bits'] ?? 0) < 2048) {
    fwrite(STDERR, "chiave non valida: serve RSA di almeno 2048 bit\n");
    exit(1);
}
$b64 = static fn(string $s): string => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
echo json_encode([
    'kty' => 'RSA', 'alg' => 'RS256', 'use' => 'sig', 'kid' => $kid,
    'n' => $b64($d['rsa']['n']), 'e' => $b64($d['rsa']['e']),
], JSON_UNESCAPED_SLASHES), "\n";

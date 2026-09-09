<?php
/**
 * Blocks until the configured database answers.
 *
 * Deliberately raw PDO rather than a booted application: Railway starts every
 * service at once, so this runs at the point where the framework itself may not
 * be able to boot yet, and a bare connection attempt is the only thing that can
 * be trusted to report the truth.
 */

$driver   = getenv('DB_CONNECTION') ?: 'pgsql';
$host     = getenv('DB_HOST') ?: '127.0.0.1';
$database = getenv('DB_DATABASE') ?: 'october';
$username = getenv('DB_USERNAME') ?: '';
$password = getenv('DB_PASSWORD');
$password = $password === false ? '' : $password;

$defaultPorts = ['pgsql' => '5432', 'mysql' => '3306', 'mariadb' => '3306'];
$port = getenv('DB_PORT') ?: ($defaultPorts[$driver] ?? '5432');

if ($driver === 'sqlite') {
    fwrite(STDERR, "[october-railway] sqlite in use, nothing to wait for\n");
    exit(0);
}

$pdoDriver = $driver === 'mariadb' ? 'mysql' : $driver;
$dsn = sprintf('%s:host=%s;port=%s;dbname=%s', $pdoDriver, $host, $port, $database);

$timeout  = (int) (getenv('OCTOBER_DB_WAIT_SECONDS') ?: 300);
$deadline = time() + max($timeout, 10);
$last     = '';

while (true) {
    try {
        new PDO($dsn, $username, $password, [
            PDO::ATTR_TIMEOUT => 5,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);
        fwrite(STDERR, "[october-railway] database is reachable\n");
        exit(0);
    } catch (Throwable $e) {
        $last = $e->getMessage();
        if (time() >= $deadline) {
            fwrite(STDERR, "[october-railway] database unreachable after {$timeout}s: {$last}\n");
            exit(1);
        }
        sleep(3);
    }
}

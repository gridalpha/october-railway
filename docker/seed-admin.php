<?php
/**
 * Creates the first October CMS administrator from the environment.
 *
 * October has no console command that creates a backend user, and its browser
 * setup screen is only reachable while APP_DEBUG is on — so on a production
 * deployment there is otherwise no way to get an administrator at all. Running
 * it here also means the public listener never opens while the account is
 * unclaimed.
 *
 * Idempotent by design. A hash of the configured credentials is stamped beside
 * the application; a later boot only rewrites the password when that stamp
 * changes, so a password an operator changed in the backend is never reverted.
 */

require '/var/www/html/bootstrap/autoload.php';

$app = require_once '/var/www/html/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

function out(string $message): void
{
    fwrite(STDERR, "[october-railway] {$message}\n");
}

$login     = trim((string) getenv('OCTOBER_ADMIN_LOGIN'));
$email     = trim((string) getenv('OCTOBER_ADMIN_EMAIL'));
$password  = (string) getenv('OCTOBER_ADMIN_PASSWORD');
$firstName = trim((string) getenv('OCTOBER_ADMIN_FIRST_NAME')) ?: 'Site';
$lastName  = trim((string) getenv('OCTOBER_ADMIN_LAST_NAME')) ?: 'Administrator';

if ($login === '' || $email === '' || $password === '') {
    out('OCTOBER_ADMIN_LOGIN, OCTOBER_ADMIN_EMAIL and OCTOBER_ADMIN_PASSWORD are not all set — skipping.');
    exit(0);
}

if (strlen($password) < 8) {
    out('OCTOBER_ADMIN_PASSWORD is shorter than 8 characters — refusing to create an administrator.');
    exit(1);
}

$stampFile = '/var/www/html/storage/.railway-admin-stamp';
$stamp     = hash('sha256', $login . "\0" . $email . "\0" . $password);
$previous  = is_file($stampFile) ? trim((string) file_get_contents($stampFile)) : '';

$existing = Backend\Models\User::where('login', $login)->orWhere('email', $email)->first();

if (!$existing) {
    if (Backend\Models\User::count() > 0) {
        out('Backend accounts already exist and none matches the configured login — leaving them alone.');
        exit(0);
    }

    Backend\Models\User::createDefaultAdmin([
        'first_name'            => $firstName,
        'last_name'             => $lastName,
        'email'                 => $email,
        'login'                 => $login,
        'password'              => $password,
        'password_confirmation' => $password,
    ]);

    file_put_contents($stampFile, $stamp);
    @chmod($stampFile, 0600);
    out("Created the first administrator '{$login}'.");
    exit(0);
}

if ($previous === $stamp) {
    out("Administrator '{$login}' is already in step with the environment.");
    exit(0);
}

$existing->login                 = $login;
$existing->email                 = $email;
$existing->password              = $password;
$existing->password_confirmation = $password;
$existing->is_superuser          = true;
$existing->is_activated          = true;
$existing->forceSave();

Backend\Facades\BackendAuth::clearThrottleForUserId($existing->id);

file_put_contents($stampFile, $stamp);
@chmod($stampFile, 0600);
out("Reset administrator '{$login}' from the environment.");

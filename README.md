# October CMS on Railway

Deployment files for running [October CMS](https://octobercms.com) on
[Railway](https://railway.com) as a production topology: a web tier, a queue
worker, PostgreSQL, Redis and a capture-only mail inbox.

The image is built on October's own production runtime,
[`ghcr.io/octobercms/runtime-prod`](https://github.com/octobercms/runtimes)
(nginx + PHP-FPM + Supervisor, a `/_health` endpoint and a `schedule:work`
program). This repository adds only what Railway needs.

## What this adds

| Piece | Why |
|---|---|
| `composer create-project october/october` in a build stage | October CMS is a project skeleton, not a library, so the application is created at build time and floats inside the 4.x line |
| phpredis, OPcache, exif | Redis backs cache, sessions and the queue; the other two are what a production CMS wants and the base image leaves out |
| `themes/` symlinked onto the volume | The backend editor writes theme files, so they are state. Each shipped theme is seeded once and an existing copy is never overwritten |
| `REMOTE_ADDR` and `HTTPS` FastCGI parameters | Railway's edge terminates TLS and reaches the container over plain HTTP from a rotating address. Without these, October generates `http://` links and its backend login throttle gets a fresh bucket per attempt |
| Boot-time migration and administrator bootstrap | October's browser setup screen only works while `APP_DEBUG` is on, so a production deployment has no other way to get a first administrator |

## Roles

One image, two Railway services.

- **Web** — runs the image default (`supervisord`): nginx, PHP-FPM and, with
  `OCTOBER_SCHEDULER_ENABLED=true`, `php artisan schedule:work`. Owns the volume
  and runs migrations.
- **Worker** — start command
  `/usr/local/bin/october-railway-entrypoint.sh php artisan queue:work --tries=3 --timeout=90`,
  with `OCTOBER_BOOTSTRAP=false` so it does not race the web tier's migrations.

## Variables

| Variable | Notes |
|---|---|
| `OCTOBER_ADMIN_LOGIN` / `_EMAIL` / `_PASSWORD` | The first administrator. Written once; a later change to any of them resets the account, and a password changed in the backend is left alone |
| `OCTOBER_ADMIN_FIRST_NAME` / `_LAST_NAME` | Optional display name |
| `APP_KEY` | Must be stable and identical on both services. Falls back to a key generated onto the volume when unset |
| `OCTOBER_BOOTSTRAP` | `false` on the worker |
| `OCTOBER_SCHEDULER_ENABLED` | `true` on the web service |
| `OCTOBER_DB_WAIT_SECONDS` | How long the entrypoint waits for the database, default 300 |
| `DB_*`, `REDIS_URL`, `MAIL_*` | Standard October CMS configuration |

## Licensing

October CMS is source-available under a
[proprietary EULA](https://github.com/octobercms/october/blob/develop/LICENSE.md).
The platform runs without a licence key; a key obtained from an October CMS
account is what unlocks updates and the Marketplace. Deployers are responsible
for holding a valid licence for their project.

## Local build

```bash
docker build -t october-railway .
```

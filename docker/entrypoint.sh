#!/usr/bin/env bash
#
# Prepares October CMS for a Railway container, then hands off to the image's
# own command. Runs as root; every October command is run as www-data.
#
# Order matters: the storage tree has to exist before anything reads config,
# the database has to answer before migrations, and migrations have to finish
# before the first administrator can be written.
set -euo pipefail

APP_DIR=/var/www/html
STORAGE="$APP_DIR/storage"
THEMES_DIST=/opt/october-themes-dist

log() { echo "[october-railway] $*"; }

# su resets PATH from /etc/login.defs, which need not carry /usr/local/bin —
# where the php binary lives in this image — so it is restated here.
as_app() {
    su -s /bin/bash www-data -c \
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd '$APP_DIR' && $1"
}

umask 022

# ---------------------------------------------------------------------------
# Storage tree
#
# The volume is mounted at $STORAGE, which hides the directory skeleton baked
# into the image. October only creates the directories it declares itself, so a
# missing storage/framework/sessions surfaces much later as "invalid security
# token" on the login form.
# ---------------------------------------------------------------------------
for dir in \
    app/media app/resources app/assets app/public \
    app/uploads/public app/uploads/protected \
    cms/cache cms/combiner cms/twig \
    framework/cache/cms framework/sessions framework/views \
    logs temp/public temp/protected themes
do
    mkdir -p "$STORAGE/$dir"
done
mkdir -p "$APP_DIR/bootstrap/cache"

# ---------------------------------------------------------------------------
# Themes
#
# themes/ is a symlink onto the volume because the backend editor writes there.
# Seed each shipped theme once; an existing directory is the operator's copy and
# is never overwritten, so an image update cannot revert their edits.
# ---------------------------------------------------------------------------
if [ -d "$THEMES_DIST" ]; then
    for theme in "$THEMES_DIST"/*; do
        [ -d "$theme" ] || continue
        name="$(basename "$theme")"
        if [ ! -d "$STORAGE/themes/$name" ]; then
            log "seeding theme '$name' onto the volume"
            cp -a "$theme" "$STORAGE/themes/$name"
        fi
    done
fi
log "themes available: $(ls -A "$STORAGE/themes" 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Application key
#
# Laravel derives session signing and at-rest encryption from APP_KEY, so it has
# to survive every redeploy. The template supplies one; this fallback keeps a
# hand-built project working and stores the key on the volume. A worker sharing
# the queue must be given the same value.
# ---------------------------------------------------------------------------
KEY_FILE="$STORAGE/.railway-app-key"
if [ -z "${APP_KEY:-}" ]; then
    if [ ! -s "$KEY_FILE" ]; then
        printf 'base64:%s' "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        log "generated an APP_KEY and stored it on the volume"
    fi
    APP_KEY="$(cat "$KEY_FILE")"
    export APP_KEY
fi

chown -R www-data:www-data "$STORAGE" "$APP_DIR/bootstrap/cache"

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
log "waiting for the database"
as_app "php /opt/october/db-wait.php"

if [ "${OCTOBER_BOOTSTRAP:-true}" = "true" ]; then
    # Railway has no service ordering and every deploy overlaps the previous
    # container, so the migration is retried rather than assumed to win.
    migrated=0
    for attempt in $(seq 1 12); do
        if as_app "php artisan october:migrate --no-interaction"; then
            migrated=1
            break
        fi
        log "migration attempt $attempt failed, retrying in 10s"
        sleep 10
    done
    if [ "$migrated" != "1" ]; then
        log "FATAL: database migrations did not complete"
        exit 1
    fi

    as_app "php /opt/october/seed-admin.php"
else
    log "OCTOBER_BOOTSTRAP=false — skipping migrations and admin seeding"
fi

chown -R www-data:www-data "$STORAGE" "$APP_DIR/bootstrap/cache"

log "starting: $*"
exec "$@"

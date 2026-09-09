# October CMS on Railway
#
# Built on October's own production runtime image (nginx + PHP-FPM + Supervisor,
# with a `/_health` endpoint and a `schedule:work` program). This repository adds
# only what Railway needs: the October CMS application itself, a Redis client, a
# boot-time database migration and first-administrator bootstrap, and the two
# FastCGI parameters that recover the real client address and the forwarded
# scheme from Railway's edge.
#
# One image serves both roles. The web service runs the image's default command
# (Supervisor); the worker service overrides the start command with
# `queue:work` and sets OCTOBER_BOOTSTRAP=false so it does not race migrations.

# ---------------------------------------------------------------------------
# Stage 1 — create the October CMS project
# ---------------------------------------------------------------------------
FROM composer:2 AS builder

# Floating inside the 4.x line so every deploy of the published template gets
# the current release. Pin a full version here to freeze it.
ARG OCTOBER_VERSION=^4.0

RUN set -eux; \
    composer create-project october/october /build "${OCTOBER_VERSION}" \
        --no-interaction --prefer-dist --no-dev; \
    rm -f /build/.env; \
    test -f /build/artisan; \
    test -d /build/modules; \
    test -d /build/themes/demo

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM ghcr.io/octobercms/runtime-prod:php85

USER root

# phpredis backs the cache, session and queue connections; OPcache and exif are
# the two extensions a production CMS wants that the base image leaves out.
# OPcache is bundled but not built in the base image, so it needs ext-install
# rather than ext-enable — the latter only knows about .so files already present.
# One extension per invocation: naming two in a single parallel ext-install left
# the shared build with nothing to install (`cp: cannot stat 'modules/*'`).
RUN set -eux; \
    yes '' | pecl install redis; \
    docker-php-ext-enable redis; \
    docker-php-ext-install exif; \
    docker-php-ext-install opcache; \
    rm -rf /tmp/pear; \
    php -m | grep -qx redis; \
    php -m | grep -qx exif; \
    php -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);'

COPY --from=builder /build /var/www/html

# Theme files are editable from the backend, so they are state, not code. Keep a
# pristine copy outside the mount and let the entrypoint seed the volume from it.
RUN set -eux; \
    mv /var/www/html/themes /opt/october-themes-dist; \
    ln -s /var/www/html/storage/themes /var/www/html/themes; \
    test -d /opt/october-themes-dist/demo

COPY docker/php/zz-october.ini /usr/local/etc/php/conf.d/zz-october.ini
COPY docker/php/zz-october-pool.conf /usr/local/etc/php-fpm.d/zz-october-pool.conf
COPY docker/nginx/00-railway.conf /etc/nginx/conf.d/00-railway.conf
COPY docker/entrypoint.sh /usr/local/bin/october-railway-entrypoint.sh
COPY docker/db-wait.php /opt/october/db-wait.php
COPY docker/seed-admin.php /opt/october/seed-admin.php

# REMOTE_ADDR and HTTPS are the only two CGI variables nginx does not derive from
# a request header, so rewriting them in fastcgi_params is what hands PHP the
# real client address and the edge's scheme. Everything HTTP_*-shaped would be
# overwritten by the incoming header anyway.
RUN set -eux; \
    chmod +x /usr/local/bin/october-railway-entrypoint.sh; \
    bash -n /usr/local/bin/october-railway-entrypoint.sh; \
    php -l /opt/october/db-wait.php; \
    php -l /opt/october/seed-admin.php; \
    sed -i 's|^fastcgi_param[[:blank:]]\{1,\}REMOTE_ADDR.*|fastcgi_param  REMOTE_ADDR        $railway_client_ip;|' /etc/nginx/fastcgi_params; \
    grep -q 'railway_client_ip' /etc/nginx/fastcgi_params; \
    printf 'fastcgi_param  HTTPS              $railway_https;\n' >> /etc/nginx/fastcgi_params; \
    nginx -t; \
    rm -f /var/run/nginx.pid

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/october-railway-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n"]

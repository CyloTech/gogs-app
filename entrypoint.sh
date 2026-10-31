#!/bin/bash
set -x

APP_USER="1000:1000"
CONFIG_FLAG="/etc/app_configured"
APP_INI="/home/git/gogs/custom/conf/app.ini"
GOGS_DIR="/home/git/gogs"
LOCAL_URL="http://localhost:3000"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

wait_for_http() {
    local url="$1"
    local attempts="${2:-60}"
    local sleep_seconds="${3:-2}"
    local i=0

    until curl -sf "${url}" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${attempts}" ]]; then
            echo "Timed out waiting for ${url}"
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        echo "Skipping Appbox callback (SKIP_APPBOX_CALLBACK=1)"
        return 0
    fi

    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(
        -H "Accept: application/json"
        -H "Content-Type:application/json"
    )

    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

# Resolve env vars that may not be set during local testing.
DOMAIN="${DOMAIN:-localhost}"
SSH_PORT="${SSH_PORT:-10022}"
ROOT_URL="${ROOT_URL:-http://localhost:3000/}"

# Ensure volume directories exist with correct ownership.
mkdir -p /home/git/gogs/custom/conf \
         /home/git/gogs/data \
         /home/git/repositories \
         /home/git/gogs/log
chown -R 1000:1000 /home/git/gogs/custom \
                   /home/git/gogs/data \
                   /home/git/repositories \
                   /home/git/gogs/log

# ---------------------------------------------------------------------------
# First-boot detection
# ---------------------------------------------------------------------------

cd "${GOGS_DIR}"

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CONFIG_FLAG}"

    if [[ ! -f "${APP_INI}" ]]; then
        # ==================================================================
        # FRESH INSTALL
        # ==================================================================
        echo "Fresh install detected, bootstrapping Gogs..."

        SECRET_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)

        cat > "${APP_INI}" <<EOF
RUN_USER = git
RUN_MODE = prod
BRAND_NAME = Gogs

[server]
HTTP_PORT         = 3000
START_SSH_SERVER  = true
SSH_PORT          = ${SSH_PORT}
SSH_LISTEN_PORT   = 10022
DOMAIN            = ${DOMAIN}
EXTERNAL_URL      = ${ROOT_URL}
DISABLE_SSH       = false
OFFLINE_MODE      = false

[database]
TYPE     = sqlite3
HOST     = 127.0.0.1:3306
NAME     = gogs
USER     = gogs
PASSWORD =
SSL_MODE = disable
PATH     = data/gogs.db

[repository]
ROOT = /home/git/repositories

[email]
ENABLED = false

[auth]
REQUIRE_EMAIL_CONFIRMATION  = false
DISABLE_REGISTRATION        = true
ENABLE_REGISTRATION_CAPTCHA = true
REQUIRE_SIGNIN_VIEW         = false

[picture]
DISABLE_GRAVATAR        = false
ENABLE_FEDERATED_AVATAR = false

[session]
PROVIDER = file

[log]
MODE      = file
LEVEL     = Info
ROOT_PATH = /home/git/gogs/log

[security]
INSTALL_LOCK = true
SECRET_KEY   = ${SECRET_KEY}
EOF

        chown 1000:1000 "${APP_INI}"

        gosu "${APP_USER}" "$@" &
        APP_PID=$!

        wait_for_http "${LOCAL_URL}" 90 2 || true

        ADMIN_USER="${ADMIN_USER:-admin}"
        ADMIN_PASS="${ADMIN_PASS:-admin}"
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"

        if ! gosu "${APP_USER}" "${GOGS_DIR}/gogs" admin create-user \
                --name "${ADMIN_USER}" \
                --password "${ADMIN_PASS}" \
                --admin \
                --email "${ADMIN_EMAIL}"; then
            echo "WARNING: Admin user creation failed. Manual setup may be required."
        fi

        kill "${APP_PID}" 2>/dev/null || true
        wait "${APP_PID}" 2>/dev/null || true

    else
        # ==================================================================
        # UPGRADE — existing data, new container image
        # ==================================================================
        echo "Upgrade detected: existing config at ${APP_INI}"

        # -- Port changes ------------------------------------------------
        sed -i "s/^HTTP_PORT.*/HTTP_PORT         = 3000/" "${APP_INI}"

        if ! grep -q "^SSH_LISTEN_PORT" "${APP_INI}"; then
            sed -i "/^SSH_PORT/a SSH_LISTEN_PORT   = 10022" "${APP_INI}"
        fi
        sed -i "s/^SSH_PORT.*/SSH_PORT          = ${SSH_PORT}/" "${APP_INI}"

        # -- Config key renames (0.11.x → 0.14.x) -----------------------
        sed -i "s/^APP_NAME.*/BRAND_NAME = Gogs/" "${APP_INI}"
        sed -i "s/^DB_TYPE.*/TYPE     = sqlite3/" "${APP_INI}"
        sed -i "s/^PASSWD.*/PASSWORD =/" "${APP_INI}"

        # ROOT_URL was renamed to EXTERNAL_URL in 0.12.x.
        if grep -q "^ROOT_URL" "${APP_INI}"; then
            sed -i "s|^ROOT_URL.*|EXTERNAL_URL      = ${ROOT_URL}|" "${APP_INI}"
        else
            sed -i "s|^EXTERNAL_URL.*|EXTERNAL_URL      = ${ROOT_URL}|" "${APP_INI}"
        fi
        sed -i "s/^DOMAIN.*/DOMAIN            = ${DOMAIN}/" "${APP_INI}"

        # Section renames.
        sed -i "s/^\[mailer\]/[email]/" "${APP_INI}"
        sed -i "s/^\[service\]/[auth]/" "${APP_INI}"

        # Key renames within [auth] (was [service]).
        sed -i "s/^REGISTER_EMAIL_CONFIRM.*/REQUIRE_EMAIL_CONFIRMATION  = false/" "${APP_INI}"
        sed -i "s/^ENABLE_CAPTCHA.*/ENABLE_REGISTRATION_CAPTCHA = true/" "${APP_INI}"

        # -- Enforce secure defaults -------------------------------------
        sed -i "s/^DISABLE_REGISTRATION.*/DISABLE_REGISTRATION        = true/" "${APP_INI}"

        # -- Remove deprecated keys --------------------------------------
        sed -i "/^ENABLE_NOTIFY_MAIL/d" "${APP_INI}"
        sed -i "/^ENABLE_EMAIL_NOTIFICATION/d" "${APP_INI}"
    fi

    callback_installed
fi

# ---------------------------------------------------------------------------
# Start Gogs as PID 1, UID 1000
# ---------------------------------------------------------------------------
exec gosu "${APP_USER}" "$@"

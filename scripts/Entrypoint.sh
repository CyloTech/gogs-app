#!/bin/bash
set -x

if [ ! -f /etc/gogs_installed ]; then
    SECRET_KEY=`pwgen 16 1`

    cd /home/git/gogs

    mkdir -p /home/git/gogs/custom/conf

cat <<EOT >> /home/git/gogs/custom/conf/app.ini
RUN_USER = git
RUN_MODE = prod
APP_NAME = Gogs

[server]
HTTP_PORT        = ${HTTP_PORT}
START_SSH_SERVER = true
SSH_PORT         = ${SSH_PORT}
DOMAIN           = ${DOMAIN}
ROOT_URL         = ${ROOT_URL}
DISABLE_SSH      = false
OFFLINE_MODE     = false

[database]
DB_TYPE  = mysql
HOST     = 127.0.0.1:3306
NAME     = gogs
USER     = gogs
PASSWD   = gogs
SSL_MODE = disable
PATH     = data/gogs.db

[repository]
ROOT = /home/git/repositories

[mailer]
ENABLED = false

[service]
REGISTER_EMAIL_CONFIRM = false
ENABLE_NOTIFY_MAIL     = false
DISABLE_REGISTRATION   = false
ENABLE_CAPTCHA         = true
REQUIRE_SIGNIN_VIEW    = false

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
EOT

    chown -R git:git /home/git

    /bin/sh /scripts/mysql.sh

    mkdir -p /var/log/gogs/

cat << EOF >> /etc/supervisor/conf.d/gogs.conf
[program:gogs]
directory=/home/git/gogs/
command=/home/git/gogs/gogs web
autostart=true
autorestart=true
startsecs=10
stdout_logfile=/var/log/gogs/stdout.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=10
stdout_capture_maxbytes=1MB
stderr_logfile=/var/log/gogs/stderr.log
stderr_logfile_maxbytes=1MB
stderr_logfile_backups=10
stderr_capture_maxbytes=1MB
user = git
environment = HOME="/home/git", USER="git"
EOF

    # Allow git user to use port 80.
    setcap cap_net_bind_service=+ep /home/git/gogs/gogs

    cd /home/git/gogs
    exec su -c "./gogs admin create-user --name ${ADMIN_USER} --password ${ADMIN_PASS} --admin --email ${ADMIN_EMAIL}" -s /bin/sh git &
    sleep 5
    pkill -9 gogs
    pkill -9 mysql
    sleep 5

    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/gogs_installed
fi
# Start supervisord and services
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
#!/bin/bash

DB_NAME=${DB_NAME:-gogs}
DB_USER=${DB_USER:-gogs}
DB_PASS=${DB_PASS:-gogs}

service mysql start
service mysql stop

mkdir -p /var/run/mysqld
touch /var/run/mysqld/mysqld.sock
chown -R mysql:mysql /var/lib/mysql

/usr/bin/mysqld_safe &
sleep 10

echo "Setting up root password."
mysqladmin -u root password ${MYSQL_ROOT_PASSWORD}


echo "Setting up new DB and user credentials."
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE $DB_NAME"
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;"
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;"
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "select user, host FROM mysql.user;"

echo "Installing Gogs Database"
mysql -u${DB_USER} -p${DB_PASS} ${DB_NAME} < /sources/gogs.sql

cat << EOF >> /etc/supervisor/conf.d/mysql.conf
[program:mysql]
command=/usr/sbin/mysqld --user=git --verbose=0 --socket=/run/mysqld/mysqld.sock
autostart=true
autorestart=true
priority=10
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF



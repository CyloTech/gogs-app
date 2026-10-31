#!/bin/bash
# moduser.sh — Change the admin user's password in Gogs.
#
# Gogs 0.13 stores passwords as PBKDF2-SHA256 (10 000 iterations, 50-byte
# output, hex-encoded) with a 10-character alphanumeric salt. This script
# hashes the new password and writes it directly to the SQLite database.
#
# Usage: /moduser.sh <new_password>

NEW_PASSWORD="$1"

if [[ -z "${NEW_PASSWORD}" ]]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

GOGS_DB="/home/git/gogs/data/gogs.db"

if [[ ! -f "${GOGS_DB}" ]]; then
    echo "Error: database not found at ${GOGS_DB}"
    exit 1
fi

python3 -c "
import hashlib, os, sqlite3, sys, string

password  = sys.argv[1]
db_path   = sys.argv[2]

chars = string.ascii_letters + string.digits
salt  = ''.join(chars[b % len(chars)] for b in os.urandom(10))

dk     = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 10000, dklen=50)
passwd = dk.hex()

rands = ''.join(chars[b % len(chars)] for b in os.urandom(10))

conn   = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute(
    'UPDATE user SET passwd=?, salt=?, rands=? '
    'WHERE is_admin=1 AND id=(SELECT id FROM user WHERE is_admin=1 ORDER BY id LIMIT 1)',
    (passwd, salt, rands),
)
if cursor.rowcount == 0:
    print('Error: no admin user found in database', file=sys.stderr)
    sys.exit(1)
conn.commit()
conn.close()
print('Password updated successfully')
" "${NEW_PASSWORD}" "${GOGS_DB}"

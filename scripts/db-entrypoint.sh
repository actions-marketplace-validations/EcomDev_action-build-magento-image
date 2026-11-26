#!/bin/sh
set -eu

# Minimal runtime entrypoint for scratch MariaDB/MySQL testcontainers.
# Set MYSQL_ENABLE_BINLOG=1 to enable binary logging in ROW/FULL format.

SERVER_BIN="$1"
shift

if [ "${MYSQL_ENABLE_BINLOG:-0}" = "1" ]; then
  set -- \
    --log-bin=mysql-bin \
    --server-id="${MYSQL_SERVER_ID:-1}" \
    --binlog-format=ROW \
    --binlog-row-image=FULL \
    "$@"
fi

exec "${SERVER_BIN}" "$@"

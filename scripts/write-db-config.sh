#!/usr/bin/env bash
set -euo pipefail

# Writes the ephemeral testcontainer server configuration to /etc/mysql/conf.d/zz-testcontainer.cnf.
# Used by both the target-arch rootfs builder and the native $BUILDPLATFORM init stage.

ENGINE="${1:-}"
CONF_FILE="/etc/mysql/conf.d/zz-testcontainer.cnf"

mkdir -p /etc/mysql/conf.d

cat <<'EOF' > "${CONF_FILE}"
[mysqld]
skip-name-resolve
max_allowed_packet=1024M
innodb_doublewrite=0
innodb_flush_log_at_trx_commit=2
EOF

case "${ENGINE}" in
  mariadb)
    cat <<'EOF' >> "${CONF_FILE}"
innodb_log_file_size=8M
aria_log_file_size=8M
EOF
    ;;
  mysql)
    cat <<'EOF' >> "${CONF_FILE}"
basedir=/usr
skip-log-bin
loose-innodb-redo-log-capacity=8M
EOF
    ;;
  *)
    echo "Usage: $0 <mariadb|mysql>" >&2
    exit 1
    ;;
esac

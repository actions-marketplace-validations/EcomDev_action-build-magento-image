#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Initializes a MariaDB or MySQL data directory at /setup/db and imports /docker-entrypoint-initdb.d/*.sql*.
# Runs natively on $BUILDPLATFORM without relying on or patching upstream docker-entrypoint.sh.
# Usage: init-db.sh <mariadb|mysql> [database] [user] [password] [root-password] [startup-timeout]

ENGINE="${1:-}"
DB_NAME="${2:-magento}"
DB_USER="${3:-magento}"
DB_PASSWORD="${4:-magento}"
ROOT_PASSWORD="${5:-magento}"
STARTUP_TIMEOUT="${6:-120}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DATA_DIR="/setup/db"
INITDB_DIR="/docker-entrypoint-initdb.d"
SOCKET="/run/mysqld/mysqld.sock"
SERVER_PID=""

case "${ENGINE}" in
  mariadb)
    CLIENT_BIN="mariadb"
    ADMIN_BIN="mariadb-admin"
    SERVER_BIN="/usr/sbin/mariadbd"
    ;;
  mysql)
    CLIENT_BIN="mysql"
    ADMIN_BIN="mysqladmin"
    # On Ubuntu hosts (e.g. GitHub Actions), BuildKit's unconfined docker-container
    # driver attaches the host's /etc/apparmor.d/usr.sbin.mysqld profile whenever
    # /usr/sbin/mysqld is executed by path, blocking /setup/db and /usr/share/mysql-8.x.
    # Running from /usr/local/sbin/mysqld (with basedir=/usr in zz-testcontainer.cnf)
    # avoids path-based AppArmor attachment during build-time initialization.
    SERVER_BIN="/usr/local/sbin/mysqld"
    ;;
  *)
    echo "Usage: $0 <mariadb|mysql> [database] [user] [password] [root-password] [startup-timeout]" >&2
    exit 1
    ;;
esac

cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g; s/\\\\/\\\\\\\\/g"
}

run_sql() {
  local password="$1"
  shift
  local extra_args=()
  if [[ "${ENGINE}" == "mariadb" ]]; then
    extra_args+=(--skip-ssl)
  fi
  MYSQL_PWD="${password}" "${CLIENT_BIN}" \
    --protocol=socket \
    --socket="${SOCKET}" \
    -uroot \
    --comments \
    "${extra_args[@]}" \
    "$@"
}

prepare_dirs() {
  "${SCRIPT_DIR}/write-db-config.sh" "${ENGINE}"
  install -m 0750 -o mysql -g mysql -d "${SETUP_DATA_DIR}"
  install -m 0755 -o mysql -g mysql -d /run/mysqld

  if [[ "${ENGINE}" == "mysql" ]]; then
    cp -a /usr/sbin/mysqld "${SERVER_BIN}"
  fi
}

initialize_datadir() {
  echo "[init-db] Initializing ${ENGINE} data directory at ${SETUP_DATA_DIR}"
  case "${ENGINE}" in
    mariadb)
      mariadb-install-db \
        --user=mysql \
        --datadir="${SETUP_DATA_DIR}" \
        --rpm \
        --auth-root-authentication-method=normal \
        --cross-bootstrap \
        --skip-test-db \
        --old-mode='UTF8_IS_UTF8MB3' \
        --default-time-zone=SYSTEM \
        --enforce-storage-engine= \
        --skip-log-bin \
        --expire-logs-days=0 \
        --loose-innodb_buffer_pool_load_at_startup=0 \
        --loose-innodb_buffer_pool_dump_at_shutdown=0
      ;;
    mysql)
      "${SERVER_BIN}" \
        --user=mysql \
        --datadir="${SETUP_DATA_DIR}" \
        --initialize-insecure \
        --default-time-zone=SYSTEM
      ;;
  esac
}

start_temp_server() {
  echo "[init-db] Starting temporary ${ENGINE} server"
  case "${ENGINE}" in
    mariadb)
      "${SERVER_BIN}" \
        --user=mysql \
        --datadir="${SETUP_DATA_DIR}" \
        --innodb-fast-shutdown=0 \
        --skip-networking \
        --default-time-zone=SYSTEM \
        --socket="${SOCKET}" \
        --wsrep_on=OFF \
        --skip-log-bin \
        --expire-logs-days=0 \
        --skip-slave-start \
        --loose-innodb_buffer_pool_load_at_startup=0 \
        --skip-ssl &
      SERVER_PID=$!

      local attempt
      for attempt in $(seq 1 "${STARTUP_TIMEOUT}"); do
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
          echo "[init-db] Temporary MariaDB server exited prematurely" >&2
          wait "${SERVER_PID}" || true
          exit 1
        fi
        if run_sql "" --database=mysql -e "SELECT 1" >/dev/null 2>&1; then
          echo "[init-db] Temporary MariaDB server ready"
          return 0
        fi
        sleep 1
      done

      echo "[init-db] Timed out waiting for MariaDB server after ${STARTUP_TIMEOUT}s" >&2
      exit 1
      ;;
    mysql)
      "${SERVER_BIN}" \
        --user=mysql \
        --datadir="${SETUP_DATA_DIR}" \
        --innodb-fast-shutdown=0 \
        --daemonize \
        --skip-networking \
        --default-time-zone=SYSTEM \
        --socket="${SOCKET}"
      echo "[init-db] Temporary MySQL server ready"
      ;;
  esac
}

configure_users_and_database() {
  local root_pw_esc user_pw_esc db_esc
  root_pw_esc="$(sql_escape "${ROOT_PASSWORD}")"
  user_pw_esc="$(sql_escape "${DB_PASSWORD}")"
  db_esc="${DB_NAME//_/\\_}"

  echo "[init-db] Configuring root, user '${DB_USER}', and database '${DB_NAME}'"
  run_sql "" --database=mysql <<EOSQL
SET autocommit = 1;
SET @@SESSION.SQL_LOG_BIN = 0;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pw_esc}';
GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
CREATE USER 'root'@'%' IDENTIFIED BY '${root_pw_esc}';
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${user_pw_esc}';
GRANT ALL ON \`${db_esc}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
EOSQL
}

import_sql_files() {
  local file
  for file in "${INITDB_DIR}"/*; do
    case "${file}" in
      *.sql)
        echo "[init-db] Importing ${file}"
        run_sql "${ROOT_PASSWORD}" --database="${DB_NAME}" < "${file}"
        ;;
      *.sql.gz)
        echo "[init-db] Importing ${file}"
        gunzip -c "${file}" | run_sql "${ROOT_PASSWORD}" --database="${DB_NAME}"
        ;;
      *.sql.bz2)
        echo "[init-db] Importing ${file}"
        bunzip2 -c "${file}" | run_sql "${ROOT_PASSWORD}" --database="${DB_NAME}"
        ;;
      *.sql.xz)
        echo "[init-db] Importing ${file}"
        xzcat "${file}" | run_sql "${ROOT_PASSWORD}" --database="${DB_NAME}"
        ;;
      *.sql.zst)
        echo "[init-db] Importing ${file}"
        zstd -dc "${file}" | run_sql "${ROOT_PASSWORD}" --database="${DB_NAME}"
        ;;
    esac
  done
}

stop_temp_server() {
  echo "[init-db] Shutting down temporary ${ENGINE} server cleanly (innodb_fast_shutdown=0)"
  local extra_args=()
  if [[ "${ENGINE}" == "mariadb" ]]; then
    extra_args+=(--skip-ssl)
  fi

  MYSQL_PWD="${ROOT_PASSWORD}" "${ADMIN_BIN}" \
    --protocol=socket \
    --socket="${SOCKET}" \
    -uroot \
    "${extra_args[@]}" \
    shutdown

  if [[ -n "${SERVER_PID}" ]]; then
    wait "${SERVER_PID}"
    SERVER_PID=""
  fi
}

prepare_dirs
initialize_datadir
start_temp_server
configure_users_and_database
import_sql_files
stop_temp_server
echo "[init-db] Initialization complete"

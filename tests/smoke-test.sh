#!/usr/bin/env bash
set -euo pipefail

# Smoke tests built MariaDB, MySQL, and OpenSearch testcontainer images.
# Usage: ./tests/smoke-test.sh <image-prefix> [image-tag] [network-name]

IMAGE_PREFIX="${1:-}"
IMAGE_TAG="${2:-smoke-test}"
NET_NAME="${3:-smoke-test-net-$$}"

MARIADB_CLIENT_IMAGE="${MARIADB_CLIENT_IMAGE:-ghcr.io/wardenenv/mariadb:11.8}"
MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-ghcr.io/wardenenv/mysql:8.4}"

if [[ -z "${IMAGE_PREFIX}" ]]; then
  echo "Usage: $0 <image-prefix> [image-tag] [network-name]" >&2
  exit 1
fi

IMAGE_PREFIX="$(printf '%s' "${IMAGE_PREFIX}" | tr '[:upper:]' '[:lower:]')"

CONTAINERS=()
NET_CREATED=0

cleanup() {
  if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
    docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
  fi
  if [[ "${NET_CREATED}" -eq 1 ]]; then
    docker network rm "${NET_NAME}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log_section() {
  printf '\n=== %s ===\n' "$1"
}

pass() {
  printf '  [PASS] %s\n' "$1"
}

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local description="$1" actual="$2" expected="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${description}: expected '${expected}', got '${actual}'"
  fi
  pass "${description} (${actual})"
}

assert_match() {
  local description="$1" actual="$2" pattern="$3"
  if ! grep -Eq "${pattern}" <<< "${actual}"; then
    fail "${description}: output '${actual}' did not match /${pattern}/"
  fi
  pass "${description}"
}

start_container() {
  local -n _cid_ref="$1"
  shift
  _cid_ref="$(docker run -d "$@")"
  CONTAINERS+=("${_cid_ref}")
}

wait_for_db_ready() {
  local label="$1" cid="$2"
  local attempt
  for attempt in $(seq 1 30); do
    if docker logs "${cid}" 2>&1 1>/dev/null | grep -q "ready for connections"; then
      pass "${label}: reported 'ready for connections' on stderr"
      return 0
    fi
    sleep 1
  done

  docker logs "${cid}" >&2 || true
  fail "${label}: did not report 'ready for connections' on stderr within 30s"
}

assert_db_container_metadata() {
  local label="$1" cid="$2"
  local mounts env_output

  mounts="$(docker inspect --format '{{json .Mounts}}' "${cid}")"
  assert_eq "${label}: no anonymous volumes" "${mounts}" "[]"

  env_output="$(docker exec "${cid}" env)"
  assert_match "${label}: docker exec env exposes MYSQL_DATABASE=magento" "${env_output}" '^MYSQL_DATABASE=magento$'
}

db_query() {
  local client_cid="$1" cli="$2" host="$3" user="$4" sql="$5" database="${6:-}"
  local args=("${cli}" "-h${host}" "-u${user}" "-Nse" "${sql}")

  if [[ "${cli}" == "mariadb" ]]; then
    args=("${cli}" "-h${host}" "-u${user}" "--skip-ssl" "-Nse" "${sql}")
  fi
  if [[ -n "${database}" ]]; then
    args+=("${database}")
  fi

  docker exec -e MYSQL_PWD=magento "${client_cid}" "${args[@]}"
}

test_database_default() {
  local label="$1" client_cid="$2" cli="$3" host="$4"
  local store_count log_bin

  store_count="$(db_query "${client_cid}" "${cli}" "${host}" magento "SELECT COUNT(*) FROM store" magento)"
  assert_match "${label}: pre-initialized store table has rows (${store_count})" "${store_count}" '^[1-9][0-9]*$'

  log_bin="$(db_query "${client_cid}" "${cli}" "${host}" root "SELECT @@log_bin+0")"
  assert_eq "${label}: binary logging disabled by default" "${log_bin}" "0"

  db_query "${client_cid}" "${cli}" "${host}" magento \
    "CREATE TABLE _smoke (id INT PRIMARY KEY); INSERT INTO _smoke VALUES (1); DROP TABLE _smoke;" \
    magento >/dev/null
  pass "${label}: database accepts DDL/DML writes"
}

test_database_binlog() {
  local label="$1" client_cid="$2" cli="$3" host="$4" expected_server_id="${5:-1}"
  local binlog_config binlogs

  binlog_config="$(db_query "${client_cid}" "${cli}" "${host}" root \
    "SELECT CONCAT(@@log_bin+0, ':', @@binlog_format, ':', @@binlog_row_image, ':', @@server_id)")"
  assert_eq "${label}: binlog enabled in ROW/FULL format" "${binlog_config}" "1:ROW:FULL:${expected_server_id}"

  binlogs="$(db_query "${client_cid}" "${cli}" "${host}" root "SHOW BINARY LOGS")"
  assert_match "${label}: binary log file mysql-bin.000001 created" "${binlogs}" '^mysql-bin\.000001'
}

wait_for_opensearch_ready() {
  local cid="$1" port="$2"
  local attempt
  for attempt in $(seq 1 30); do
    if docker logs "${cid}" 2>/dev/null | grep -q "Cluster health status changed from \[RED\]" \
      && curl -fsS "http://127.0.0.1:${port}/_cat/indices/magento2*" >/dev/null 2>&1; then
      pass "OpenSearch: reported cluster health transition and accepted HTTP queries"
      return 0
    fi
    sleep 2
  done

  docker logs "${cid}" >&2 || true
  fail "OpenSearch: did not become ready within 60s"
}

assert_opensearch_container_metadata() {
  local cid="$1"
  local mounts env_output

  mounts="$(docker inspect --format '{{json .Mounts}}' "${cid}")"
  assert_eq "OpenSearch: no anonymous volumes" "${mounts}" "[]"

  env_output="$(docker exec "${cid}" env)"
  assert_match "OpenSearch: docker exec env exposes OPENSEARCH_HOME=/usr/share/opensearch" "${env_output}" '^OPENSEARCH_HOME=/usr/share/opensearch$'
}

test_opensearch() {
  local cid="$1"
  local port indices plugins analyze_out script_out

  log_section "OpenSearch"
  port="$(docker port "${cid}" 9200/tcp | head -n 1 | awk -F: '{print $NF}')"
  if [[ -z "${port}" ]]; then
    fail "OpenSearch: failed to resolve published host port for 9200/tcp"
  fi

  wait_for_opensearch_ready "${cid}" "${port}"
  assert_opensearch_container_metadata "${cid}"

  indices="$(curl -fsS "http://127.0.0.1:${port}/_cat/indices/magento2*")"
  assert_match "OpenSearch: magento2 indices present" "${indices}" 'magento2'
  printf '%s\n' "${indices}"

  plugins="$(curl -fsS "http://127.0.0.1:${port}/_cat/plugins")"
  assert_match "OpenSearch: analysis-icu plugin loaded" "${plugins}" 'analysis-icu'
  assert_match "OpenSearch: analysis-phonetic plugin loaded" "${plugins}" 'analysis-phonetic'

  analyze_out="$(curl -fsS -X POST "http://127.0.0.1:${port}/_analyze" \
    -H 'Content-Type: application/json' \
    -d '{"tokenizer":"icu_tokenizer","filter":["icu_folding","phonetic"],"text":"Café Shirt"}')"
  assert_match "OpenSearch: ICU and phonetic analyzers execute" "${analyze_out}" '"tokens":\['

  curl -fsS -X PUT "http://127.0.0.1:${port}/smoke_test/_doc/1?refresh=true" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Test Product","price":42}' >/dev/null
  script_out="$(curl -fsS -X POST "http://127.0.0.1:${port}/smoke_test/_search" \
    -H 'Content-Type: application/json' \
    -d '{"script_fields":{"doubled":{"script":{"lang":"painless","source":"doc[\u0027price\u0027].value * 2"}}}}')"
  assert_match "OpenSearch: Painless scripting and index writes succeed" "${script_out}" '"doubled":\[84\]'
  curl -fsS -X DELETE "http://127.0.0.1:${port}/smoke_test" >/dev/null
  pass "OpenSearch: temporary smoke_test index deleted"
}

main() {
  local mariadb_image="${IMAGE_PREFIX}/mariadb:${IMAGE_TAG}"
  local mysql_image="${IMAGE_PREFIX}/mysql:${IMAGE_TAG}"
  local opensearch_image="${IMAGE_PREFIX}/opensearch:${IMAGE_TAG}"

  docker network create "${NET_NAME}" >/dev/null
  NET_CREATED=1

  # Start all containers concurrently so initialization runs in parallel
  local mariadb_cid mysql_cid mariadb_binlog_cid mysql_binlog_cid opensearch_cid
  local mariadb_client_cid mysql_client_cid

  start_container mariadb_cid --network "${NET_NAME}" --network-alias mariadb-smoke "${mariadb_image}"
  start_container mysql_cid --network "${NET_NAME}" --network-alias mysql-smoke "${mysql_image}"
  start_container mariadb_binlog_cid --network "${NET_NAME}" --network-alias mariadb-binlog -e MYSQL_ENABLE_BINLOG=1 "${mariadb_image}"
  start_container mysql_binlog_cid --network "${NET_NAME}" --network-alias mysql-binlog -e MYSQL_ENABLE_BINLOG=1 "${mysql_image}"
  start_container opensearch_cid -p 127.0.0.1::9200 -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true "${opensearch_image}"

  start_container mariadb_client_cid --network "${NET_NAME}" --entrypoint sleep "${MARIADB_CLIENT_IMAGE}" infinity
  start_container mysql_client_cid --network "${NET_NAME}" --entrypoint sleep "${MYSQL_CLIENT_IMAGE}" infinity

  log_section "MariaDB (default)"
  wait_for_db_ready "MariaDB" "${mariadb_cid}"
  assert_db_container_metadata "MariaDB" "${mariadb_cid}"
  test_database_default "MariaDB" "${mariadb_client_cid}" mariadb mariadb-smoke

  log_section "MariaDB (MYSQL_ENABLE_BINLOG=1)"
  wait_for_db_ready "MariaDB-binlog" "${mariadb_binlog_cid}"
  assert_db_container_metadata "MariaDB-binlog" "${mariadb_binlog_cid}"
  test_database_binlog "MariaDB-binlog" "${mariadb_client_cid}" mariadb mariadb-binlog 1

  log_section "MySQL (default)"
  wait_for_db_ready "MySQL" "${mysql_cid}"
  assert_db_container_metadata "MySQL" "${mysql_cid}"
  test_database_default "MySQL" "${mysql_client_cid}" mysql mysql-smoke

  log_section "MySQL (MYSQL_ENABLE_BINLOG=1)"
  wait_for_db_ready "MySQL-binlog" "${mysql_binlog_cid}"
  assert_db_container_metadata "MySQL-binlog" "${mysql_binlog_cid}"
  test_database_binlog "MySQL-binlog" "${mysql_client_cid}" mysql mysql-binlog 1

  test_opensearch "${opensearch_cid}"

  printf '\nAll smoke tests passed.\n'
}

main

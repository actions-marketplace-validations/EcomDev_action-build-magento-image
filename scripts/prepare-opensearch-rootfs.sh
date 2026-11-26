#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Prepares a minimal /rootfs in an OpenSearch target-arch stage for a `FROM scratch` testcontainer:
#   1. Builds a custom minimal JRE with jlink from the image's bundled JDK
#   2. Copies only OpenSearch core libs, core modules (dropping bloat like ingest-geoip and
#      opensearch-dashboards), and Magento-required plugins (analysis-icu, analysis-phonetic)
#   3. Strips unused plugin configs and Performance Analyzer JVM flags
#   4. Assembles a minimal OS rootfs with /bin/sh, /usr/bin/env, required shared libraries,
#      and minimal user/group/NSS files for uid 1000 (opensearch)

OPENSEARCH_HOME="${OPENSEARCH_HOME:-/usr/share/opensearch}"
JDK_DIR="${OPENSEARCH_HOME}/jdk"
ROOTFS_DIR="/rootfs"
DEST_OS="${ROOTFS_DIR}${OPENSEARCH_HOME}"
# zip-0 leaves lib/modules uncompressed so OCI zstd/gzip layer compression achieves a
# ~17 MB smaller pull size and avoids runtime deflate overhead on JVM classloading.
JLINK_COMPRESSION="${JLINK_COMPRESSION:-zip-0}"

# Magento 2 requires analysis-icu and analysis-phonetic; all other bundled plugins
# (ML, k-NN, SQL, Security, Performance Analyzer, Alerting, etc.) are unused in testcontainers.
KEEP_PLUGINS=(
  analysis-icu
  analysis-phonetic
)

# Drop known large/unused modules while keeping core modules (and any new core modules added
# in future OpenSearch 3.x releases).
DROP_MODULES=(
  ingest-geoip
  ingest-user-agent
  opensearch-dashboards
  repository-url
  systemd
)

# Java modules required by OpenSearch 2.x/3.x core, Lucene, Netty, Painless, Log4j, and agent.
# Filtered against $JDK_DIR/jmods so builds stay compatible across JDK 17/21/25+.
DESIRED_JMODS=(
  java.base
  java.compiler
  java.desktop
  java.instrument
  java.logging
  java.management
  java.management.rmi
  java.naming
  java.net.http
  java.prefs
  java.rmi
  java.scripting
  java.security.jgss
  java.security.sasl
  java.sql
  java.xml
  jdk.charsets
  jdk.crypto.ec
  jdk.incubator.vector
  jdk.localedata
  jdk.management
  jdk.management.agent
  jdk.naming.dns
  jdk.net
  jdk.nio.mapmode
  jdk.unsupported
  jdk.zipfs
)

copy_to_rootfs() {
  local src="$1"
  local dest
  dest="$(realpath -m -s "${src}")"

  if [[ -e "${ROOTFS_DIR}${dest}" ]]; then
    return 0
  fi

  mkdir -p "${ROOTFS_DIR}$(dirname "${dest}")"
  cp -L "${src}" "${ROOTFS_DIR}${dest}"
}

copy_binary_with_libs() {
  local bin="$1"
  copy_to_rootfs "${bin}"

  # On Amazon Linux 2023 / Oracle Linux (coreutils-single), /usr/bin/env is a shebang
  # wrapper pointing to /usr/bin/coreutils; copy the interpreter and its libs too.
  if [[ "$(head -c 2 "${bin}" | tr -d '\0')" == "#!" ]]; then
    local interp
    interp="$(head -n 1 "${bin}" | sed 's/^#![[:space:]]*//' | awk '{print $1}')"
    if [[ -x "${interp}" ]]; then
      copy_binary_with_libs "${interp}"
    fi
    return 0
  fi

  local libs lib
  libs="$(ldd "${bin}" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}' || true)"
  while IFS= read -r lib; do
    [[ -n "${lib}" && -e "${lib}" ]] || continue
    # Skip libraries inside the JRE tree itself; they are already in DEST_OS/jdk
    case "${lib}" in
      "${DEST_OS}/jdk/"*|"${JDK_DIR}/"*) continue ;;
    esac
    copy_to_rootfs "${lib}"
  done <<< "${libs}"
}

build_custom_jre() {
  local available_mods=()
  local mod
  for mod in "${DESIRED_JMODS[@]}"; do
    if [[ -f "${JDK_DIR}/jmods/${mod}.jmod" ]]; then
      available_mods+=("${mod}")
    fi
  done

  local mod_csv
  mod_csv="$(IFS=,; printf '%s' "${available_mods[*]}")"

  local compress_flag="--compress=${JLINK_COMPRESSION}"
  if ! "${JDK_DIR}/bin/jlink" --help 2>&1 | grep -q "zip-\[0-9\]"; then
    # JDK 17-20 fallback
    case "${JLINK_COMPRESSION}" in
      zip-0) compress_flag="--compress=0" ;;
      *) compress_flag="--compress=2" ;;
    esac
  fi

  mkdir -p "${DEST_OS}"
  "${JDK_DIR}/bin/jlink" \
    --module-path "${JDK_DIR}/jmods" \
    --add-modules "${mod_csv}" \
    --strip-java-debug-attributes \
    --no-man-pages \
    --no-header-files \
    "${compress_flag}" \
    --output "${DEST_OS}/jdk"
}

is_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

copy_opensearch_files() {
  mkdir -p "${DEST_OS}/config" "${DEST_OS}/logs" "${DEST_OS}/modules" "${DEST_OS}/plugins"

  cp -a "${OPENSEARCH_HOME}/lib" "${DEST_OS}/lib"

  # OpenSearch 3.0+ uses agent/opensearch-agent.jar via -javaagent in jvm.options
  if [[ -d "${OPENSEARCH_HOME}/agent" ]]; then
    cp -a "${OPENSEARCH_HOME}/agent" "${DEST_OS}/agent"
  fi

  local dir name
  for dir in "${OPENSEARCH_HOME}/modules"/*; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    if is_in_list "${name}" "${DROP_MODULES[@]}"; then
      continue
    fi
    cp -a "${dir}" "${DEST_OS}/modules/${name}"
  done

  for name in "${KEEP_PLUGINS[@]}"; do
    if [[ -d "${OPENSEARCH_HOME}/plugins/${name}" ]]; then
      cp -a "${OPENSEARCH_HOME}/plugins/${name}" "${DEST_OS}/plugins/${name}"
    fi
  done

  # Copy only core configuration files (skip security/performance-analyzer/notifications/etc. dirs)
  local cfg
  for cfg in opensearch.yml jvm.options log4j2.properties java.security; do
    if [[ -f "${OPENSEARCH_HOME}/config/${cfg}" ]]; then
      cp -a "${OPENSEARCH_HOME}/config/${cfg}" "${DEST_OS}/config/${cfg}"
    fi
  done
  if [[ -d "${OPENSEARCH_HOME}/config/jvm.options.d" ]]; then
    cp -a "${OPENSEARCH_HOME}/config/jvm.options.d" "${DEST_OS}/config/jvm.options.d"
  fi

  # Remove Performance Analyzer JVM flags (plugin and jdk.attach module are not included)
  if [[ -f "${DEST_OS}/config/jvm.options" ]]; then
    grep -Ev '(opensearch-performance-analyzer|jdk\.attach|^-Dclk\.tck=|## OpenDistro Performance Analyzer)' \
      "${DEST_OS}/config/jvm.options" > "${DEST_OS}/config/jvm.options.tmp"
    mv "${DEST_OS}/config/jvm.options.tmp" "${DEST_OS}/config/jvm.options"
  fi

  local meta
  for meta in LICENSE.txt NOTICE.txt manifest.yml; do
    if [[ -f "${OPENSEARCH_HOME}/${meta}" ]]; then
      cp -a "${OPENSEARCH_HOME}/${meta}" "${DEST_OS}/${meta}"
    fi
  done

  chown -R 1000:1000 "${DEST_OS}"
}

assemble_os_rootfs() {
  mkdir -p "${ROOTFS_DIR}/etc" "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/run"
  chmod 1777 "${ROOTFS_DIR}/tmp"
  ln -s /run "${ROOTFS_DIR}/var/run" 2>/dev/null || { mkdir -p "${ROOTFS_DIR}/var" && ln -s /run "${ROOTFS_DIR}/var/run"; }

  # Copy /bin/sh (for runtime entrypoint) and /usr/bin/env (for env parsing & testcontainers)
  copy_binary_with_libs "/bin/sh"
  copy_binary_with_libs "/usr/bin/env"

  # Copy shared libraries required by the custom JRE binaries and JNI libraries
  local jre_bin
  for jre_bin in "${DEST_OS}/jdk/bin/java" "${DEST_OS}/jdk/lib"/*.so "${DEST_OS}/jdk/lib/server"/*.so; do
    [[ -e "${jre_bin}" ]] || continue
    local libs lib
    libs="$(ldd "${jre_bin}" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}' || true)"
    while IFS= read -r lib; do
      [[ -n "${lib}" && -e "${lib}" ]] || continue
      case "${lib}" in
        "${DEST_OS}/jdk/"*|"${JDK_DIR}/"*) continue ;;
      esac
      copy_to_rootfs "${lib}"
    done <<< "${libs}"
  done

  # Copy NSS file/DNS backends and libgcc_s (used by glibc user/DNS resolution and JVM unwinding)
  local syslib
  for syslib in \
    /lib*/libnss_files.so* /lib*/*/libnss_files.so* \
    /lib*/libnss_dns.so* /lib*/*/libnss_dns.so* \
    /lib*/libresolv.so* /lib*/*/libresolv.so* \
    /lib*/libgcc_s.so* /lib*/*/libgcc_s.so*; do
    copy_to_rootfs "${syslib}"
  done

  if [[ -f /etc/ld.so.cache ]]; then
    cp -a /etc/ld.so.cache "${ROOTFS_DIR}/etc/ld.so.cache"
  fi

  # Minimal identity and NSS configuration
  grep -E '^(root|opensearch):' /etc/passwd > "${ROOTFS_DIR}/etc/passwd"
  grep -E '^(root|opensearch):' /etc/group > "${ROOTFS_DIR}/etc/group"
  printf 'passwd: files\ngroup: files\nhosts: files dns\n' > "${ROOTFS_DIR}/etc/nsswitch.conf"

  # Copy CA certificates bundle if present
  if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
    copy_to_rootfs /etc/ssl/certs/ca-certificates.crt
  elif [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
    mkdir -p "${ROOTFS_DIR}/etc/ssl/certs"
    cp -L /etc/pki/tls/certs/ca-bundle.crt "${ROOTFS_DIR}/etc/ssl/certs/ca-certificates.crt"
  fi
}

build_custom_jre
copy_opensearch_files
assemble_os_rootfs

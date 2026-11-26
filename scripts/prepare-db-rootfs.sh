#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Prepares a minimal /rootfs in a MariaDB or MySQL target-arch stage for a `FROM scratch` testcontainer:
#   1. Writes an ephemeral testcontainer config (/etc/mysql/conf.d/zz-testcontainer.cnf)
#   2. Assembles a minimal /rootfs containing only the DB server binary, /bin/sh, /usr/bin/env,
#      required shared libraries, minimal user/group files, configs, and charsets/messages

ENGINE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_DIR="/rootfs"

case "${ENGINE}" in
  mariadb)
    SERVER_BIN="/usr/sbin/mariadbd"
    ;;
  mysql)
    SERVER_BIN="/usr/sbin/mysqld"
    ;;
  *)
    echo "Usage: $0 <mariadb|mysql>" >&2
    exit 1
    ;;
esac

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

  # On Oracle Linux 9 (coreutils-single), /usr/bin/env is a shebang wrapper
  # pointing to /usr/bin/coreutils; copy the interpreter and its libs too.
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
    copy_to_rootfs "${lib}"
  done <<< "${libs}"
}

assemble_rootfs() {
  mkdir -p "${ROOTFS_DIR}/etc" "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/run/mysqld" "${ROOTFS_DIR}/var/lib"
  chmod 1777 "${ROOTFS_DIR}/tmp"
  chown mysql:mysql "${ROOTFS_DIR}/run/mysqld"
  ln -s /run "${ROOTFS_DIR}/var/run"

  # MySQL defaults secure_file_priv to /var/lib/mysql-files
  if [[ -d /var/lib/mysql-files ]]; then
    mkdir -p "${ROOTFS_DIR}/var/lib/mysql-files"
    chown mysql:mysql "${ROOTFS_DIR}/var/lib/mysql-files"
    chmod 0750 "${ROOTFS_DIR}/var/lib/mysql-files"
  fi

  # Copy database server binary, /bin/sh (for runtime entrypoint), and /usr/bin/env (for testcontainers)
  copy_binary_with_libs "${SERVER_BIN}"
  copy_binary_with_libs "/bin/sh"
  copy_binary_with_libs "/usr/bin/env"

  # Copy NSS file backend so glibc can resolve the mysql user from /etc/passwd and /etc/group
  local nss
  for nss in /lib*/libnss_files.so* /lib*/*/libnss_files.so*; do
    copy_to_rootfs "${nss}"
  done

  if [[ -f /etc/ld.so.cache ]]; then
    cp -a /etc/ld.so.cache "${ROOTFS_DIR}/etc/ld.so.cache"
  fi

  # Minimal identity and NSS configuration
  grep -E '^(root|mysql):' /etc/passwd > "${ROOTFS_DIR}/etc/passwd"
  grep -E '^(root|mysql):' /etc/group > "${ROOTFS_DIR}/etc/group"
  printf 'passwd: files\ngroup: files\nhosts: files\n' > "${ROOTFS_DIR}/etc/nsswitch.conf"

  # Copy database server configuration files
  if [[ -d /etc/mysql ]]; then
    cp -a /etc/mysql "${ROOTFS_DIR}/etc/mysql"
  fi
  if [[ -e /etc/my.cnf ]]; then
    cp -a /etc/my.cnf "${ROOTFS_DIR}/etc/my.cnf"
  fi

  # Copy error messages (english) and character sets, skipping mysqlsh data
  local share_dir sub
  for share_dir in /usr/share/mariadb /usr/share/mysql*; do
    [[ -d "${share_dir}" ]] || continue
    case "${share_dir}" in
      *mysqlsh*) continue ;;
    esac
    for sub in english charsets; do
      [[ -d "${share_dir}/${sub}" ]] || continue
      mkdir -p "${ROOTFS_DIR}${share_dir}"
      cp -a "${share_dir}/${sub}" "${ROOTFS_DIR}${share_dir}/${sub}"
    done
  done
}

"${SCRIPT_DIR}/write-db-config.sh" "${ENGINE}"
assemble_rootfs

#!/bin/sh
set -eu

# Minimal POSIX runtime entrypoint for scratch OpenSearch testcontainers.
# Supports standard dot-separated OpenSearch environment settings (e.g. discovery.type=single-node),
# processors, OPENSEARCH_JAVA_OPTS, and ignores DISABLE_SECURITY_PLUGIN / plugins.security.*
# when opensearch-security is not installed.

export OPENSEARCH_HOME="${OPENSEARCH_HOME:-/usr/share/opensearch}"
export OPENSEARCH_PATH_CONF="${OPENSEARCH_PATH_CONF:-${OPENSEARCH_HOME}/config}"
export OPENSEARCH_TMPDIR="${OPENSEARCH_TMPDIR:-/tmp}"

JAVA="${OPENSEARCH_HOME}/jdk/bin/java"
OPENSEARCH_CLASSPATH="${OPENSEARCH_HOME}/lib/*"

if [ $# -eq 0 ]; then
  set -- opensearch
else
  case "$1" in
    -*) set -- opensearch "$@" ;;
  esac
fi

if [ "$1" != "opensearch" ]; then
  exec "$@"
fi
shift

umask 0002

# Match upstream Docker entrypoint cgroup hierarchy override
export OPENSEARCH_JAVA_OPTS="-Dopensearch.cgroups.hierarchy.override=/ ${OPENSEARCH_JAVA_OPTS:-}"

# Do not let JAVA_TOOL_OPTIONS slip into the JVM unexpectedly
if [ -n "${JAVA_TOOL_OPTIONS:-}" ]; then
  unset JAVA_TOOL_OPTIONS
fi

is_opensearch_setting() {
  k="$1"
  if [ "${k}" = "processors" ]; then
    return 0
  fi
  case "${k}" in
    ''|.*|*.|*..*|*[!a-z0-9_.]*) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

HAS_SECURITY_PLUGIN=0
if [ -d "${OPENSEARCH_HOME}/plugins/opensearch-security" ]; then
  HAS_SECURITY_PLUGIN=1
fi

ENV_DUMP="$(/usr/bin/env)"
while IFS= read -r line; do
  case "${line}" in
    *=*)
      key="${line%%=*}"
      val="${line#*=}"
      if [ -n "${val}" ] && is_opensearch_setting "${key}"; then
        if [ "${HAS_SECURITY_PLUGIN}" -eq 0 ]; then
          case "${key}" in
            plugins.security.*) continue ;;
          esac
        fi
        set -- "$@" "-E${key}=${val}"
      fi
      ;;
  esac
done <<EOF
${ENV_DUMP}
EOF

if [ "${HAS_SECURITY_PLUGIN}" -eq 1 ] && [ "${DISABLE_SECURITY_PLUGIN:-false}" = "true" ]; then
  set -- "$@" "-Eplugins.security.disabled=true"
fi

# Resolve final JVM flags from jvm.options, jvm.options.d/*, and OPENSEARCH_JAVA_OPTS
PARSED_JVM_OPTS="$("${JAVA}" -cp "${OPENSEARCH_CLASSPATH}" org.opensearch.tools.launchers.JvmOptionsParser "${OPENSEARCH_PATH_CONF}")"

cd "${OPENSEARCH_HOME}"

# shellcheck disable=SC2086
exec "${JAVA}" \
  -Xshare:auto \
  ${PARSED_JVM_OPTS} \
  -Dopensearch.path.home="${OPENSEARCH_HOME}" \
  -Dopensearch.path.conf="${OPENSEARCH_PATH_CONF}" \
  -Dopensearch.distribution.type=tar \
  -Dopensearch.bundled_jdk=true \
  -cp "${OPENSEARCH_CLASSPATH}" \
  org.opensearch.bootstrap.OpenSearch \
  "$@" </dev/null

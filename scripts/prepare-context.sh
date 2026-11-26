#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Populates the Docker build context directory from downloaded or local
# Magento data artifact archives based on container type.
#
# Usage:
#   prepare-context.sh <container_type> <source_dir> <context_dir>

CONTAINER_TYPE="${1:-}"
SOURCE_DIR="${2:-}"
CONTEXT_DIR="${3:-}"

write_output() {
  echo "$1=$2" >> "${GITHUB_OUTPUT}"
}

prepare_database_context() {
  local sql_files=("${SOURCE_DIR}"/*.sql "${SOURCE_DIR}"/*.sql.gz)
  if [[ ${#sql_files[@]} -eq 0 ]]; then
    echo "::error::No SQL dump (*.sql or *.sql.gz) found in '${SOURCE_DIR}'."
    exit 1
  fi
  cp "${sql_files[@]}" "${CONTEXT_DIR}/"
}

prepare_opensearch_context() {
  if [[ ! -f "${SOURCE_DIR}/search.tgz" ]]; then
    echo "::notice::Skipping OpenSearch image build because 'search.tgz' was not found in '${SOURCE_DIR}'."
    write_output "skip" "true"
    exit 0
  fi
  tar xzf "${SOURCE_DIR}/search.tgz" -C "${CONTEXT_DIR}"
}

prepare_media_context() {
  if [[ ! -f "${SOURCE_DIR}/media.tgz" ]]; then
    echo "::error::'media.tgz' not found in '${SOURCE_DIR}'."
    exit 1
  fi
  tar xzf "${SOURCE_DIR}/media.tgz" -C "${CONTEXT_DIR}"
}

main() {
  case "${CONTAINER_TYPE}" in
    mariadb|mysql)
      prepare_database_context
      ;;
    opensearch)
      prepare_opensearch_context
      ;;
    media)
      prepare_media_context
      ;;
    *)
      echo "::error::Unsupported containerType '${CONTAINER_TYPE}'."
      exit 1
      ;;
  esac

  write_output "skip" "false"
}

main

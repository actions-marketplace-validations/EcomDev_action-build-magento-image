#!/usr/bin/env bash
set -euo pipefail

# Validates composite action inputs and prepares the temporary workspace
# and BuildKit options for Docker image builds.
#
# Usage:
#   prepare-workspace.sh <container_type> <version> <artifact_name> <artifact_id> <artifact_path> [enable_cache] [load_image] [push_image] [compression] [compression_level]

CONTAINER_TYPE="${1:-}"
VERSION="${2:-}"
ARTIFACT_NAME="${3:-}"
ARTIFACT_ID="${4:-}"
ARTIFACT_PATH="${5:-}"
ENABLE_CACHE="${6:-false}"
LOAD_IMAGE="${7:-false}"
PUSH_IMAGE="${8:-false}"
COMPRESSION="${9:-zstd}"
COMPRESSION_LEVEL="${10:-9}"

WORK_DIR=""
SOURCE_DIR=""
CONTEXT_DIR=""
CACHE_FROM=""
CACHE_TO=""
PROVENANCE=""
OUTPUTS=""

write_output() {
  echo "$1=$2" >> "${GITHUB_OUTPUT}"
}

validate_container_type() {
  case "${CONTAINER_TYPE}" in
    mariadb|mysql|opensearch|media) ;;
    *)
      echo "::error::Unsupported containerType '${CONTAINER_TYPE}'. Expected one of: mariadb, mysql, opensearch, media."
      exit 1
      ;;
  esac
}

validate_compression() {
  case "${COMPRESSION}" in
    zstd|gzip|estargz|uncompressed) ;;
    *)
      echo "::error::Unsupported compression '${COMPRESSION}'. Expected one of: zstd, gzip, estargz, uncompressed."
      exit 1
      ;;
  esac

  if [[ "${COMPRESSION}" == "uncompressed" || -z "${COMPRESSION_LEVEL}" ]]; then
    return 0
  fi

  if [[ ! "${COMPRESSION_LEVEL}" =~ ^[0-9]+$ ]]; then
    echo "::error::Invalid compressionLevel '${COMPRESSION_LEVEL}'. Expected a non-negative integer."
    exit 1
  fi

  local max_level=9
  if [[ "${COMPRESSION}" == "zstd" ]]; then
    max_level=22
  fi

  if (( 10#${COMPRESSION_LEVEL} > max_level )); then
    echo "::error::Invalid compressionLevel '${COMPRESSION_LEVEL}' for '${COMPRESSION}'. Expected 0-${max_level}."
    exit 1
  fi
}

should_skip_optional_build() {
  [[ "${CONTAINER_TYPE}" == "opensearch" && ( -z "${VERSION}" || "${VERSION}" == "none" ) ]]
}

validate_required_inputs() {
  if [[ "${CONTAINER_TYPE}" != "media" && ( -z "${VERSION}" || "${VERSION}" == "none" ) ]]; then
    echo "::error::Input 'version' is required when containerType is '${CONTAINER_TYPE}'."
    exit 1
  fi

  if [[ -z "${ARTIFACT_PATH}" && -z "${ARTIFACT_ID}" && -z "${ARTIFACT_NAME}" ]]; then
    echo "::error::One of 'artifact', 'artifactId', or 'artifactPath' must be specified."
    exit 1
  fi
}

prepare_directories() {
  WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/magento-image-XXXXXX")"
  CONTEXT_DIR="${WORK_DIR}/context"
  mkdir -p "${CONTEXT_DIR}"

  if [[ -n "${ARTIFACT_PATH}" ]]; then
    if [[ ! -d "${ARTIFACT_PATH}" ]]; then
      echo "::error::Specified artifactPath '${ARTIFACT_PATH}' does not exist or is not a directory."
      rm -rf "${WORK_DIR}"
      exit 1
    fi
    SOURCE_DIR="$(cd "${ARTIFACT_PATH}" && pwd)"
  else
    SOURCE_DIR="${WORK_DIR}/download"
    mkdir -p "${SOURCE_DIR}"
  fi
}

configure_build_options() {
  if [[ "${ENABLE_CACHE}" != "false" ]]; then
    CACHE_FROM="type=gha"
    CACHE_TO="type=gha,mode=max"
  else
    CACHE_FROM=""
    CACHE_TO=""
  fi

  if [[ "${LOAD_IMAGE}" != "false" ]]; then
    PROVENANCE="false"
  else
    PROVENANCE="mode=max"
  fi

  if [[ "${PUSH_IMAGE}" != "false" ]]; then
    OUTPUTS="type=registry,compression=${COMPRESSION},force-compression=true"
    if [[ "${COMPRESSION}" != "uncompressed" && -n "${COMPRESSION_LEVEL}" ]]; then
      OUTPUTS="${OUTPUTS},compression-level=${COMPRESSION_LEVEL}"
    fi
    if [[ "${COMPRESSION}" == "zstd" || "${COMPRESSION}" == "estargz" ]]; then
      OUTPUTS="${OUTPUTS},oci-mediatypes=true"
    fi
  else
    OUTPUTS=""
  fi
}

main() {
  validate_container_type
  validate_compression

  if should_skip_optional_build; then
    echo "::notice::Skipping OpenSearch image build because 'version' is not specified."
    write_output "skip" "true"
    write_output "work_dir" ""
    exit 0
  fi

  validate_required_inputs
  prepare_directories
  configure_build_options

  write_output "skip" "false"
  write_output "work_dir" "${WORK_DIR}"
  write_output "source_dir" "${SOURCE_DIR}"
  write_output "context_dir" "${CONTEXT_DIR}"
  write_output "cache_from" "${CACHE_FROM}"
  write_output "cache_to" "${CACHE_TO}"
  write_output "provenance" "${PROVENANCE}"
  write_output "outputs" "${OUTPUTS}"
}

main

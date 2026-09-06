#!/bin/bash
# =============================================================================
# scripts/apptainer_bake.sh — bake a development snapshot or a production
# runtime into an Apptainer SIF artifact.
# Usage: apptainer_bake.sh [--mode dev|prod] [--env ros|dev] [--share]
# =============================================================================
set -euo pipefail

# WS_ROOT comes from util_paths.sh, which ignores a WORKSPACE_PATH that is not a
# DevKit tree on THIS machine — the Makefile exports the container path.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
devkit_require "util_sif_common.sh"
LOG_PREFIX="[Bake]"

MODE="dev"
ENV_NAME="${ENV:-ros}"
SHARE_MODE="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) [ $# -ge 2 ] || { log_error "--mode needs a value (dev|prod)"; exit 2; }
                MODE="$2"; shift 2 ;;
        --env)  [ $# -ge 2 ] || { log_error "--env needs a value (ros|dev)"; exit 2; }
                ENV_NAME="$2"; shift 2 ;;
        --share) SHARE_MODE="true"; shift ;;
        -h|--help)
            echo "Usage: apptainer_bake.sh [--mode dev|prod] [--env ros|dev] [--share]"
            exit 0 ;;
        *) log_error "Unknown option: $1"; exit 2 ;;
    esac
done

sif_require_choice --mode "$MODE" dev prod || exit 2
sif_require_choice --env "$ENV_NAME" ros dev || exit 2
if [ "$SHARE_MODE" = "true" ] && [ "$MODE" = "prod" ]; then
    log_error "--share is a dev-snapshot option; prod builds always install a self-contained venv."
    exit 2
fi

BAKE_FORMAT="${BAKE_FORMAT:-sif}"
sif_require_choice BAKE_FORMAT "$BAKE_FORMAT" sif oci || exit 2
RUNTIME=""
if [ "$BAKE_FORMAT" = sif ]; then
    RUNTIME="$(sif_runtime)" || { log_detail 'On macOS use BAKE_FORMAT=oci, then convert the archive on Linux.' >&2; exit 1; }
fi
# Direct script calls need the same .env/default pairing and host IDs as make.
detected_env="$(bash "${WS_ROOT}/scripts/check_env.sh")" || exit 1
eval "$detected_env"
TARGETARCH="$(sif_arch)"
sif_require_choice TARGETARCH "$TARGETARCH" amd64 arm64 || exit 2
COMPOSE_PROJECT="$(sif_project_name)"
# --share bakes a different artifact (system-site-packages venv): give it its
# own filename so the two dev variants stop overwriting each other.
SHARE_SUFFIX=""
[ "$SHARE_MODE" = "true" ] && SHARE_SUFFIX="-share"
SIF_FILE="${SIF_FILE:-${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${MODE}${SHARE_SUFFIX}-${TARGETARCH}.sif}"
GIT_COMMIT="$(git -C "${WS_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# PROD_FULL_CUDA is the documented user-facing spelling of the FULL_CUDA build arg.
FULL_CUDA="${FULL_CUDA:-${PROD_FULL_CUDA:-false}}"
[ "$FULL_CUDA" = "1" ] && FULL_CUDA="true"

# Pass the release pin policy into every stage that imports dependencies.
[ "$MODE" = "prod" ] && DEVKIT_REQUIRE_PINNED="${DEVKIT_REQUIRE_PINNED:-1}"

BUILD_ARGS=(
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:22.04}"
    --build-arg "WORKSPACE_PATH=${WORKSPACE_PATH:-/workspace}"
    --build-arg "CONTAINER_USER=${CONTAINER_USER:-user}"
    --build-arg "USER_UID=${HOST_UID:-1000}"
    --build-arg "USER_GID=${HOST_GID:-1000}"
    --build-arg "ROS_DISTRO=${ROS_DISTRO:-humble}"
    --build-arg "FULL_CUDA=${FULL_CUDA}"
    --build-arg "IMAGE_TAG=${IMAGE_TAG:-latest}"
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-}"
    --build-arg "DEVKIT_STRIP_SOURCE=${DEVKIT_STRIP_SOURCE:-}"
    --build-arg "DEVKIT_FAIL_ON_SOURCE=${DEVKIT_FAIL_ON_SOURCE:-}"
    --build-arg "GIT_COMMIT=${GIT_COMMIT}"
    --build-arg "DEVKIT_REQUIRE_PINNED=${DEVKIT_REQUIRE_PINNED:-0}"
    --build-arg "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT}"
)

# Forward the remaining Dockerfile knobs only when set, so unset ones keep
# their Dockerfile defaults (--build-arg KEY= would override with empty).
# Without CUDA_VERSION in particular, a SIF baked on a GPU host silently
# ships with no CUDA while the equivalent compose build installs it.
for arg in APT_SNAPSHOT_DATE APT_SNAPSHOT_FALLBACK ROS_SNAPSHOT_DATE STRICT_GPG_CHECK OPENCV_CUDA \
           UV_VERSION UV_PYTHON UV_EXTRA TARGETARCH \
           SYS_PYTHON_EXE UV_SYNC_FLAGS CMAKE_EXTRA_ARGS COLCON_EXTRA_FLAGS \
           CMAKE_C_STANDARD CMAKE_CXX_STANDARD CUDA_VERSION CUDNN_VERSION LANG TZ; do
    [ -n "${!arg:-}" ] && BUILD_ARGS+=(--build-arg "${arg}=${!arg}")
done

TEMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/devkit-bake.XXXXXX")"
trap 'rm -f "$TEMP_ARCHIVE"' EXIT

if [ "$MODE" = "dev" ]; then
    BASE_TARGET="$ENV_NAME"
    DOCKER_IMG="${COMPOSE_PROJECT}_${ENV_NAME}_snapshot:latest"
    SYNC_FLAG=""
    [ "$SHARE_MODE" = "true" ] && SYNC_FLAG="--share"

    log_info "Building dev snapshot image (target=${BASE_TARGET})..."
    docker build --platform "linux/${TARGETARCH}" \
        -f "${WS_ROOT}/docker/Dockerfile" \
        --target "$BASE_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "${COMPOSE_PROJECT}_${ENV_NAME}_base:latest" "${WS_ROOT}"

    docker build --platform "linux/${TARGETARCH}" -t "$DOCKER_IMG" -f - "${WS_ROOT}" <<EOF
FROM ${COMPOSE_PROJECT}_${ENV_NAME}_base:latest
COPY . ${WORKSPACE_PATH:-/workspace}
RUN DEVKIT_BUILD_TYPE=${DEVKIT_BUILD_TYPE:-dev} bash -lc "source ${WORKSPACE_PATH:-/workspace}/config/util_aliases.sh && mksync ${SYNC_FLAG}"
WORKDIR ${WORKSPACE_PATH:-/workspace}
EOF
else
    PROD_TARGET="prod-${ENV_NAME}-runtime"
    DOCKER_IMG="${COMPOSE_PROJECT}_${ENV_NAME}_prod:latest"

    log_info "Building production runtime image (target=${PROD_TARGET})..."
    docker build --platform "linux/${TARGETARCH}" \
        -f "${WS_ROOT}/docker/Dockerfile" \
        --target "$PROD_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "$DOCKER_IMG" "${WS_ROOT}"
fi

actual_arch="$(docker image inspect --format '{{.Architecture}}' "$DOCKER_IMG")"
[ "$actual_arch" = "$TARGETARCH" ] || { log_error "Image architecture mismatch: $actual_arch != $TARGETARCH"; exit 1; }

# Record the OCI identity and declared base. A local tag may refer to a
# different image from BuildKit's base, so only an explicit digest is recorded.
write_provenance() {   # write_provenance <destination>
    local base="${BASE_IMAGE:-ubuntu:22.04}" digest=""
    case "$base" in *@sha256:*) digest="${base##*@}" ;; esac
    {
        printf 'oci_image_id=%s\n' "$(docker image inspect --format '{{.Id}}' "$DOCKER_IMG")"
        printf 'base_image=%s\n'   "$base"
        printf 'base_digest=%s\n' "$digest"
        printf 'git_commit=%s\narch=%s\ndevkit_version=%s\n' \
            "$GIT_COMMIT" "$TARGETARCH" "$(cat "${WS_ROOT}/VERSION" 2>/dev/null || echo unknown)"
        # Cheap staleness check for the sha256 sidecar: a run compares this
        # against the artifact on disk instead of re-hashing gigabytes.
        [ "${1##*.}" = provenance ] && [ -f "${1%.provenance}" ] && \
            printf 'artifact_bytes=%s\n' "$(wc -c < "${1%.provenance}" | tr -d ' ')"
    } > "$1"
}
docker save -o "$TEMP_ARCHIVE" "$DOCKER_IMG"
if [ "$BAKE_FORMAT" = oci ]; then
    archive="${SIF_FILE%.sif}.oci.tar"
    mv "$TEMP_ARCHIVE" "$archive"
    write_provenance "${archive}.provenance"
    log_ok "Docker/OCI transport archive: $archive"
    log_detail "On Linux: apptainer build '${SIF_FILE##*/}' 'docker-archive://${archive##*/}'"
    exit 0
fi
log_info "Converting Docker image to SIF artifact: ${SIF_FILE}..."
# Convert beside the destination and publish only after a successful build.
TEMP_SIF="$(mktemp "${SIF_FILE}.XXXXXX")"
trap 'rm -f "$TEMP_ARCHIVE" "$TEMP_SIF"' EXIT
"$RUNTIME" build --force "$TEMP_SIF" "docker-archive://${TEMP_ARCHIVE}"
mv "$TEMP_SIF" "$SIF_FILE"
# Hash once, here: every run and every job submission wants this digest, and
# re-reading a multi-GB artifact per launch is minutes of I/O for a value that
# cannot change. sif_record_run reuses the sidecar when it is present.
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$SIF_FILE")" && sha256sum "$(basename "$SIF_FILE")") > "${SIF_FILE}.sha256"
elif command -v shasum >/dev/null 2>&1; then
    (cd "$(dirname "$SIF_FILE")" && shasum -a 256 "$(basename "$SIF_FILE")") > "${SIF_FILE}.sha256"
fi

write_provenance "${SIF_FILE}.provenance"

log_ok "SIF artifact baked successfully: ${SIF_FILE}"

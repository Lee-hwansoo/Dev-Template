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

case "$MODE" in dev|prod) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --mode must be 'dev' or 'prod' (got: ${MODE})" >&2; exit 2 ;;
esac
case "$ENV_NAME" in ros|dev) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --env must be 'ros' or 'dev' (got: ${ENV_NAME})" >&2; exit 2 ;;
esac
if [ "$SHARE_MODE" = "true" ] && [ "$MODE" = "prod" ]; then
    log_error "--share is a dev-snapshot option; prod builds always install a self-contained venv."
    exit 2
fi

RUNTIME="$(sif_runtime)" || exit 1
sif_import_host_env || exit 1
COMPOSE_PROJECT="$(sif_project_name)"
# --share bakes a different artifact (system-site-packages venv): give it its
# own filename so the two dev variants stop overwriting each other.
SHARE_SUFFIX=""
[ "$SHARE_MODE" = "true" ] && SHARE_SUFFIX="-share"
SIF_FILE="${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${MODE}${SHARE_SUFFIX}.sif"
GIT_COMMIT="$(git -C "${WS_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# PROD_FULL_CUDA is the documented user-facing spelling of the FULL_CUDA build arg.
FULL_CUDA="${FULL_CUDA:-${PROD_FULL_CUDA:-false}}"
[ "$FULL_CUDA" = "1" ] && FULL_CUDA="true"

BUILD_ARGS=(
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:22.04}"
    --build-arg "WORKSPACE_PATH=${WORKSPACE_PATH:-/workspace}"
    --build-arg "CONTAINER_USER=${CONTAINER_USER:-user}"
    --build-arg "USER_UID=${HOST_UID:-1000}"
    --build-arg "USER_GID=${HOST_GID:-1000}"
    --build-arg "ROS_DISTRO=${ROS_DISTRO:-humble}"
    --build-arg "GPU_MODE=${GPU_MODE:-auto}"
    --build-arg "HAS_NVIDIA=${HAS_NVIDIA:-false}"
    --build-arg "FULL_CUDA=${FULL_CUDA}"
    --build-arg "IMAGE_TAG=${IMAGE_TAG:-latest}"
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-}"
    --build-arg "DEVKIT_STRIP_SOURCE=${DEVKIT_STRIP_SOURCE:-}"
    --build-arg "DEVKIT_FAIL_ON_SOURCE=${DEVKIT_FAIL_ON_SOURCE:-}"
    --build-arg "GIT_COMMIT=${GIT_COMMIT}"
    --build-arg "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT}"
)

# Forward the remaining Dockerfile knobs only when set, so unset ones keep
# their Dockerfile defaults (--build-arg KEY= would override with empty).
# Without CUDA_VERSION in particular, a SIF baked on a GPU host silently
# ships with no CUDA while the equivalent compose build installs it.
for arg in APT_SNAPSHOT_DATE STRICT_GPG_CHECK UV_VERSION UV_PYTHON TARGETARCH \
           SYS_PYTHON_EXE UV_SYNC_FLAGS CMAKE_EXTRA_ARGS COLCON_EXTRA_FLAGS \
           CUDA_VERSION CUDNN_VERSION LANG TZ; do
    [ -n "${!arg:-}" ] && BUILD_ARGS+=(--build-arg "${arg}=${!arg}")
done

TEMP_ARCHIVE="$(mktemp /tmp/devkit-bake.XXXXXX.tar)"
trap 'rm -f "$TEMP_ARCHIVE"' EXIT

if [ "$MODE" = "dev" ]; then
    BASE_TARGET="$ENV_NAME"
    DOCKER_IMG="${COMPOSE_PROJECT}_${ENV_NAME}_snapshot:latest"
    SYNC_FLAG=""
    [ "$SHARE_MODE" = "true" ] && SYNC_FLAG="--share"

    log_info "Building dev snapshot image (target=${BASE_TARGET})..."
    docker build \
        -f "${WS_ROOT}/docker/Dockerfile" \
        --target "$BASE_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "${COMPOSE_PROJECT}_${ENV_NAME}_base:latest" "${WS_ROOT}"

    docker build -t "$DOCKER_IMG" -f - "${WS_ROOT}" <<EOF
FROM ${COMPOSE_PROJECT}_${ENV_NAME}_base:latest
COPY . ${WORKSPACE_PATH:-/workspace}
RUN DEVKIT_BUILD_TYPE=${DEVKIT_BUILD_TYPE:-dev} bash -lc "source ${WORKSPACE_PATH:-/workspace}/config/util_aliases.sh && mksync ${SYNC_FLAG}"
WORKDIR ${WORKSPACE_PATH:-/workspace}
EOF
else
    PROD_TARGET="prod-${ENV_NAME}-runtime"
    DOCKER_IMG="${COMPOSE_PROJECT}_${ENV_NAME}_prod:latest"

    log_info "Building production runtime image (target=${PROD_TARGET})..."
    docker build \
        -f "${WS_ROOT}/docker/Dockerfile" \
        --target "$PROD_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "$DOCKER_IMG" "${WS_ROOT}"
fi

log_info "Converting Docker image to SIF artifact: ${SIF_FILE}..."
docker save -o "$TEMP_ARCHIVE" "$DOCKER_IMG"
"$RUNTIME" build --force "$SIF_FILE" "docker-archive://${TEMP_ARCHIVE}"

log_ok "SIF artifact baked successfully: ${SIF_FILE}"

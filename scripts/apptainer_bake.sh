#!/bin/bash
# =============================================================================
# scripts/apptainer_bake.sh
# Bake development snapshot or production runtime into an Apptainer SIF file.
# Usage: apptainer_bake.sh [--mode dev|prod] [--env ros|dev] [--share]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Host-side script: WORKSPACE_PATH is the CONTAINER path (and the Makefile
# exports it), so the repository root can only come from this file's location.
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="dev"
ENV_NAME="${ENV:-ros}"
SHARE_MODE="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) [ $# -ge 2 ] || { echo -e "  \033[31m[ERROR]\033[0m --mode needs a value (dev|prod)" >&2; exit 2; }
                MODE="$2"; shift 2 ;;
        --env)  [ $# -ge 2 ] || { echo -e "  \033[31m[ERROR]\033[0m --env needs a value (ros|dev)" >&2; exit 2; }
                ENV_NAME="$2"; shift 2 ;;
        --share) SHARE_MODE="true"; shift ;;
        -h|--help)
            echo "Usage: apptainer_bake.sh [--mode dev|prod] [--env ros|dev] [--share]"
            exit 0 ;;
        *) echo -e "  \033[31m[ERROR]\033[0m Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$MODE" in dev|prod) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --mode must be 'dev' or 'prod' (got: ${MODE})" >&2; exit 2 ;;
esac
case "$ENV_NAME" in ros|dev) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --env must be 'ros' or 'dev' (got: ${ENV_NAME})" >&2; exit 2 ;;
esac
if [ "$SHARE_MODE" = "true" ] && [ "$MODE" = "prod" ]; then
    echo -e "  \033[31m[ERROR]\033[0m --share is a dev-snapshot option; prod builds always install a self-contained venv." >&2
    exit 2
fi

RUNTIME="apptainer"
if ! command -v apptainer >/dev/null 2>&1; then
    if command -v singularity >/dev/null 2>&1; then
        RUNTIME="singularity"
    else
        echo -e "  \033[31m[ERROR]\033[0m Neither apptainer nor singularity found!" >&2
        exit 1
    fi
fi

# Import detected environment settings. check_env.sh calls `exit` on a fatal
# misconfiguration, so it must run as a child process — sourcing it would kill
# this script with the error message suppressed.
if env_out="$(bash "${WS_ROOT}/scripts/check_env.sh")"; then
    eval "$env_out"
else
    echo -e "  \033[31m[ERROR]\033[0m Host environment detection failed. Run 'bash scripts/check_env.sh' to see why." >&2
    exit 1
fi

# Project name: env (make export) → .env (direct script invocation) → devkit.
# All three SIF consumers (bake / run / slurm docs) must derive the same name.
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${WS_ROOT}/.env" 2>/dev/null | tail -1 | tr -d "\r\"'")}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-devkit}"
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

    echo -e "  \033[34m[Bake Dev]\033[0m Building dev snapshot image (target=${BASE_TARGET})..."
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

    echo -e "  \033[34m[Bake Prod]\033[0m Building production runtime image (target=${PROD_TARGET})..."
    docker build \
        -f "${WS_ROOT}/docker/Dockerfile" \
        --target "$PROD_TARGET" \
        "${BUILD_ARGS[@]}" \
        -t "$DOCKER_IMG" "${WS_ROOT}"
fi

echo -e "  \033[34m[Bake]\033[0m Converting Docker image to SIF artifact: ${SIF_FILE}..."
docker save -o "$TEMP_ARCHIVE" "$DOCKER_IMG"
"$RUNTIME" build --force "$SIF_FILE" "docker-archive://${TEMP_ARCHIVE}"

echo -e "  \033[32m[OK]\033[0m SIF artifact baked successfully: ${SIF_FILE}"

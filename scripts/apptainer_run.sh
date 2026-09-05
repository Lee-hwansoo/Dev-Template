#!/bin/bash
# =============================================================================
# scripts/apptainer_run.sh — run a SIF artifact locally, or submit it to SLURM.
# Usage: apptainer_run.sh [--mode dev|prod|slurm] [--env ros|dev] [command...]
# =============================================================================
set -euo pipefail

# WS_ROOT comes from util_paths.sh, which ignores a WORKSPACE_PATH that is not a
# DevKit tree on THIS machine — the Makefile exports the container path.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
devkit_require "util_sif_common.sh"
LOG_PREFIX="[Apptainer]"

MODE="dev"
ENV_NAME="${ENV:-ros}"
APP_CMD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) [ $# -ge 2 ] || { log_error "--mode needs a value (dev|prod|slurm)"; exit 2; }
                MODE="$2"; shift 2 ;;
        --env)  [ $# -ge 2 ] || { log_error "--env needs a value (ros|dev)"; exit 2; }
                ENV_NAME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: apptainer_run.sh [--mode dev|prod|slurm] [--env ros|dev] [--] [command...]"
            exit 0 ;;
        # `--` is the escape hatch for a command that itself starts with a dash;
        # without it a typo'd flag would silently become the container command.
        --) shift; APP_CMD="$*"; break ;;
        -*) log_error "Unknown option: $1 (use '--' before a command starting with '-')"; exit 2 ;;
        *) APP_CMD="$*"; break ;;
    esac
done

sif_require_choice --mode "$MODE" dev prod slurm || exit 2
sif_require_choice --env "$ENV_NAME" ros dev || exit 2

# APP_COMMAND is the env-var spelling of the trailing command (docs/SLURM.md).
APP_CMD="${APP_CMD:-${APP_COMMAND:-}}"

sif_import_host_env || exit 1

# An explicit SIF_FILE is used as-is and MUST exist: substituting a stale local
# artifact for a mistyped /scratch path runs the wrong image silently. The
# default probes only THIS mode's variants, for the same reason.
COMPOSE_PROJECT="$(sif_project_name)"
# slurm submits the PRODUCTION artifact (there is no `bake --mode slurm`), which
# .env.example states and the hint below already assumed — the probe has to use
# the same mapping or the default slurm run can never find an artifact.
ARTIFACT_MODE="$MODE"; [ "$MODE" = "slurm" ] && ARTIFACT_MODE="prod"
if [ -z "${SIF_FILE:-}" ]; then
    for candidate in "${ARTIFACT_MODE}" "${ARTIFACT_MODE}-share"; do
        SIF_FILE="${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${candidate}.sif"
        [ -f "$SIF_FILE" ] && break
    done
fi
if [ ! -f "$SIF_FILE" ]; then
    log_error "SIF artifact not found: ${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${ARTIFACT_MODE}.sif"
    log_detail "Run 'make bake-${ARTIFACT_MODE} ENV=${ENV_NAME}' first, or point SIF_FILE at an existing artifact." >&2
    exit 1
fi

# Forward environment variables to Apptainer
export APPTAINERENV_ROS_DISTRO="${ROS_DISTRO:-humble}"
export APPTAINERENV_ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export APPTAINERENV_RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
[ -n "${ROS_MASTER_URI:-}" ] && export APPTAINERENV_ROS_MASTER_URI="$ROS_MASTER_URI"
[ -n "${GPU_MODE:-}" ] && export APPTAINERENV_GPU_MODE="$GPU_MODE"

# Dispatch to SLURM scheduler if requested
if [ "$MODE" = "slurm" ]; then
    SLURM_SCRIPT="${WS_ROOT}/scripts/slurm_run.sh"

    # DEVKIT_SLURM_* → sbatch flags, which override slurm_run.sh's #SBATCH
    # defaults, so an unset knob keeps the script default. --chdir pins the cwd
    # so the relative #SBATCH log paths land in the workspace; --export=ALL
    # guards against sites that default to NONE and strip the ROS/DDS env.
    SBATCH_OPTS=( "--chdir=${WS_ROOT}" "--export=ALL" )
    [ -n "${DEVKIT_SLURM_PARTITION:-}"     ] && SBATCH_OPTS+=( "--partition=${DEVKIT_SLURM_PARTITION}" )
    [ -n "${DEVKIT_SLURM_GRES:-}"          ] && SBATCH_OPTS+=( "--gres=${DEVKIT_SLURM_GRES}" )
    [ -n "${DEVKIT_SLURM_CPUS_PER_TASK:-}" ] && SBATCH_OPTS+=( "--cpus-per-task=${DEVKIT_SLURM_CPUS_PER_TASK}" )
    [ -n "${DEVKIT_SLURM_NODES:-}"         ] && SBATCH_OPTS+=( "--nodes=${DEVKIT_SLURM_NODES}" )
    [ -n "${DEVKIT_SLURM_NTASKS:-}"        ] && SBATCH_OPTS+=( "--ntasks=${DEVKIT_SLURM_NTASKS}" )
    [ -n "${DEVKIT_SLURM_MEM:-}"           ] && SBATCH_OPTS+=( "--mem=${DEVKIT_SLURM_MEM}" )
    [ -n "${DEVKIT_SLURM_TIME:-}"          ] && SBATCH_OPTS+=( "--time=${DEVKIT_SLURM_TIME}" )
    [ -n "${DEVKIT_SLURM_JOB_NAME:-}"      ] && SBATCH_OPTS+=( "--job-name=${DEVKIT_SLURM_JOB_NAME}" )
    [ -n "${DEVKIT_SLURM_OUTPUT:-}"        ] && SBATCH_OPTS+=( "--output=${DEVKIT_SLURM_OUTPUT}" )
    [ -n "${DEVKIT_SLURM_ERROR:-}"         ] && SBATCH_OPTS+=( "--error=${DEVKIT_SLURM_ERROR}" )
    [ -n "${DEVKIT_SLURM_COMMENT:-}"       ] && SBATCH_OPTS+=( "--comment=${DEVKIT_SLURM_COMMENT}" )
    # Escape hatch for unmanaged sbatch flags. Word-split on purpose; values
    # containing spaces are not supported (use #SBATCH in slurm_run.sh instead).
    # shellcheck disable=SC2206
    [ -n "${DEVKIT_SLURM_EXTRA_ARGS:-}" ] && SBATCH_OPTS+=( ${DEVKIT_SLURM_EXTRA_ARGS} )

    # APP_CMD reaches slurm_run.sh as ONE argument and runs via `bash -c`, so
    # quoting survives for APP_COMMAND and RUN_ARGS; a raw multi-arg call here
    # is space-joined by "$*" first and loses inner quoting.
    if command -v sbatch >/dev/null 2>&1; then
        # ${arr[@]+...}: empty-array "${arr[@]}" is fatal under set -u in
        # bash < 4.4 (RHEL 7/8 SLURM nodes).
        log_info "Submitting job (${SBATCH_OPTS[*]})..."
        exec sbatch ${SBATCH_OPTS[@]+"${SBATCH_OPTS[@]}"} "$SLURM_SCRIPT" "$SIF_FILE" ${APP_CMD:+"$APP_CMD"}
    else
        log_warn "sbatch not found. Falling back to local execution:"
        exec bash "$SLURM_SCRIPT" "$SIF_FILE" ${APP_CMD:+"$APP_CMD"}
    fi
fi

# Build Apptainer bind mounts & options
BIND_OPTS=()

# Dev mode: bind-mount host workspace into container
if [ "$MODE" = "dev" ]; then
    BIND_OPTS+=( "--bind" "${WS_ROOT}:/workspace" )
fi

# GPU / Display / Acceleration Binds
[ -d "/dev/dri" ] && BIND_OPTS+=( "--bind" "/dev/dri:/dev/dri" )
[ -e "/dev/dxg" ] && BIND_OPTS+=( "--bind" "/dev/dxg:/dev/dxg" )
[ -d "/usr/lib/wsl" ] && BIND_OPTS+=( "--bind" "/usr/lib/wsl:/usr/lib/wsl:ro" )

# Display & GUI forwarding
if [ -n "${DISPLAY:-}" ]; then
    export APPTAINERENV_DISPLAY="$DISPLAY"
    [ -d "/tmp/.X11-unix" ] && BIND_OPTS+=( "--bind" "/tmp/.X11-unix:/tmp/.X11-unix" )
    [ -f "${XAUTHORITY:-$HOME/.Xauthority}" ] && BIND_OPTS+=( "--bind" "${XAUTHORITY:-$HOME/.Xauthority}:/tmp/.container_xauth:ro" ) && export APPTAINERENV_XAUTHORITY="/tmp/.container_xauth"
fi
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export APPTAINERENV_WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
    [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && BIND_OPTS+=( "--bind" "${XDG_RUNTIME_DIR}:/tmp/.container_xdg" ) && export APPTAINERENV_XDG_RUNTIME_DIR="/tmp/.container_xdg"
fi

GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1 || [ "${HAS_NVIDIA:-false}" = "true" ]; then
    GPU_FLAGS+=( "--nv" )
fi

RUNTIME="$(sif_runtime)" || exit 1

log_info "Executing ${SIF_FILE} (mode=${MODE})..."
if [ -n "${APP_CMD:-}" ]; then
    # Route the command through the image entrypoint (see sif_entry_args), the
    # same way `make exec` does for docker.
    read -r -a ENTRY <<< "$(sif_entry_args "$RUNTIME" "$SIF_FILE")"
    exec "$RUNTIME" exec ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
        "$SIF_FILE" ${ENTRY[@]+"${ENTRY[@]}"} bash -c "${APP_CMD}"
else
    exec "$RUNTIME" run ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} "$SIF_FILE"
fi

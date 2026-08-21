#!/bin/bash
# =============================================================================
# scripts/apptainer_run.sh
# Run SIF artifact locally (dev/prod) or submit to SLURM cluster.
# Usage: apptainer_run.sh [--mode dev|prod|slurm] [--env ros|dev] [command...]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Host-side script: WORKSPACE_PATH is the CONTAINER path (and the Makefile
# exports it), so the repository root can only come from this file's location.
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="dev"
ENV_NAME="${ENV:-ros}"
APP_CMD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) [ $# -ge 2 ] || { echo -e "  \033[31m[ERROR]\033[0m --mode needs a value (dev|prod|slurm)" >&2; exit 2; }
                MODE="$2"; shift 2 ;;
        --env)  [ $# -ge 2 ] || { echo -e "  \033[31m[ERROR]\033[0m --env needs a value (ros|dev)" >&2; exit 2; }
                ENV_NAME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: apptainer_run.sh [--mode dev|prod|slurm] [--env ros|dev] [--] [command...]"
            exit 0 ;;
        # `--` is the escape hatch for a command that itself starts with a dash;
        # without it a typo'd flag would silently become the container command.
        --) shift; APP_CMD="$*"; break ;;
        -*) echo -e "  \033[31m[ERROR]\033[0m Unknown option: $1 (use '--' before a command starting with '-')" >&2; exit 2 ;;
        *) APP_CMD="$*"; break ;;
    esac
done

case "$MODE" in dev|prod|slurm) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --mode must be 'dev', 'prod' or 'slurm' (got: ${MODE})" >&2; exit 2 ;;
esac
case "$ENV_NAME" in ros|dev) ;; *)
    echo -e "  \033[31m[ERROR]\033[0m --env must be 'ros' or 'dev' (got: ${ENV_NAME})" >&2; exit 2 ;;
esac

# APP_COMMAND is the env-var spelling of the trailing command (docs/SLURM.md).
APP_CMD="${APP_CMD:-${APP_COMMAND:-}}"

# Import detected environment settings. check_env.sh calls `exit` on a fatal
# misconfiguration, so it must run as a child process — sourcing it would kill
# this script with the error message suppressed.
if env_out="$(bash "${WS_ROOT}/scripts/check_env.sh")"; then
    eval "$env_out"
else
    echo -e "  \033[31m[ERROR]\033[0m Host environment detection failed. Run 'bash scripts/check_env.sh' to see why." >&2
    exit 1
fi

# Resolve SIF file. An explicitly given SIF_FILE is used as-is and MUST exist —
# silently substituting a stale local artifact for a mistyped /scratch path
# would run the wrong image without a word. The automatic default probes only
# THIS mode's variants (mode → mode-share): running a dev SIF because prod was
# never baked is the same wrong-image failure, not a convenience.
# Project name: env (make export) → .env (direct script invocation) → devkit.
# Must match apptainer_bake.sh or the default probe misses freshly baked SIFs.
# tail/tr: keep the last assignment, drop quotes and CR that compose tolerates
# but a filename must not contain.
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${WS_ROOT}/.env" 2>/dev/null | tail -1 | tr -d "\r\"'")}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-devkit}"
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
    echo -e "  \033[31m[ERROR]\033[0m SIF artifact not found: ${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${ARTIFACT_MODE}.sif" >&2
    echo -e "  \033[36m[Hint]\033[0m Run 'make bake-${ARTIFACT_MODE} ENV=${ENV_NAME}' first, or point SIF_FILE at an existing artifact." >&2
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

    # DEVKIT_SLURM_* → sbatch flags. Command-line flags override the #SBATCH
    # defaults baked into slurm_run.sh, so an unset knob keeps the script default.
    # --chdir pins the job's cwd to the workspace, so the relative #SBATCH
    # log paths (logs/%x_%j.out) land there no matter where it was submitted.
    # --export=ALL is SLURM's own default, but sites that set NONE would strip
    # the ROS/DDS env slurm_run.sh forwards into the container.
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

    # APP_CMD reaches slurm_run.sh as ONE argument and runs via `bash -c`.
    # Quoting survives for the APP_COMMAND env spelling and for the Makefile's
    # RUN_ARGS (passed as a single argument); raw multi-arg invocations of this
    # script are space-joined by "$*" first and lose inner quoting.
    if command -v sbatch >/dev/null 2>&1; then
        # ${arr[@]+...}: empty-array "${arr[@]}" is fatal under set -u in
        # bash < 4.4 (RHEL 7/8 SLURM nodes).
        echo -e "  \033[34m[SLURM]\033[0m Submitting job (${SBATCH_OPTS[*]})..."
        exec sbatch ${SBATCH_OPTS[@]+"${SBATCH_OPTS[@]}"} "$SLURM_SCRIPT" "$SIF_FILE" ${APP_CMD:+"$APP_CMD"}
    else
        echo -e "  \033[33m[WARN]\033[0m sbatch not found. Falling back to local execution:"
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

RUNTIME="apptainer"
command -v apptainer >/dev/null 2>&1 || RUNTIME="singularity"

echo -e "  \033[34m[Apptainer]\033[0m Executing ${SIF_FILE} (mode=${MODE})..."
if [ -n "${APP_CMD:-}" ]; then
# `apptainer exec` does NOT run the image's ENTRYPOINT, so a bare command starts
# with no ROS/venv/GPU environment at all (`import rclpy` fails). Route it
# through /entrypoint.sh, exactly like `make exec` does for docker: the dev
# entrypoint takes `--env <cmd>`, the production one execs "$@" directly.
ENTRY=()
if "$RUNTIME" exec "$SIF_FILE" test -x /entrypoint.sh 2>/dev/null; then
    ENTRY=(/entrypoint.sh)
    "$RUNTIME" exec "$SIF_FILE" grep -q '"--env"' /entrypoint.sh 2>/dev/null && ENTRY+=(--env)
fi
    exec "$RUNTIME" exec ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
        "$SIF_FILE" ${ENTRY[@]+"${ENTRY[@]}"} bash -c "${APP_CMD}"
else
    exec "$RUNTIME" run ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} "$SIF_FILE"
fi

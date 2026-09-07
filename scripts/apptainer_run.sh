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
# Set by `--`: the command as ARGV, for a command bash -c cannot take.
APP_ARGV=()

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
        # `--` hands the command through as ARGV (APP_ARGV), because a command
        # whose name starts with a dash can never be run by `bash -c`: bash
        # reads it as its own flag.
        --) shift; APP_ARGV=("$@"); break ;;
        -*) log_error "Unknown option: $1 (use '--' before a command starting with '-')"; exit 2 ;;
        *) if [ $# -eq 1 ]; then APP_CMD="$1"; else printf -v APP_CMD '%q ' "$@"; fi; break ;;
    esac
done

sif_require_choice --mode "$MODE" dev prod slurm || exit 2
sif_require_choice --env "$ENV_NAME" ros dev || exit 2

# The ONE place the command precedence lives: argv, then RUN_ARGS (the make
# spelling, exported as-is), then the .env pair. It used to be split with the
# Makefile, and a ROS_LAUNCH_COMMAND in .env silently beat every RUN_ARGS.
APP_CMD="${APP_CMD:-${RUN_ARGS:-${ROS_LAUNCH_COMMAND:-${APP_COMMAND:-}}}}"

# An explicit SIF_FILE is used as-is and MUST exist: substituting a stale local
# artifact for a mistyped /scratch path runs the wrong image silently. The
# default probes only THIS mode's variants, for the same reason.
COMPOSE_PROJECT="$(sif_project_name)"
# slurm submits the PRODUCTION artifact (there is no `bake --mode slurm`), which
# .env.example states and the hint below already assumed — the probe has to use
# the same mapping or the default slurm run can never find an artifact.
ARTIFACT_MODE="$MODE"; [ "$MODE" = "slurm" ] && ARTIFACT_MODE="prod"
if [ -z "${SIF_FILE:-}" ]; then
    arch="$(sif_arch)"
    # -share exists for dev bakes only (mkenv --share); offering it for prod
    # made the "not found" message name a file prod never produces.
    candidates=("${ARTIFACT_MODE}-${arch}" "${ARTIFACT_MODE}")
    [ "$ARTIFACT_MODE" != dev ] || candidates=("${ARTIFACT_MODE}-${arch}" "${ARTIFACT_MODE}-share-${arch}" "${ARTIFACT_MODE}" "${ARTIFACT_MODE}-share")
    for candidate in "${candidates[@]}"; do
        SIF_FILE="${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${candidate}.sif"
        [ -f "$SIF_FILE" ] && break
    done
    # The message must name the FIRST candidate, the one a bake writes.
    [ -f "$SIF_FILE" ] || SIF_FILE="${WS_ROOT}/${COMPOSE_PROJECT}-${ENV_NAME}-${candidates[0]}.sif"
fi
if [ ! -f "$SIF_FILE" ]; then
    log_error "SIF artifact not found: ${SIF_FILE}"
    log_detail "Run 'make bake-${ARTIFACT_MODE} ENV=${ENV_NAME}' first, or point SIF_FILE at an existing artifact." >&2
    exit 1
fi
SIF_FILE="$(cd "$(dirname "$SIF_FILE")" && pwd)/$(basename "$SIF_FILE")"

# Forward environment variables to Apptainer
sif_forward_env

# Dispatch to SLURM scheduler if requested
if [ "$MODE" = "slurm" ]; then
    SLURM_SCRIPT="${WS_ROOT}/scripts/slurm_run.sh"
    { [ -n "$APP_CMD" ] || [ "${#APP_ARGV[@]}" -gt 0 ]; } \
        || { log_error 'No job command. Pass RUN_ARGS or APP_COMMAND.'; exit 2; }
    command -v sbatch >/dev/null || { log_error "sbatch not found. Use SIF_MODE=prod for local execution."; exit 1; }
    export DEVKIT_REPO_ROOT="$WS_ROOT"
    mkdir -p "$WS_ROOT/logs"

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
    [ -n "${DEVKIT_SLURM_SIGNAL:-}"        ] && SBATCH_OPTS+=( "--signal=${DEVKIT_SLURM_SIGNAL}" )
    [ -n "${DEVKIT_SLURM_ARRAY:-}"         ] && SBATCH_OPTS+=( "--array=${DEVKIT_SLURM_ARRAY}" )
    [ -n "${DEVKIT_SLURM_ACCOUNT:-}"       ] && SBATCH_OPTS+=( "--account=${DEVKIT_SLURM_ACCOUNT}" )
    # Escape hatch for unmanaged sbatch flags. Word-split on purpose; values
    # containing spaces are not supported (use #SBATCH in slurm_run.sh instead).
    # shellcheck disable=SC2206
    [ -n "${DEVKIT_SLURM_EXTRA_ARGS:-}" ] && SBATCH_OPTS+=( ${DEVKIT_SLURM_EXTRA_ARGS} )

    # Submit the shell command as one argument to preserve its quoting.
    # ${arr[@]+...}: empty-array "${arr[@]}" is fatal under set -u in
    # bash < 4.4 (RHEL 7/8 SLURM nodes).
    log_info "Submitting job (${SBATCH_OPTS[*]})..."
    # slurm_run.sh already runs a multi-word argv directly, so `--` reaches the
    # compute node as argv rather than through a shell.
    if [ "${#APP_ARGV[@]}" -gt 0 ]; then
        exec sbatch ${SBATCH_OPTS[@]+"${SBATCH_OPTS[@]}"} "$SLURM_SCRIPT" "$SIF_FILE" "${APP_ARGV[@]}"
    fi
    exec sbatch ${SBATCH_OPTS[@]+"${SBATCH_OPTS[@]}"} "$SLURM_SCRIPT" "$SIF_FILE" ${APP_CMD:+"$APP_CMD"}
fi

# Build Apptainer bind mounts & options
RUNTIME="$(sif_runtime)" || exit 1
sif_data_binds
RUN_OPTS=(--cleanenv)

# Dev mode: bind-mount host workspace into container
if [ "$MODE" = "dev" ]; then
    container_ws="$("$RUNTIME" exec "$SIF_FILE" sh -c 'printf %s "${WORKSPACE_PATH:-/workspace}"')"
    for dir in src config scripts dependencies; do
        [ ! -d "$WS_ROOT/$dir" ] || BIND_OPTS+=(--bind "$WS_ROOT/$dir:$container_ws/$dir")
    done
    RUN_OPTS+=(--writable-tmpfs)
else
    RUN_OPTS+=(--containall)
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

sif_gpu_flags
sif_record_run "$SIF_FILE"

log_info "Executing ${SIF_FILE} (mode=${MODE})..."
if [ -n "${APP_CMD:-}" ] || [ "${#APP_ARGV[@]}" -gt 0 ]; then
    # The entrypoint loads ROS/venv; the wrapper records the command's status.
    read -r -a ENTRY <<< "$(sif_entry_args "$RUNTIME" "$SIF_FILE")"
    if [ "${#ENTRY[@]}" -eq 0 ]; then
        log_error 'Image has no DevKit entrypoint.'
        sif_record_exit 1
        exit 1
    fi
    RUN_RC=0
    if [ "${#APP_ARGV[@]}" -gt 0 ]; then
        sif_run_and_record "$RUNTIME" exec "${RUN_OPTS[@]}" ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
            "$SIF_FILE" ${ENTRY[@]+"${ENTRY[@]}"} "${APP_ARGV[@]}" || RUN_RC=$?
    else
        sif_run_and_record "$RUNTIME" exec "${RUN_OPTS[@]}" ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
            "$SIF_FILE" ${ENTRY[@]+"${ENTRY[@]}"} bash -c "${APP_CMD}" || RUN_RC=$?
    fi
    exit "$RUN_RC"
else
    # A prod artifact has no interactive shell: --cleanenv strips APP_COMMAND and
    # its entrypoint exits 2 on an empty command, which was recorded as
    # "interactive". Say what is missing instead, like the slurm branch does.
    if [ "$ARTIFACT_MODE" = prod ]; then
        log_error 'No command to run. Pass RUN_ARGS or APP_COMMAND (a production artifact has no interactive shell).'
        sif_record_exit 2
        exit 2
    fi
    # An interactive shell: exec, so the terminal talks to the container
    # directly. Nothing to close — say so rather than leaving the record open.
    sif_record_exit interactive
    exec "$RUNTIME" run "${RUN_OPTS[@]}" ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} "$SIF_FILE"
fi

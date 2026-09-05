#!/bin/bash
#SBATCH --job-name=devkit
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --comment=submitter:devkit

# =============================================================================
# scripts/slurm_run.sh — the sbatch job script: bind the data/run roots, forward
# the ROS/DDS env past --cleanenv, and exec the SIF through its entrypoint.
# The #SBATCH block above holds the defaults; DEVKIT_SLURM_* override them.
# =============================================================================
set -euo pipefail

# Runs on a compute node, from the repository the job was submitted from
# (apptainer_run.sh passes --chdir), so the shared helpers are reachable.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
devkit_require "util_sif_common.sh"

case "${1:-}" in
    -h|--help) echo "Usage: slurm_run.sh <sif-image> [command [args...]]"; exit 0 ;;
    -*) LOG_PREFIX="[SLURM]" log_error "Unknown option: $1"; exit 2 ;;
esac
# Required: a guessed default silently ran the wrong image.
SIF_IMAGE="${1:?Usage: slurm_run.sh <sif-image> [command [args...]]}"
shift || true

# Two call shapes: 1 arg (a pre-joined string from apptainer_run.sh) goes
# through `bash -c` to keep its quoting; N args exec verbatim, since re-parsing
# would re-interpret `&`, `(` and `$` inside legitimate arguments.
if [ $# -eq 1 ]; then CMD=( bash -c "$1" )
elif [ $# -gt 1 ]; then CMD=( "$@" )
else CMD=( bash ); fi

# --cleanenv keeps only APPTAINERENV_*/SINGULARITYENV_*, so forward the ROS/DDS
# knobs here too — a job submitted directly never passes through apptainer_run.
for v in ROS_DISTRO ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_LOCALHOST_ONLY; do
    if [ -n "${!v:-}" ]; then
        export "APPTAINERENV_${v}=${!v}" "SINGULARITYENV_${v}=${!v}"
    fi
done

# Relative on purpose: the #SBATCH --output/--error paths above are resolved by
# SLURM against the submission cwd, so this must use the same reference.
# apptainer_run.sh passes --chdir=${WS_ROOT}, which makes that the workspace.
mkdir -p logs

JOB_ID="${SLURM_JOB_ID:-LOCAL_TEST}"
LOG_PREFIX="[SLURM Job ${JOB_ID}]"
log_ok "Starting execution..."
log_detail "Nodes:        ${SLURM_JOB_NUM_NODES:-1}"
log_detail "CPUs/Task:    ${SLURM_CPUS_PER_TASK:-8}"
log_detail "SIF Artifact: ${SIF_IMAGE}"
log_detail "Command:      ${CMD[*]}"

# Host → container bind roots (mount points are configurable; see .env.example)
CONTAINER_DATA_ROOT="${CONTAINER_DATA_ROOT:-${WORKSPACE_PATH:-/workspace}/data}"
CONTAINER_RUN_ROOT="${CONTAINER_RUN_ROOT:-/runs}"

BIND_OPTS=()
if [ -n "${SLURM_DATA_ROOT:-}" ] && [ -d "${SLURM_DATA_ROOT}" ]; then
    BIND_OPTS+=( "--bind" "${SLURM_DATA_ROOT}:${CONTAINER_DATA_ROOT}:ro" )
    log_detail "Data (ro):    ${SLURM_DATA_ROOT} → ${CONTAINER_DATA_ROOT}"
fi
if [ -n "${SLURM_RUN_ROOT:-}" ]; then
    mkdir -p "${SLURM_RUN_ROOT}"
    BIND_OPTS+=( "--bind" "${SLURM_RUN_ROOT}:${CONTAINER_RUN_ROOT}" )
    log_detail "Runs (rw):    ${SLURM_RUN_ROOT} → ${CONTAINER_RUN_ROOT}"
fi

GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1 || [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
    GPU_FLAGS+=( "--nv" )
fi

RUNTIME="$(sif_runtime)" || exit 1
# Route the job through the image entrypoint (see sif_entry_args) — without it
# the job runs with none of the ROS/venv environment the artifact was built with.
read -r -a ENTRY <<< "$(sif_entry_args "$RUNTIME" "$SIF_IMAGE")"

# ${arr[@]+...}: plain "${arr[@]}" on an empty array is fatal under set -u in
# bash < 4.4 — the RHEL 7/8 bash that SLURM nodes actually run.
exec "$RUNTIME" exec ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} \
    --containall --cleanenv \
    ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
    "$SIF_IMAGE" ${ENTRY[@]+"${ENTRY[@]}"} "${CMD[@]}"

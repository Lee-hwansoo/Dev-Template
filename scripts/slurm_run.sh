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
# scripts/slurm_run.sh
# SLURM cluster job submission script for DevKit Apptainer SIF execution
# =============================================================================
set -euo pipefail

case "${1:-}" in
    -h|--help) echo "Usage: slurm_run.sh <sif-image> [command [args...]]"; exit 0 ;;
    -*) echo "slurm_run.sh: unknown option: $1" >&2; exit 2 ;;
esac
# The SIF path is required: a guessed default here silently ran the wrong
# image when this script was submitted directly.
SIF_IMAGE="${1:?Usage: slurm_run.sh <sif-image> [command [args...]]}"
shift || true

# Command handling — two call shapes, two semantics:
#   1 arg   (apptainer_run.sh pre-joined string) → `bash -c` so its internal
#           quoting survives;
#   N args  (direct `sbatch slurm_run.sh img python3 train.py --flag`) → exec
#           verbatim as argv; re-parsing through bash -c would re-interpret
#           metacharacters (`&`, `(`, `$`) inside legitimate arguments.
if [ $# -eq 1 ]; then CMD=( bash -c "$1" )
elif [ $# -gt 1 ]; then CMD=( "$@" )
else CMD=( bash ); fi

# --cleanenv strips everything except APPTAINERENV_*/SINGULARITYENV_*: forward
# the ROS/DDS knobs so a directly-submitted job (sbatch scripts/slurm_run.sh …)
# keeps them, not only jobs routed through apptainer_run.sh.
for v in ROS_DISTRO ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_LOCALHOST_ONLY; do
    if [ -n "${!v:-}" ]; then
        export "APPTAINERENV_${v}=${!v}" "SINGULARITYENV_${v}=${!v}"
    fi
done

mkdir -p logs

JOB_ID="${SLURM_JOB_ID:-LOCAL_TEST}"
echo -e "  \033[32m[SLURM Job ${JOB_ID}]\033[0m Starting execution..."
echo -e "  Node Count:   ${SLURM_JOB_NUM_NODES:-1}"
echo -e "  CPUs/Task:    ${SLURM_CPUS_PER_TASK:-8}"
echo -e "  SIF Artifact: ${SIF_IMAGE}"
echo -e "  Command:      ${CMD[*]}"

# Host → container bind roots (mount points are configurable; see .env.example)
CONTAINER_DATA_ROOT="${CONTAINER_DATA_ROOT:-${WORKSPACE_PATH:-/workspace}/data}"
CONTAINER_RUN_ROOT="${CONTAINER_RUN_ROOT:-/runs}"

BIND_OPTS=()
if [ -n "${SLURM_DATA_ROOT:-}" ] && [ -d "${SLURM_DATA_ROOT}" ]; then
    BIND_OPTS+=( "--bind" "${SLURM_DATA_ROOT}:${CONTAINER_DATA_ROOT}:ro" )
    echo -e "  Data (ro):    ${SLURM_DATA_ROOT} → ${CONTAINER_DATA_ROOT}"
fi
if [ -n "${SLURM_RUN_ROOT:-}" ]; then
    mkdir -p "${SLURM_RUN_ROOT}"
    BIND_OPTS+=( "--bind" "${SLURM_RUN_ROOT}:${CONTAINER_RUN_ROOT}" )
    echo -e "  Runs (rw):    ${SLURM_RUN_ROOT} → ${CONTAINER_RUN_ROOT}"
fi

GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1 || [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
    GPU_FLAGS+=( "--nv" )
fi

RUNTIME="apptainer"
command -v apptainer >/dev/null 2>&1 || RUNTIME="singularity"

# `apptainer exec` skips the image ENTRYPOINT, so the job would run without the
# ROS/venv environment the artifact was built with (`import rclpy` fails). Route
# through /entrypoint.sh like scripts/apptainer_run.sh does; --env is the dev
# entrypoint's exec-wrapper mode, absent from the production one.
ENTRY=()
if "$RUNTIME" exec "$SIF_IMAGE" test -x /entrypoint.sh 2>/dev/null; then
    ENTRY=(/entrypoint.sh)
    "$RUNTIME" exec "$SIF_IMAGE" grep -q '"--env"' /entrypoint.sh 2>/dev/null && ENTRY+=(--env)
fi

# ${arr[@]+...}: plain "${arr[@]}" on an empty array is fatal under set -u in
# bash < 4.4 — the RHEL 7/8 bash that SLURM nodes actually run.
exec "$RUNTIME" exec ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} \
    --containall --cleanenv \
    ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
    "$SIF_IMAGE" ${ENTRY[@]+"${ENTRY[@]}"} "${CMD[@]}"

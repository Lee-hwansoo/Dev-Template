#!/bin/bash
#SBATCH --job-name=devkit
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
# Warn the batch shell so its trap can forward TERM and close the run record.
#SBATCH --signal=B:TERM@60

# SLURM copies this file into its spool; helpers live in the submitted workspace.
set -euo pipefail
case "${1:-}" in
    -h|--help) echo 'Usage: slurm_run.sh <sif-image> [command [args...]]'; exit 0 ;;
    ''|-*) echo 'Usage: slurm_run.sh <sif-image> [command [args...]]' >&2; exit 2 ;;
esac
REPO_ROOT="${DEVKIT_REPO_ROOT:-${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
# sbatch copies THIS file into the SLURM spool, but the helpers stay where they
# were submitted from — so the COMPUTE node has to be able to read them. A
# workspace on node-local storage exists on the login node and nowhere else, and
# the failure was a raw "No such file or directory" naming neither.
if [ ! -r "$REPO_ROOT/config/util_paths.sh" ]; then
    echo "  [ERROR] Cannot read ${REPO_ROOT}/config/util_paths.sh from $(hostname 2>/dev/null || echo 'this node')." >&2
    echo "    -> The workspace must sit on a filesystem every compute node mounts (\$HOME or a shared /scratch), not node-local storage." >&2
    echo "    -> If the compute nodes see it at a different path, set DEVKIT_REPO_ROOT to that path." >&2
    exit 1
fi
source "$REPO_ROOT/config/util_paths.sh" || exit 1
devkit_require util_logging.sh
devkit_require util_sif_common.sh
LOG_PREFIX="[SLURM Job ${SLURM_JOB_ID:-local}]"
SIF_IMAGE="$1"; shift
[ -f "$SIF_IMAGE" ] || { log_error "SIF artifact not found: $SIF_IMAGE"; exit 1; }

if [ $# -eq 1 ]; then CMD=( bash -c "$1" )
elif [ $# -gt 1 ]; then CMD=( "$@" )
elif [ -n "${ROS_LAUNCH_COMMAND:-${APP_COMMAND:-}}" ]; then CMD=( bash -c "${ROS_LAUNCH_COMMAND:-$APP_COMMAND}" )
else log_error 'No job command. Pass RUN_ARGS or APP_COMMAND.'; exit 2; fi

RUNTIME="$(sif_runtime)"
sif_forward_env
sif_gpu_flags
sif_data_binds
read -r -a ENTRY <<< "$(sif_entry_args "$RUNTIME" "$SIF_IMAGE")"
[ "${#ENTRY[@]}" -gt 0 ] || { log_error 'Image has no DevKit entrypoint.'; exit 1; }
log_info "Image: $SIF_IMAGE"
log_detail "Tasks: ${SLURM_NTASKS:-1}; CPUs/task: ${SLURM_CPUS_PER_TASK:-8}"

JOB_CMD=( "$RUNTIME" exec --containall --cleanenv \
    ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} ${BIND_OPTS[@]+"${BIND_OPTS[@]}"} \
    "$SIF_IMAGE" "${ENTRY[@]}" "${CMD[@]}" )

# srun creates one process per requested task. MPI/DDP policy belongs to the app.
LAUNCH=()
if [ -n "${SLURM_JOB_ID:-}" ]; then
    command -v srun >/dev/null || { log_error 'srun is required inside a SLURM allocation.'; exit 1; }
    # SLURM assigns the devices PER TASK, so the list this script saw is the
    # job-wide one. Re-read it inside the task — forwarding the outer value gave
    # every task the full list and two tasks then fought over device 0.
    LAUNCH=( srun --kill-on-bad-exit=1 bash -c '
        if [ -n "${CUDA_VISIBLE_DEVICES+x}" ]; then
            export APPTAINERENV_CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
                   SINGULARITYENV_CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES"
        else
            unset APPTAINERENV_CUDA_VISIBLE_DEVICES SINGULARITYENV_CUDA_VISIBLE_DEVICES
        fi
        exec "$@"' devkit-task )
fi
sif_record_run "$SIF_IMAGE"
JOB_RC=0
sif_run_and_record ${LAUNCH[@]+"${LAUNCH[@]}"} "${JOB_CMD[@]}" || JOB_RC=$?
exit "$JOB_RC"

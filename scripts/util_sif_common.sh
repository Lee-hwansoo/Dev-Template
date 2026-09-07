#!/bin/bash
# =============================================================================
# scripts/util_sif_common.sh — facts the three SIF entry points must agree on.
# A library: source it. Callers (apptainer_bake, apptainer_run, slurm_run) load
# config/util_paths.sh + util_logging.sh first, so WS_ROOT and log verbs exist.
# =============================================================================

# Container runtime binary, or one clear failure. `singularity` is the pre-fork
# name most HPC sites still ship.
sif_runtime() {
    local rt
    for rt in apptainer singularity; do
        command -v "$rt" >/dev/null 2>&1 && { printf '%s' "$rt"; return 0; }
    done
    log_error "Neither apptainer nor singularity found in PATH."
    log_detail "HPC sites usually publish it as a module: 'module load apptainer'." >&2
    return 1
}

# sif_require_choice <name> <value> <allowed>…
#   One wording for an out-of-range value, so a typo reads the same whichever
#   entry point you ran. <name> is whatever the user typed — a flag (--mode) or
#   an environment variable (BAKE_FORMAT) — and is quoted back to them.
sif_require_choice() {
    local flag="$1" value="$2"; shift 2
    local allowed="$*" candidate
    # shellcheck disable=SC2086  # deliberate word split over the allowed list
    for candidate in $allowed; do
        [ "$value" = "$candidate" ] && return 0
    done
    log_error "${flag} must be one of: ${allowed} (got: '${value}')"
    return 2
}

# Project component of the SIF filename: env → .env → devkit. bake and run must
# agree or run's default probe never finds a fresh artifact.
sif_project_name() {
    local name="${COMPOSE_PROJECT_NAME:-}"
    [ -n "$name" ] || name="$(devkit_env_value COMPOSE_PROJECT_NAME)"
    printf '%s' "${name:-devkit}"
}

# sif_entry_args <runtime> <sif> — entrypoint prefix for a command, or nothing.
# `apptainer exec` skips the image ENTRYPOINT, so a bare command starts with no
# ROS/venv/GPU environment. Dev entrypoint takes `--env <cmd>`, prod execs "$@".
# Read into an array: read -r -a ENTRY <<< "$(sif_entry_args …)".
sif_entry_args() {
    local rt="$1" sif="$2"
    "$rt" exec "$sif" test -x /entrypoint.sh 2>/dev/null || return 0
    printf '/entrypoint.sh'
    "$rt" exec "$sif" grep -q '"--env"' /entrypoint.sh 2>/dev/null && printf ' --env'
    return 0
}

# sif_arch — the artifact's architecture tag, in docker's vocabulary. bake puts
# it in the filename and run probes for it, so the two must spell it the same
# way; they each had their own uname translation before.
sif_arch() {
    local arch="${TARGETARCH:-$(uname -m)}"
    case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
    printf '%s' "$arch"
}

# sif_forward_env — export the runtime knobs past `--cleanenv`. Runtime
# overrides only: the image owns its ROS/Python/toolchain versions.
sif_forward_env() {
    local v
    # OpenMP and MKL size themselves from the cores VISIBLE on the node, not the
    # cores granted: 8 allocated cpus on a 128-core node became 128 threads
    # fighting over 8, and the neighbours paid for it too. An explicit value wins.
    if [ -n "${SLURM_CPUS_PER_TASK:-}" ]; then
        : "${OMP_NUM_THREADS:=$SLURM_CPUS_PER_TASK}"
        : "${MKL_NUM_THREADS:=$SLURM_CPUS_PER_TASK}"
        export OMP_NUM_THREADS MKL_NUM_THREADS
    fi
    for v in ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_MASTER_URI ROS_HOSTNAME ROS_IP \
        ROS_LOCALHOST_ONLY CYCLONEDDS_URI FASTRTPS_DEFAULT_PROFILES_FILE \
        CUDA_VISIBLE_DEVICES OMP_NUM_THREADS MKL_NUM_THREADS \
        SLURM_JOB_ID SLURM_ARRAY_TASK_ID; do
        if [ "${!v+x}" ]; then
            export "APPTAINERENV_${v}=${!v}" "SINGULARITYENV_${v}=${!v}"
        fi
    done
    export APPTAINERENV_PYTHONUNBUFFERED=1 SINGULARITYENV_PYTHONUNBUFFERED=1
}

# sif_gpu_flags — Fills GPU_FLAGS. Inside an allocation the login node's
# hardware says nothing about the compute node's, so only an explicit request
# counts there.
sif_gpu_flags() {
    GPU_FLAGS=()
    [ "${GPU_MODE:-auto}" != cpu ] || return 0
    # amd asks for --rocm, which SLURM.md advertises; every other explicit mode
    # (igpu, intel) has no apptainer flag at all, and answering --nv for them
    # asked the runtime for hardware the job never requested.
    case "${GPU_MODE:-auto}" in
        amd)          GPU_FLAGS=(--rocm); return 0 ;;
        igpu|intel)   return 0 ;;
    esac
    if [ -n "${CUDA_VISIBLE_DEVICES:-}" ] || [ "${GPU_MODE:-}" = nvidia ]; then
        GPU_FLAGS=(--nv)
    elif [ -z "${SLURM_JOB_ID:-}" ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        GPU_FLAGS=(--nv)
    fi
}

# sif_data_binds — Fills BIND_OPTS from the SLURM_*_ROOT pair.
sif_data_binds() {
    BIND_OPTS=()
    if [ -n "${SLURM_DATA_ROOT:-}" ]; then
        [ -d "$SLURM_DATA_ROOT" ] || { log_error "Data directory not found: $SLURM_DATA_ROOT"; return 1; }
        BIND_OPTS+=(--bind "${SLURM_DATA_ROOT}:${CONTAINER_DATA_ROOT:-${WORKSPACE_PATH:-/workspace}/data}:ro")
    fi
    if [ -n "${SLURM_RUN_ROOT:-}" ]; then
        mkdir -p "$SLURM_RUN_ROOT"
        BIND_OPTS+=(--bind "${SLURM_RUN_ROOT}:${CONTAINER_RUN_ROOT:-/runs}")
    fi
}

# sif_record_run — Fills DEVKIT_RUN_RECORD with the path it wrote. Answers "what
# ran, on what hardware, against which data" for a job nobody watched.
sif_record_run() {
    # Avoid command/environment dumps: arguments may contain secrets.
    local sif="$1" root="${SLURM_RUN_ROOT:-${WS_ROOT}/logs}"
    mkdir -p "$root"
    DEVKIT_RUN_RECORD="$root/devkit-${SLURM_JOB_ID:-local}-$(date -u +%Y%m%dT%H%M%S)-$$.txt"
    # Prefer the sidecar written at bake time: hashing a multi-GB SIF on every
    # launch costs minutes for a value fixed when the artifact was created.
    (umask 077; {
        printf 'image=%s\njob=%s\narray_task=%s\nstarted=%s\n' "$sif" \
            "${SLURM_JOB_ID:-local}" "${SLURM_ARRAY_TASK_ID:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # Size detects truncation, not same-size replacements. Only a fresh
        # hash (DEVKIT_VERIFY_SIF_HASH=1) verifies the current file's identity.
        sif_bytes_now="$(wc -c < "$sif" 2>/dev/null | tr -d " " || true)"
        sif_bytes_bake="$(sed -n "s/^artifact_bytes=//p" "${sif}.provenance" 2>/dev/null || true)"
        if [ "${DEVKIT_VERIFY_SIF_HASH:-0}" != "1" ] && [ -f "${sif}.sha256" ] \
           && [ -n "$sif_bytes_bake" ] && [ "$sif_bytes_now" = "$sif_bytes_bake" ]; then
            printf 'sha256_at_bake=%s\n' "$(cut -d" " -f1 < "${sif}.sha256")"
        elif command -v sha256sum >/dev/null; then
            printf 'sha256_verified=%s\n' "$(sha256sum "$sif" | cut -d" " -f1)"
        elif command -v shasum >/dev/null; then
            printf 'sha256_verified=%s\n' "$(shasum -a 256 "$sif" | cut -d" " -f1)"
        fi
        # What the scheduler GRANTED, which is rarely what the script asked for.
        printf 'partition=%s\nnodelist=%s\nnodes=%s\nntasks=%s\ncpus_per_task=%s\nmem=%s\ngpus=%s\naccount=%s\n' \
            "${SLURM_JOB_PARTITION:-}" "${SLURM_JOB_NODELIST:-}" "${SLURM_JOB_NUM_NODES:-}" \
            "${SLURM_NTASKS:-}" "${SLURM_CPUS_PER_TASK:-}" "${SLURM_MEM_PER_NODE:-}" \
            "${SLURM_GPUS:-${CUDA_VISIBLE_DEVICES:-}}" "${SLURM_JOB_ACCOUNT:-}"
        # The OCI identity behind the SIF, written at bake time. Without it the run
        # record stops at "some SIF" and cannot reach the build that made it.
        if [ -f "${sif}.provenance" ]; then cat "${sif}.provenance"; fi
        # Which data the run saw. A VERSION file in the data root is the cheapest
        # thing a site can drop in to make "which dataset" answerable later.
        printf 'data_root=%s\ndata_version=%s\n' "${SLURM_DATA_ROOT:-}" \
            "$(head -1 "${SLURM_DATA_ROOT:-/nonexistent}/VERSION" 2>/dev/null || true)"
    } > "$DEVKIT_RUN_RECORD")
    log_detail "Run record: $DEVKIT_RUN_RECORD"
}

# sif_run_and_record <command>… — run the job as a CHILD (not exec) so the
# record can be closed with its exit status, forwarding the scheduler's signals.
# Returns the job's status.
sif_run_and_record() {
    "$@" &
    local job_pid=$! rc=0
    trap 'kill -TERM "$job_pid" 2>/dev/null || true' TERM INT HUP
    while :; do
        rc=0
        wait "$job_pid" || rc=$?
        # A trapped signal can interrupt wait before the child exits.
        kill -0 "$job_pid" 2>/dev/null || break
    done
    trap - TERM INT HUP
    sif_record_exit "$rc"
    return "$rc"
}

# sif_record_exit <rc> — close the record sif_record_run opened. Without it the
# record cannot tell "still running" from "died in the first second".
sif_record_exit() {
    [ -n "${DEVKIT_RUN_RECORD:-}" ] && [ -f "$DEVKIT_RUN_RECORD" ] || return 0
    printf 'finished=%s\nexit_status=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$DEVKIT_RUN_RECORD"
}

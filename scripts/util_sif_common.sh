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

# sif_require_choice <flag> <value> <allowed>…
#   One wording for an out-of-range flag value, so a typo reads the same
#   whichever entry point you ran.
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

# Eval check_env.sh's host facts into the caller. A CHILD process: check_env.sh
# exits on a fatal misconfiguration and would take the caller with it.
sif_import_host_env() {
    local env_out
    if env_out="$(bash "${WS_ROOT}/scripts/check_env.sh")"; then
        eval "$env_out"
        return 0
    fi
    log_error "Host environment detection failed. Run 'bash scripts/check_env.sh' to see why."
    return 1
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

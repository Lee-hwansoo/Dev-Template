#!/bin/bash
# =============================================================================
# config/util_paths.sh
# Centralized Path Management (Single Source of Truth)
# =============================================================================

# Root Workspace Path.
# WORKSPACE_PATH is the CONTAINER path (/workspace) and the Makefile exports it
# to every recipe — host-side scripts included. Honour it only when it really is
# a DevKit tree on this machine; otherwise anchor to this file's own location,
# or `make bake-prod` resolves /workspace/scripts/... and dies with
# "No such file or directory" on the host.
WS_ROOT="${WORKSPACE_PATH:-}"
[ -n "$WS_ROOT" ] && [ -f "${WS_ROOT}/config/util_paths.sh" ] \
    || WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WS_ROOT

# Core Directories
export WS_SCRIPTS="${WS_ROOT}/scripts"
export WS_CONFIG="${WS_ROOT}/config"
export WS_DEPS="${WS_ROOT}/dependencies"
export WS_INSTALL="${WS_ROOT}/install"
export WS_SRC="${WS_ROOT}/src"
export WS_BUILD="${WS_ROOT}/build"
export WS_LOGS="${WS_ROOT}/log"

# Python & Environment
# Not configurable: the image (Dockerfile ENV VIRTUAL_ENV/PATH), the compose
# install volume and docker/prod_entrypoint.sh all hardcode install/.venv, so a
# relocation knob here would move the shell half only.
export WS_VENV="${WS_INSTALL}/.venv"
# The venv interpreter, composed ONCE — five call sites spelled it themselves.
export WS_VENV_PY="${WS_VENV}/bin/python3"
export WS_CCACHE_DIR="/cache/ccache"
export WS_UV_CACHE_DIR="/cache/uv"

# devkit_env_value <key> [env_file] — the last assignment of <key> in .env,
# with the quotes and CR compose tolerates stripped. READ, never source: .env is
# data, not code, and make's `export` does not reach $(shell …), so every caller
# that needs a value before compose runs has to read the file itself.
devkit_env_value() {
    local key="$1" file="${2:-${WS_ROOT}/.env}"
    [ -f "$file" ] || return 0
    sed -n "s/^[[:space:]]*${key}=//p" "$file" | tail -n 1 | tr -d '"'"'"'\r'
}

configure_git_safe_directory() {
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="safe.directory"
    export GIT_CONFIG_VALUE_0="*"
}

# devkit_require [script_name] [force_reload:optional]
#   Locates and sources a script cleanly from WS_SCRIPTS or caller directory.
#   Idempotency protection via variable-name flags.
devkit_require() {
    local script_name="$1"
    local force_reload="${2:-false}"
    local sanitize_name
    sanitize_name="$(echo "$script_name" | tr -c 'a-zA-Z0-9_' '_')"
    local flag_var="__DEVKIT_LOADED_${sanitize_name}"

    if [ "${!flag_var:-}" = "true" ] && [ "$force_reload" != "true" ]; then
        return 0
    fi

    local target_path="${WS_SCRIPTS}/${script_name}"
    if [ ! -f "$target_path" ]; then
        local caller_dir
        caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-.}")" && pwd 2>/dev/null || true)"
        target_path="${caller_dir}/${script_name}"
    fi

    if [ -f "$target_path" ]; then
        source "$target_path"
        eval "${flag_var}=true"
        return 0
    fi

    echo -e "\033[0;31m[DEVKIT-FATAL]\033[0m Failed to require script '$script_name' at '$target_path'" >&2
    return 1
}

# Default logging stubs (overridden when util_logging.sh is loaded)
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()       { echo "[INFO] $*"; }
    log_ok()         { echo "[OK] $*"; }
    log_warn()       { echo "[WARN] $*" >&2; }
    log_error()      { echo "[ERROR] $*" >&2; }
    log_detail()     { echo "  -> $*"; }
    print_section()  { echo "[ $* ]"; }
    log_step_done()  { echo "[OK] $*"; }
    _log_plain()     { return 0; }
fi

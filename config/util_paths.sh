#!/bin/bash
# =============================================================================
# config/util_paths.sh — every workspace path, composed once, plus the .env
# reader and the `devkit_require` loader. Provided API: a name with no in-tree
# caller is a feature, and check [provided-api] keeps the set callable.
# =============================================================================

# WORKSPACE_PATH is the CONTAINER path and make exports it to host recipes too,
# so honour it only when it really is a DevKit tree here; otherwise anchor to
# this file. Without that guard `make bake-prod` resolved /workspace/scripts.
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

# Not configurable: the image ENV, the compose install volume and
# prod_entrypoint.sh all hardcode install/.venv — a knob here moves one half.
export WS_VENV="${WS_INSTALL}/.venv"
# The venv interpreter, composed ONCE — five call sites spelled it themselves.
export WS_VENV_PY="${WS_VENV}/bin/python3"
export WS_CCACHE_DIR="/cache/ccache"
export WS_UV_CACHE_DIR="/cache/uv"

# devkit_env_value <key> [env_file] — the last assignment of <key> in .env,
# with the quotes and CR compose tolerates stripped. READ, never source: .env is
# data, not code, and make's `export` does not reach $(shell …), so every caller
# that needs a value before compose runs has to read the file itself.
# devkit_resolve_path <path> — absolute, with '..' and symlinks resolved. Used
# before anything destructive: a string test let '<ws>/cache/../../<ws>' pass a
# "must contain cache" guard and reach `rm -rf` on the workspace itself.
# No `realpath -m` / `readlink -f`: macOS ships neither in a usable form, so the
# deepest EXISTING directory is resolved physically and the missing tail
# appended.
devkit_resolve_path() {
    local path="$1" probe tail="" out comp
    [ -n "$path" ] || return 1
    case "$path" in /*) ;; *) path="${PWD}/${path}" ;; esac
    # Deepest EXISTING directory, resolved physically (symlinks and all)…
    probe="$path"
    while [ ! -d "$probe" ] && [ "$probe" != / ]; do
        tail="${probe##*/}${tail:+/$tail}"
        probe="${probe%/*}"; [ -n "$probe" ] || probe=/
    done
    out="$(cd "$probe" 2>/dev/null && pwd -P)" || return 1
    # …then fold what is left. '..' has to be popped here: the components below
    # may not exist, so the kernel cannot resolve them and a lexical pass is the
    # only way '<ws>/src/thirdparty/../../../outside' stops looking internal.
    while [ -n "$tail" ]; do
        comp="${tail%%/*}"
        case "$tail" in */*) tail="${tail#*/}" ;; *) tail="" ;; esac
        case "$comp" in
            ''|.) ;;
            ..)   out="${out%/*}"; [ -n "$out" ] || out=/ ;;
            *)    out="${out%/}/${comp}" ;;
        esac
    done
    printf '%s' "$out"
}

# devkit_is_true <value> — the one spelling of truth for destructive guards.
# `FORCE=0` and `CI=false` are answers, not absence, and a presence test read
# them as "yes".
devkit_is_true() {
    case "$1" in 1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;; *) return 1 ;; esac
}

devkit_env_value() {
    local key="$1" file="${2:-${WS_ROOT}/.env}"
    [ -f "$file" ] || return 0
    sed -n "s/^[[:space:]]*${key}=//p" "$file" | tail -n 1 | tr -d '"'"'"'\r'
}

configure_git_safe_directory() {
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="safe.directory"
    export GIT_CONFIG_VALUE_0="${WS_ROOT}"
}

# devkit_require <script> [force_reload] — source once from WS_SCRIPTS or the
# caller's directory.
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

# Colourless fallbacks, used until util_logging.sh loads. _log_plain answers
# "yes" so callers that branch on it match these stubs.
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

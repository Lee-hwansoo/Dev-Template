#!/bin/bash
# =============================================================================
# docker/entrypoint.sh
# DevKit Container Runtime Entrypoint
# =============================================================================
set -eE

export LANG=${LANG:-C.UTF-8}
export LC_ALL="$LANG" LANGUAGE="$LANG"

# Git: suppress "dubious ownership" errors without mutating global config
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="*"

WS_ROOT="${WORKSPACE_PATH:-/workspace}"

# =============================================================================
# Exec-wrapper mode:  /entrypoint.sh --env <command> [args...]
# -----------------------------------------------------------------------------
# Shell rc hooks (BASH_ENV, /etc/bash.bashrc, profile.d) only reach *bash*.
# A `docker exec` of a bare binary, a `sh -c`, a compose `command:` or a k8s
# probe never touches them and would run without the DevKit environment.
#
# This mode loads the environment the boot sequence already resolved and execs
# the target directly, so ANY process — not just bash — inherits it. It performs
# no setup (no chown, no GPU probing): the container is already running.
# =============================================================================
if [ "${1:-}" = "--env" ]; then
    shift
    [ $# -gt 0 ] || { echo "usage: /entrypoint.sh --env <command> [args...]" >&2; exit 2; }
    for _f in /etc/profile.d/devkit-*.sh; do
        # shellcheck source=/dev/null
        [ -r "$_f" ] && . "$_f"
    done
    unset _f
    # shellcheck source=/dev/null
    [ -r "${WS_ROOT}/config/init_bash.sh" ] && . "${WS_ROOT}/config/init_bash.sh"
    exec "$@"
fi

source "${WS_ROOT}/config/util_paths.sh"  2>/dev/null || true
source "${WS_ROOT}/scripts/util_logging.sh" 2>/dev/null || true

# Persist boot logs for post-mortem debugging: `docker logs` dies with the
# container, the file survives in the log/ volume. The LOG_FILE knob still wins.
# Not exported: this is the ENTRYPOINT's log — user shells and tools must not
# inherit it and interleave their output into it.
# Truncate past 1 MB — the file accretes across every container start.
LOG_FILE="${LOG_FILE:-log/entrypoint.log}"
# Boot lines land in `docker logs` beside the application's own output, so they
# say who is speaking. Not exported: a user shell must not inherit the tag.
LOG_PREFIX="[Entrypoint]"
# The workspace-relative rule lives in util_logging.sh; ask it rather than
# resolving the path a second time and truncating the wrong file one day.
if declare -F _log_resolve_file >/dev/null 2>&1; then
    _log_resolve_file
    { [ "$(stat -c %s "${__DEVKIT_LOG_PATH:-}" 2>/dev/null || echo 0)" -gt 1048576 ] \
        && : > "${__DEVKIT_LOG_PATH}"; } 2>/dev/null || true
fi

# Fallback loggers if util_logging.sh not available
declare -F log_info  >/dev/null 2>&1 || log_info()  { echo "  [INFO] $*"; }
declare -F log_ok    >/dev/null 2>&1 || log_ok()    { echo "  [OK]   $*"; }
declare -F log_warn  >/dev/null 2>&1 || log_warn()  { echo "  [WARN] $*" >&2; }
declare -F log_error >/dev/null 2>&1 || log_error() { echo "  [ERROR] $*" >&2; }

trap 'ec=$?; log_error "Entrypoint aborted (exit ${ec}) at line ${LINENO}: ${BASH_COMMAND}"' ERR

# source_runtime_file: source without aborting on unbound vars or non-zero returns
source_runtime_file() {
    local file="$1"; shift
    [ -f "$file" ] || return 0
    local _had_e=0 _had_u=0 _rc=0
    case "$-" in *e*) _had_e=1 ;; esac
    case "$-" in *u*) _had_u=1 ;; esac
    set +eu
    # shellcheck source=/dev/null
    source "$file" "$@"; _rc=$?
    [ "$_had_e" = 1 ] && set -e
    [ "$_had_u" = 1 ] && set -u
    return "$_rc"
}

# sync_owner_if_root: chown path to CONTAINER_USER when running as root.
# Fast-path: skip if target already owns the entry (avoids slow recursive chown on re-runs).
sync_owner_if_root() {
    local path="$1"
    [ "$(id -u)" = "0" ] || return 0
    [ -n "${CONTAINER_USER:-}" ] || return 0
    [ "${CONTAINER_USER}" != "root" ] || return 0
    [ -e "$path" ] || return 0
    local target_uid
    target_uid="$(id -u "${CONTAINER_USER}" 2>/dev/null || true)"
    [ -n "$target_uid" ] && [ "$(stat -c %u "$path" 2>/dev/null)" = "$target_uid" ] && return 0
    chown -R "${CONTAINER_USER}:${CONTAINER_USER}" "$path" 2>/dev/null \
        || log_warn "Could not synchronize ownership: $path"
}

# bridge_profile_d: make /etc/profile.d/devkit-*.sh reach every shell flavour.
# Bash consults a different file per invocation mode, and none of them overlap:
#   login            → /etc/profile → /etc/profile.d/*      (already covered)
#   interactive      → /etc/bash.bashrc                     (appended below)
#   non-interactive  → $BASH_ENV                            (file written below)
# The image points BASH_ENV at this generated file rather than ~/.bashrc,
# because Ubuntu's stock ~/.bashrc returns early when not interactive, which
# silently discards everything appended after it (init_bash.sh included).
DEVKIT_SHELL_ENV="/etc/devkit/shell-env.sh"
bridge_profile_d() {
    # One definition for every shell flavour: the entrypoint-resolved values in
    # profile.d first, then config/init_bash.sh which derives the rest (ROS,
    # venv, paths). init_bash.sh is idempotent, so re-sourcing costs nothing.
    local loader='for __devkit_env in /etc/profile.d/devkit-*.sh; do
    [ -r "$__devkit_env" ] && . "$__devkit_env"
done; unset __devkit_env
[ -r "${WORKSPACE_PATH:-/workspace}/config/init_bash.sh" ] && . "${WORKSPACE_PATH:-/workspace}/config/init_bash.sh"'

    if mkdir -p "$(dirname "$DEVKIT_SHELL_ENV")" 2>/dev/null; then
        { echo "# Generated by docker/entrypoint.sh — BASH_ENV hook for non-interactive shells"
          echo "$loader"; } > "$DEVKIT_SHELL_ENV" 2>/dev/null || true
        chmod 644 "$DEVKIT_SHELL_ENV" 2>/dev/null || true
    fi

    local target="/etc/bash.bashrc"
    [ -w "$target" ] || return 0
    grep -q '__DEVKIT_ENV_BRIDGE' "$target" 2>/dev/null && return 0
    { echo ""; echo "# __DEVKIT_ENV_BRIDGE (generated by docker/entrypoint.sh)"; echo "$loader"; } >> "$target"
}

# setup_xdg_runtime: resolve XDG_RUNTIME_DIR, proxying for WSL2 UID mismatch
setup_xdg_runtime() {
    local xdg_dir="${XDG_RUNTIME_DIR:-/tmp/.container_xdg}"
    local target_uid
    target_uid="$(id -u "${CONTAINER_USER:-${USER:-root}}" 2>/dev/null || id -u)"
    if [ -d "$xdg_dir" ] && [ "$(stat -c %u "$xdg_dir" 2>/dev/null)" != "$target_uid" ]; then
        local proxy="/tmp/runtime-${target_uid}-$(hostname 2>/dev/null || echo default)"
        mkdir -p "$proxy" && chmod 700 "$proxy"
        sync_owner_if_root "$proxy"
        find "$proxy" -maxdepth 1 -type l -exec rm -f {} +
        find "$xdg_dir" -maxdepth 1 -not -path "$xdg_dir" -exec ln -sf {} "$proxy/" 2>/dev/null \;
        echo "$proxy"
    else
        if [ ! -d "$xdg_dir" ]; then
            mkdir -p "$xdg_dir" && chmod 700 "$xdg_dir"
            sync_owner_if_root "$xdg_dir"
        fi
        echo "$xdg_dir"
    fi
}

verify_x11() {
    [ -z "${DISPLAY:-}" ] && return
    local num="${DISPLAY#:}"; num="${num%%.*}"
    if [ -S "/tmp/.X11-unix/X${num}" ]; then
        log_ok "X11 display ${DISPLAY} verified"
    else
        log_warn "DISPLAY=${DISPLAY} set but X11 socket not found."
    fi
    local xauth="${XAUTHORITY:-$HOME/.Xauthority}"
    if [ -s "$xauth" ]; then
        export XAUTHORITY="$xauth"
        log_ok "Xauthority verified: $xauth"
    else
        # An empty cookie is normal on WSLg/XWayland, which authorises local
        # clients through xhost — telling the user to run `make xauth` there
        # would send them after a file that is never going to be populated.
        if [ -S "/tmp/.X11-unix/X${num}" ]; then
            log_info "No X11 cookie ($xauth); relying on host xhost authorisation (normal on WSLg)."
        else
            log_warn "Xauthority missing or empty ($xauth). GUI may fail. Run: make xauth"
        fi
    fi
}

setup_wayland() {
    [ -z "${WAYLAND_DISPLAY:-}" ] && return
    export QT_QPA_PLATFORM="wayland;xcb"
    export GDK_BACKEND="wayland,x11"
    log_ok "Wayland display ${WAYLAND_DISPLAY}: GUI vars initialized"
}

# Clean up empty env vars injected by Docker Compose V2
for _var in ROS_IP WAYLAND_DISPLAY HOST_WAYLAND_DISPLAY; do
    [ -n "${!_var+x}" ] && [ -z "${!_var}" ] && unset "$_var"
done
unset _var

# =============================================================================
# [1] Cache Directories & Ownership
# =============================================================================
# log/ is a named volume too: Docker creates it root:root on first use and the
# first colcon build as CONTAINER_USER would fail. devel/ (ROS 1) is a plain
# workspace dir catkin creates; covered here for the same ownership reason.
mkdir -p /cache/ccache /cache/uv "${WS_ROOT}/build" "${WS_ROOT}/install" "${WS_ROOT}/log" 2>/dev/null || true
for _dir in /cache/ccache /cache/uv "${WS_ROOT}/build" "${WS_ROOT}/install" "${WS_ROOT}/log" "${WS_ROOT}/devel"; do
    sync_owner_if_root "$_dir"
done
unset _dir

# =============================================================================
# [2] Display & GUI (X11 / Wayland / XDG)
# =============================================================================
bridge_profile_d
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export XDG_RUNTIME_DIR="$(setup_xdg_runtime)"
    if [ -w /etc/profile.d ]; then
        printf 'export XDG_RUNTIME_DIR=%q\n' "${XDG_RUNTIME_DIR}" > /etc/profile.d/devkit-xdg.sh
        chmod 644 /etc/profile.d/devkit-xdg.sh
    fi
    verify_x11
    setup_wayland
else
    log_warn "No DISPLAY or WAYLAND_DISPLAY — GUI apps will not work."
fi

# =============================================================================
# [3] GPU Acceleration
# =============================================================================
GPU_SETUP="${WS_ROOT}/scripts/setup_gpu.sh"
if [ -f "$GPU_SETUP" ]; then
    if ! source_runtime_file "$GPU_SETUP" "${GPU_MODE:-auto}"; then
        log_warn "GPU setup failed for GPU_MODE=${GPU_MODE:-auto}. Falling back to software rendering."
        source_runtime_file "$GPU_SETUP" cpu \
            || log_warn "Software GPU fallback also failed; continuing without GPU env."
    fi
    # Persist GPU env for 'docker exec' non-interactive sessions
    if [ -f "$HOME/.gpu_env.sh" ] && [ -w /etc/profile.d ]; then
        cp "$HOME/.gpu_env.sh" /etc/profile.d/devkit-gpu.sh
        chmod 644 /etc/profile.d/devkit-gpu.sh
    fi
fi

# =============================================================================
# [4] ROS & Workspace Environment Sourcing
# =============================================================================
# source_runtime_file returns 0 for a missing file, so gate the success log on
# actual existence — a non-ROS image must not claim "ROS sourced".
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
if [ -f "$ROS_SETUP" ]; then
    source_runtime_file "$ROS_SETUP" && log_ok "ROS ${ROS_DISTRO:-humble} sourced"
fi
if [ -f "${WS_ROOT}/install/setup.bash" ]; then
    source_runtime_file "${WS_ROOT}/install/setup.bash" 2>/dev/null && log_ok "Workspace overlay sourced" || true
fi
source_runtime_file "${WS_ROOT}/config/init_ros_env.sh" 2>/dev/null || true

# Persist the ROS/DDS settings resolved above. init_ros_env.sh is only reached
# through ~/.bashrc, i.e. interactive shells — without this, a `docker exec`
# script or CI job runs with no CYCLONEDDS_URI and silently uses a different
# DDS configuration than the interactive session it was tested in.
# Only when ROS is actually installed: ROS_DISTRO is passed to every service
# by compose, so its presence alone does not mean this image has ROS.
if [ -w /etc/profile.d ] && [ -d "/opt/ros/${ROS_DISTRO:-}" ]; then
    {
        echo "# Generated by docker/entrypoint.sh — do not edit"
        for _rv in ROS_DOMAIN_ID RMW_IMPLEMENTATION CYCLONEDDS_URI \
                   FASTRTPS_DEFAULT_PROFILES_FILE ROS_LOCALHOST_ONLY \
                   ROS_HOSTNAME ROS_MASTER_URI ROS_IP; do
            [ -n "${!_rv:-}" ] && printf 'export %s=%q\n' "$_rv" "${!_rv}"
        done
        unset _rv
    } > /etc/profile.d/devkit-ros.sh 2>/dev/null || true
    chmod 644 /etc/profile.d/devkit-ros.sh 2>/dev/null || true
fi
source_runtime_file "${WS_VENV:-${WS_ROOT}/install/.venv}/bin/activate" 2>/dev/null || true

# =============================================================================
# [5] rosdep cache seeding
# -----------------------------------------------------------------------------
# The image builds the rosdep sources cache as root and stages it at
# /opt/ros_cache. Without this seeding step every non-root shell hits
# "your rosdep installation has not been initialized yet" and `mksync` fails —
# which is the default path now that shells run as CONTAINER_USER.
# =============================================================================
seed_rosdep_cache() {
    [ -d /opt/ros_cache ] || return 0
    local target_home="$HOME"
    if [ "$(id -u)" = "0" ] && [ -n "${CONTAINER_USER:-}" ] && [ "${CONTAINER_USER}" != "root" ]; then
        target_home="$(getent passwd "${CONTAINER_USER}" 2>/dev/null | cut -d: -f6)"
    fi
    [ -n "$target_home" ] && [ -d "$target_home" ] || return 0
    [ -d "${target_home}/.ros/rosdep" ] && return 0
    mkdir -p "${target_home}/.ros" 2>/dev/null || return 0
    cp -a /opt/ros_cache/. "${target_home}/.ros/" 2>/dev/null || true
    sync_owner_if_root "${target_home}/.ros"
    log_ok "rosdep cache seeded for ${CONTAINER_USER:-$(id -un)}"
}
seed_rosdep_cache

# =============================================================================
# [6] Auto Dependency Sync (first-run only)
# =============================================================================
SYNC_DEPS="${WS_ROOT}/scripts/setup_sync_deps.sh"
THIRD_PARTY="${WS_ROOT}/src/thirdparty"
REPOS_FILE="${WS_ROOT}/dependencies/dependencies.repos"
# Grouping matters: the sync runs only when both inputs exist AND the target is
# still unpopulated. Without the parentheses the `||` binds the whole chain and
# the (slow, network-bound) sync fires on every container start.
if [ -f "$REPOS_FILE" ] && [ -f "$SYNC_DEPS" ] && \
   { [ ! -d "$THIRD_PARTY" ] || \
     [ -z "$(find "$THIRD_PARTY" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; } && \
   grep -qE '^[[:space:]]{2,}[^[:space:]#]' "$REPOS_FILE" 2>/dev/null; then
    log_info "First-run: syncing dependencies..."
    bash "$SYNC_DEPS" || log_warn "Dependency sync failed. Re-run with: sync_deps"
fi

# =============================================================================
# [7] Execute (with privilege drop if CONTAINER_USER set)
# =============================================================================
if [ "$(id -u)" = "0" ] && [ -n "${CONTAINER_USER:-}" ] && [ "${CONTAINER_USER}" != "root" ]; then
    log_ok "Dropping privileges → '${CONTAINER_USER}'"
    user_uid="$(id -u "${CONTAINER_USER}")"
    user_gid="$(id -g "${CONTAINER_USER}")"
    runtime_env=(
        "HOME=$(getent passwd "${CONTAINER_USER}" 2>/dev/null | cut -d: -f6)"
        "USER=${CONTAINER_USER}" "LOGNAME=${CONTAINER_USER}"
        "PATH=$PATH" "WORKSPACE_PATH=$WS_ROOT"
        "LANG=$LANG" "LC_ALL=$LC_ALL" "LANGUAGE=$LANGUAGE"
        "VIRTUAL_ENV=${VIRTUAL_ENV:-}" "DISPLAY=${DISPLAY:-}"
        "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" "XAUTHORITY=${XAUTHORITY:-}"
        "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" "QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}"
        "GDK_BACKEND=${GDK_BACKEND:-}" "QT_X11_NO_MITSHM=${QT_X11_NO_MITSHM:-}"
        "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-}"
        "ROS_DISTRO=${ROS_DISTRO:-}" "ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-}"
        "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-}" "ROS_MASTER_URI=${ROS_MASTER_URI:-}"
        "ROS_HOSTNAME=${ROS_HOSTNAME:-}" "ROS_IP=${ROS_IP:-}"
        "GPU_MODE=${GPU_MODE:-}" "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-}"
        "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-}"
        "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}" "PYTHONPATH=${PYTHONPATH:-}"
    )
    if command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid "$user_uid" --regid "$user_gid" --init-groups env "${runtime_env[@]}" "$@"
    fi
    exec sudo -E -u "${CONTAINER_USER}" env "${runtime_env[@]}" "$@"
else
    exec "$@"
fi

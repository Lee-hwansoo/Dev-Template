#!/bin/bash
# =============================================================================
# Production entrypoint for Apptainer/Docker runtime artifacts
# =============================================================================

set -euo pipefail

WS_ROOT="${WORKSPACE_PATH:-/workspace}"
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
INSTALL_SETUP="${WS_ROOT}/install/setup.bash"
VENV_ACTIVATE="${WS_ROOT}/install/.venv/bin/activate"

export WORKSPACE_PATH="$WS_ROOT"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-${LANG}}"
export PATH="${WS_ROOT}/install/.venv/bin:${WS_ROOT}/install/bin:${PATH}"
export VIRTUAL_ENV="${WS_ROOT}/install/.venv"

source_runtime_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    # Save and restore shell options to safely source files that may reference
    # unbound variables (e.g. ROS setup.bash) without permanently altering flags.
    local _saved_opts
    _saved_opts="$(set +o)"
    set +eu
    # shellcheck source=/dev/null
    source "$file"
    eval "$_saved_opts"
}

source_runtime_file "$ROS_SETUP"
source_runtime_file "$INSTALL_SETUP"
source_runtime_file "$VENV_ACTIVATE"
source_runtime_file "/etc/profile.d/devkit-gpu.sh"

if [ -d "$WS_ROOT" ]; then
    cd "$WS_ROOT"
else
    echo "  [ERROR] Workspace path does not exist: $WS_ROOT" >&2
    exit 1
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

if [ -n "${ROS_LAUNCH_COMMAND:-}" ]; then
    exec bash -lc "$ROS_LAUNCH_COMMAND"
fi

if [ -n "${APP_COMMAND:-}" ]; then
    exec bash -lc "$APP_COMMAND"
fi

echo "  [ERROR] No production command configured. Set ROS_LAUNCH_COMMAND, APP_COMMAND, or pass an explicit command after the image." >&2
exit 2

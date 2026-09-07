# =============================================================================
# config/init_bash.sh — the single definition of a DevKit shell environment.
# Sourced by every shell flavour: login (~/.bashrc), interactive
# (/etc/bash.bashrc), non-interactive ($BASH_ENV). Everything above the
# "Interactive-only" section must be safe without a terminal: no output.
# =============================================================================

WS_ROOT="${WORKSPACE_PATH:-/workspace}"

# BASH_ENV fires for every non-interactive bash. The exported marker lets an
# ancestor that already resolved this workspace short-circuit its descendants.
if [ "${__DEVKIT_ENV_READY:-}" != "$WS_ROOT" ]; then

    UTIL_PATHS="${WS_ROOT}/config/util_paths.sh"
    [ -f "$UTIL_PATHS" ] && source "$UTIL_PATHS"

    # UTF-8 for the banners and emoji
    export LANG=${LANG:-C.UTF-8}
    export LC_ALL="$LANG" LANGUAGE="$LANG"

    # Silence AT-SPI warnings from GUI apps (Terminator)
    export NO_AT_BRIDGE=1

    # git "dubious ownership" in Docker/WSL2, without touching system config
    if declare -f configure_git_safe_directory >/dev/null 2>&1; then
        configure_git_safe_directory
    else
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="safe.directory"
        export GIT_CONFIG_VALUE_0="$WS_ROOT"
    fi

    # ccache — guard against PATH growing on every re-source
    case ":${PATH}:" in
        *":/usr/lib/ccache:"*) ;;
        *) export PATH="/usr/lib/ccache:$PATH" ;;
    esac
    export CCACHE_DIR="${WS_CCACHE_DIR:-/cache/ccache}"

    # uv (Python)
    export UV_CACHE_DIR="${WS_UV_CACHE_DIR:-/cache/uv}"
    export UV_PYTHON=${UV_PYTHON:-3.10}
    DEVKIT_VENV="${WS_VENV:-${WS_ROOT}/install/.venv}"
    export UV_PROJECT_ENVIRONMENT="$DEVKIT_VENV"

    # C/C++ Standard
    export CMAKE_C_STANDARD=${CMAKE_C_STANDARD:-11}
    export CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}

    # ROS (1 and 2). setup.bash is not idempotent-cheap: skip when an ancestor
    # already sourced it.
    if [ -z "${AMENT_PREFIX_PATH:-}${ROS_PACKAGE_PATH:-}" ] \
       && [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
        source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
    fi

    # Workspace overlay: install/ after colcon, devel/ after a ROS 1 dev build.
    __devkit_overlay="$(devkit_overlay_setup 2>/dev/null)" \
        && source "$__devkit_overlay"
    unset __devkit_overlay

    # ROS version-specific configuration (RMW, domain, CYCLONEDDS_URI)
    ROS_ENV_INIT="${WS_CONFIG:-${WS_ROOT}/config}/init_ros_env.sh"
    [ -f "$ROS_ENV_INIT" ] && source "$ROS_ENV_INIT"

    # Activate the venv, skipping only a FOREIGN one: the image pre-sets
    # VIRTUAL_ENV to this very venv, so a plain -z guard never activated.
    if [ -f "${DEVKIT_VENV}/bin/activate" ] \
       && { [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV}" = "${DEVKIT_VENV}" ]; }; then
        source "${DEVKIT_VENV}/bin/activate"
        devkit_venv_prompt
    fi

    # GPU environment (after ROS, to keep LD_LIBRARY_PATH priority)
    [ -f "${HOME}/.gpu_env.sh" ] && source "${HOME}/.gpu_env.sh"

    export __DEVKIT_ENV_READY="$WS_ROOT"
fi

# `make exec CMD='h'` and `bash -lc sync_deps` are the advertised automation
# path, and bash expands aliases only in interactive shells unless asked: every
# alias-shaped shortcut answered "command not found" there.
shopt -s expand_aliases 2>/dev/null || true

# Functions live PER PROCESS, so this stays outside the guard above: a child
# shell inherits the marker but not the definitions.
declare -F mksync >/dev/null 2>&1 \
    || { [ -f "${WS_CONFIG:-${WS_ROOT}/config}/util_aliases.sh" ] \
         && source "${WS_CONFIG:-${WS_ROOT}/config}/util_aliases.sh"; }

# =============================================================================
# Interactive-only: prompt, completion, links, MOTD. Never in a scripted shell.
# =============================================================================
case $- in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# The venv marker belongs HERE: activation happened above, so activate's own
# PS1 prefix would be overwritten, and re-running it would stack a second one.
export VIRTUAL_ENV_DISABLE_PROMPT=1
export PS1="\${VIRTUAL_ENV_PROMPT:+\[\033[01;36m\](\${VIRTUAL_ENV_PROMPT}) \[\033[00m\]}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

[ -f "${WS_CONFIG}/devkit_make_completion.bash" ] && source "${WS_CONFIG}/devkit_make_completion.bash"
[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ] \
    && source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash

# Workspace symlinks — a filesystem side effect, so not in scripted shells
[ -x "${WS_SCRIPTS}/util_setup_links.sh" ] && "${WS_SCRIPTS}/util_setup_links.sh" --skip-compile-commands

# MOTD: once per login, and only for a human. `-t 0` as well as the marker —
# `docker exec … bash -ic '<cmd>'` is interactive but has no terminal.
if [ -t 0 ] && [ -z "${__DEVKIT_MOTD_SHOWN:-}" ] && [ -f "${WS_SCRIPTS}/show_welcome.sh" ]; then
    export __DEVKIT_MOTD_SHOWN=1
    bash "${WS_SCRIPTS}/show_welcome.sh"
fi

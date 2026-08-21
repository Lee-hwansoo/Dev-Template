# =============================================================================
# config/init_bash.sh — the single definition of a DevKit shell environment.
#
# Sourced by EVERY shell flavour:
#   login            → ~/.profile → ~/.bashrc (Dockerfile appends the source)
#   interactive      → /etc/bash.bashrc (entrypoint bridges /etc/devkit/shell-env.sh)
#   non-interactive  → $BASH_ENV = /etc/devkit/shell-env.sh
#
# Everything above the "Interactive-only" section must therefore be safe to run
# without a terminal: no prompts, no banners, no output. Interactive extras
# (prompt, MOTD, completion) live in the guarded section at the bottom, so a
# `docker exec … bash -c 'python3 node.py'` gets exactly the same environment a
# developer sees — only quieter.
# =============================================================================

WS_ROOT="${WORKSPACE_PATH:-/workspace}"

# Idempotency: BASH_ENV fires for every non-interactive bash, including the ones
# scripts spawn in loops. Re-sourcing ROS/venv setup each time would tax every
# subshell, so an ancestor that already resolved this workspace short-circuits
# its descendants (the marker is exported and therefore inherited).
if [ "${__DEVKIT_ENV_READY:-}" != "$WS_ROOT" ]; then

    UTIL_PATHS="${WS_ROOT}/config/util_paths.sh"
    [ -f "$UTIL_PATHS" ] && source "$UTIL_PATHS"

    # Force UTF-8 locale for terminal emoji and ASCII art support
    export LANG=${LANG:-C.UTF-8}
    export LC_ALL="$LANG" LANGUAGE="$LANG"

    # Suppress AT-SPI accessibility bus warnings in GUI applications (like Terminator)
    export NO_AT_BRIDGE=1

    # Fix for "detected dubious ownership" git error in Docker/WSL2 without mutating system config.
    if declare -f configure_git_safe_directory >/dev/null 2>&1; then
        configure_git_safe_directory
    else
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="safe.directory"
        export GIT_CONFIG_VALUE_0="*"
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

    # =========================================================================
    # ROS Environment (Common for ROS1 & ROS2)
    # =========================================================================
    # setup.bash is not idempotent-cheap; skip when an ancestor already sourced it.
    if [ -z "${AMENT_PREFIX_PATH:-}${ROS_PACKAGE_PATH:-}" ] \
       && [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
        source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
    fi

    # Workspace overlay (present after a colcon build)
    if [ -f "${WS_INSTALL:-${WS_ROOT}/install}/setup.bash" ]; then
        source "${WS_INSTALL:-${WS_ROOT}/install}/setup.bash"
    fi

    # ROS version-specific configuration (RMW, domain, CYCLONEDDS_URI)
    ROS_ENV_INIT="${WS_CONFIG:-${WS_ROOT}/config}/init_ros_env.sh"
    [ -f "$ROS_ENV_INIT" ] && source "$ROS_ENV_INIT"

    # Auto-activate the uv virtualenv. Skip ONLY when a foreign venv is active:
    # the image pre-sets VIRTUAL_ENV to this very venv (Dockerfile ENV), so a
    # plain `[ -z "$VIRTUAL_ENV" ]` guard skipped activation in every container
    # shell — no `deactivate`, no prompt marker, PATH working only by accident.
    if [ -f "${DEVKIT_VENV}/bin/activate" ] \
       && { [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV}" = "${DEVKIT_VENV}" ]; }; then
        source "${DEVKIT_VENV}/bin/activate"
        # uv reports the bare name, CPython's activate reports "(name) ": strip
        # the decoration so the prompt below renders exactly one pair of parens.
        VIRTUAL_ENV_PROMPT="${VIRTUAL_ENV_PROMPT#\(}"; VIRTUAL_ENV_PROMPT="${VIRTUAL_ENV_PROMPT%\) }"
    fi

    # GPU environment (after ROS, to keep LD_LIBRARY_PATH priority)
    [ -f "${HOME}/.gpu_env.sh" ] && source "${HOME}/.gpu_env.sh"

    export __DEVKIT_ENV_READY="$WS_ROOT"
fi

# Shell functions (cbuild/mbuild/mksync/…) are useful in scripts too, and they
# live PER PROCESS: a child shell inherits the environment but not the
# definitions, so this runs outside the guard above — otherwise
# `make exec CMD='mksync'` reaches a shell where the marker matches and nothing
# is defined. `declare -F` is a builtin, so the skip costs no fork.
declare -F mksync >/dev/null 2>&1 \
    || { [ -f "${WS_CONFIG:-${WS_ROOT}/config}/util_aliases.sh" ] \
         && source "${WS_CONFIG:-${WS_ROOT}/config}/util_aliases.sh"; }

# =============================================================================
# Interactive-only: prompt, completion, workspace links and the MOTD.
# These either write to the terminal or only make sense at a prompt, and must
# never run in a scripted shell.
# =============================================================================
case $- in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# The venv marker is rendered HERE, not by bin/activate: the environment is
# activated above (before this line), so activate's own PS1 prefix would be
# overwritten — and re-running `activate` would stack a second one. PS1 is
# re-expanded at every prompt, so ${VIRTUAL_ENV_PROMPT} tracks the live venv.
export VIRTUAL_ENV_DISABLE_PROMPT=1
export PS1="\${VIRTUAL_ENV_PROMPT:+\[\033[01;36m\](\${VIRTUAL_ENV_PROMPT}) \[\033[00m\]}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

[ -f "${WS_CONFIG}/devkit_make_completion.bash" ] && source "${WS_CONFIG}/devkit_make_completion.bash"
[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ] \
    && source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash

# Workspace symlinks (compile_commands.json etc.) — a filesystem side effect, so
# it stays out of scripted shells.
[ -x "${WS_SCRIPTS}/util_setup_links.sh" ] && "${WS_SCRIPTS}/util_setup_links.sh" --skip-compile-commands

# Welcome banner — only for a human at a prompt, and only once per login.
# `[ -t 0 ]` as well as the marker: a scripted `docker exec … bash -ic '<cmd>'`
# is interactive but has no terminal, and every such call reprinted the whole
# banner over the command's own output.
if [ -t 0 ] && [ -z "${__DEVKIT_MOTD_SHOWN:-}" ] && [ -f "${WS_SCRIPTS}/show_welcome.sh" ]; then
    export __DEVKIT_MOTD_SHOWN=1
    bash "${WS_SCRIPTS}/show_welcome.sh"
fi

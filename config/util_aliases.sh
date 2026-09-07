#!/bin/bash
# =============================================================================
# config/util_aliases.sh — the in-container shortcuts (ROS 1/2, uv, CMake).
# Sourced into the user's shell, so `h` lists what this file provides and the
# build entry points are FUNCTIONS: aliases never expand in a docker build.
# =============================================================================

source "${WORKSPACE_PATH:-/workspace}/config/util_paths.sh" 2>/dev/null || true
# The shared log verbs, so `mksync | tee build.log` comes out plain.
# util_paths.sh leaves colourless stubs, so log_* always resolve.
declare -F devkit_require >/dev/null 2>&1 && devkit_require "util_logging.sh" 2>/dev/null || true

export SYS_PYTHON_EXE=${SYS_PYTHON_EXE:-/usr/bin/python3}

# Shared CMake knobs (.env → compose → here): CMAKE_EXTRA_ARGS, the documented
# C/C++ standard pins and the OPENCV_CUDA policy. Fills DEVKIT_CMAKE_EXTRA.
__cmake_extra_args() {
    DEVKIT_CMAKE_EXTRA=()
    [ -n "${CMAKE_EXTRA_ARGS:-}" ] && read -r -a DEVKIT_CMAKE_EXTRA <<< "${CMAKE_EXTRA_ARGS}"
    [ -n "${CMAKE_C_STANDARD:-}" ] && DEVKIT_CMAKE_EXTRA+=("-DCMAKE_C_STANDARD=${CMAKE_C_STANDARD}")
    [ -n "${CMAKE_CXX_STANDARD:-}" ] && DEVKIT_CMAKE_EXTRA+=("-DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}")
    # OPENCV_CUDA must reach the compiler at configure time. Probed per call:
    # 90 ms against a build measured in seconds beats a cache to invalidate.
    local gpu_args=()
    read -r -a gpu_args <<< "$(bash "${WS_SCRIPTS}/setup_gpu.sh" opencv_args 2>/dev/null || true)"
    DEVKIT_CMAKE_EXTRA+=("${gpu_args[@]}")
    return 0
}

# A missing build tool means the wrong image, not a broken workspace.
__require_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    log_error "'$1' not found in this image."
    log_detail "ROS builds need ENV=ros; plain CMake projects use 'mbuild'." >&2
    return 1
}

# Refresh the workspace links after anything that creates their targets,
# so they do not lag a whole session behind.
__refresh_links() {
    # No --skip here: this runs AFTER a build, which is the only moment the
    # per-package compile_commands.json files exist to be merged. Skipping it
    # meant the aggregate the IDE reads was never written outside a manual run.
    [ -x "${WS_SCRIPTS}/util_setup_links.sh" ] && "${WS_SCRIPTS}/util_setup_links.sh"
    return 0
}

# The advertised build flags; anything else passes through ('--' forces it).
# $1 = generation, since the package selector differs: 2 colcon, 1 catkin, cmake.
# Fills DEVKIT_BUILD_TYPE_ARG / DEVKIT_BUILD_SELECT / DEVKIT_BUILD_PASSTHRU.
__parse_build_flags() {
    local gen="${1:-2}"; shift
    # RelWithDebInfo, not CMake's empty default: an unoptimised robotics build is
    # a performance bug nobody reads in the log.
    DEVKIT_BUILD_TYPE_ARG="RelWithDebInfo"
    DEVKIT_BUILD_SELECT=()
    DEVKIT_BUILD_PASSTHRU=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --debug)   DEVKIT_BUILD_TYPE_ARG="Debug"; shift ;;
            --release) DEVKIT_BUILD_TYPE_ARG="Release"; shift ;;
            --pkg)
                shift
                if [ $# -eq 0 ] || [[ "$1" == --* ]]; then
                    log_error "--pkg requires at least one package name."
                    return 2
                fi
                case "$gen" in
                    2) DEVKIT_BUILD_SELECT+=(--packages-select) ;;
                    1) DEVKIT_BUILD_SELECT+=(--only-pkg-with-deps) ;;
                    *) log_error "--pkg applies to ROS builds only."; return 2 ;;
                esac
                while [ $# -gt 0 ] && [[ "$1" != --* ]]; do DEVKIT_BUILD_SELECT+=("$1"); shift; done ;;
            --meta)
                if [ "$gen" = "2" ]; then
                    DEVKIT_BUILD_SELECT+=(--metas "${WS_CONFIG:-${WS_ROOT}/config}/colcon.meta")
                else
                    log_warn "--meta is a colcon option; ignored here."
                fi; shift ;;
            --) shift; DEVKIT_BUILD_PASSTHRU+=("$@"); break ;;
            *)  DEVKIT_BUILD_PASSTHRU+=("$1"); shift ;;
        esac
    done
}

# A prod image copies install/ only, so a build that installs nothing ships
# nothing. $1 names the missing install rule (catkin and CMake spell it apart).
__require_install_artifacts() {
    [ -n "$(find "${WS_ROOT}/install" -path '*/.venv' -prune -o -mindepth 2 -type f -print -quit 2>/dev/null)" ] && return 0
    log_error "Production build installed no artifacts into ${WS_ROOT}/install."
    log_detail "Add ${1} rules; the production runtime image copies install/ only." >&2
    return 1
}

# ROS images share the system interpreter and its Python dependencies.
__parse_share_flag() {
    DEVKIT_SHARE_MODE=false
    DEVKIT_REMAINING_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --share) DEVKIT_SHARE_MODE=true ;;
            *) DEVKIT_REMAINING_ARGS+=("$arg") ;;
        esac
    done
    # Shared iff ROS is installed: the bindings live in the system interpreter.
    [ ! -d "/opt/ros/${ROS_DISTRO:-}" ] || DEVKIT_SHARE_MODE=true
}

# --- General System & Help ----------------------------------------------------
alias h='__print_container_help'
alias help='__print_container_help'
# Functions, not aliases: aliases never expand in a non-interactive shell.
hwcheck()    { bash "${WS_SCRIPTS}/check_hardware.sh" "$@"; }
gpus()       { bash "${WS_SCRIPTS}/setup_gpu.sh" status "$@"; }
check_deps() { bash "${WS_SCRIPTS}/check_deps.sh" "$@"; }

__print_container_help() {
    # Locals, not devkit_auto_color: `exec >` would redirect the user's shell
    # for good. _log_plain is the same rule the log verbs apply.
    local T='\033[38;2;45;212;191m' S='\033[0;36m' G='\033[32m' Y='\033[33m' C='\033[36m' P='\033[35m' N='\033[0m'
    _log_plain && { T=''; S=''; G=''; Y=''; C=''; P=''; N=''; }
    echo -e "\n${T}DevKit Container Shortcuts & Aliases${N}\n"

    echo -e "${S}[ Quick Start & Build ] =============================${N}"
    printf "  ${G}%-20s${N} : %s\n" "mksync [--share]" "Initialize workspace; --share for system-site-packages"
    printf "  ${G}%-20s${N} : %s\n" "cbuild / mbuild" "Build workspace (ROS colcon or Modern CMake)"
    printf "  ${G}%-20s${N} : %s\n" "mkbuild / mdebugenv" "Build for the detected layout / write .vscode/.debug.env for F5"
    printf "  ${G}%-20s${N} : %s\n" "mtest / mlint" "Run the project's tests / check style and lint rules"
    printf "  ${G}%-20s${N} : %s\n" "cbt / cbtr" "Run ROS tests directly / view test results"
    printf "  ${G}%-20s${N} : %s\n" "s / sb" "Source workspace / Source .bashrc"
    printf "  ${G}%-20s${N} : %s\n" "mclean" "Clean build, install & log output directories"

    echo -e "\n${S}[ ROS Subsystem ] ===================================${N}"
    printf "  ${G}%-20s${N} : %s\n" "rt / rte / rth" "Topic list / echo / hz"
    printf "  ${G}%-20s${N} : %s\n" "rn / rs / rp" "Node list / service list / param list"
    printf "  ${G}%-20s${N} : %s\n" "rr / rl / ri" "ros2 run / launch / interface show"

    echo -e "\n${S}[ Python & Environment ] ============================${N}"
    printf "  ${Y}%-20s${N} : %s\n" "mkenv / activate" "Create or activate Python virtualenv (.venv)"
    printf "  ${Y}%-20s${N} : %s\n" "uvs / uvr / uvp / uvl" "uv sync / run / pip install / pip list"
    printf "  ${Y}%-20s${N} : %s\n" "uvpython / syspython" "Run Python in venv or system environment"
    printf "  ${Y}%-20s${N} : %s\n" "pyv" "Show which python/venv/uv is active"
    printf "  ${Y}%-20s${N} : %s\n" "sync_deps" "Sync external dependencies from .repos file"

    echo -e "\n${S}[ Navigation & Utilities ] ==========================${N}"
    printf "  ${C}%-20s${N} : %s\n" "cw / cs / cc" "cd to workspace root / src / config"
    printf "  ${C}%-20s${N} : %s\n" "ll / la / g" "ls -alF / ls -A / git wrapper"
    printf "  ${C}%-20s${N} : %s\n" "k / k9" "killall / killall -9"
    printf "  ${C}%-20s${N} : %s\n" "ccs / ccc" "ccache stats / clear ccache"

    echo -e "\n${S}[ Hardware & Diagnostics ] ==========================${N}"
    printf "  ${P}%-20s${N} : %s\n" "hwcheck" "6-section scan: system, network, GPU, display, identity, toolchain"
    printf "  ${P}%-20s${N} : %s\n" "gpus" "Full render stack: GL/GLX, EGL, Vulkan, D3D12, loader paths"
    printf "  ${P}%-20s${N} : %s\n" "gpu <mode>" "Switch GPU mode (auto/nvidia/tegra/intel/amd/igpu/cpu)"
    printf "  ${P}%-20s${N} : %s\n" "gpu_check / vulkan_check" "One-line OpenGL / Vulkan renderer check"
    printf "  ${P}%-20s${N} : %s\n" "gpu_test / pyt" "Render a real frame / check the ML stack sees the GPU"
    printf "  ${P}%-20s${N} : %s\n\n" "check_deps" "Check missing shared libraries in install/"
}

# --- ROS 1 / ROS 2 Environment & Build --------------------------------------
__smart_source() {
    local setup rc=0
    setup="$(devkit_overlay_setup)" || setup="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
    if [ ! -f "$setup" ]; then
        log_error "No ROS setup.bash found!"
        return 1
    fi
    # A setup.bash that fails must not be reported as sourced: the shell is then
    # missing the very packages the log said it had.
    source "$setup" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log_error "Failed to source ${setup} (exit ${rc})."
        return "$rc"
    fi
    log_ok "Sourced ${setup}"
}

alias s='__smart_source'
alias sb='source ~/.bashrc'

# cbuild [--debug|--release] [--pkg <name>…] [--meta] [-- <extra args>]
#   ROS build: colcon (ROS 2) or catkin_make (ROS 1). Default RelWithDebInfo.
#   --pkg selects packages, --meta applies config/colcon.meta, '--' forces
#   passthrough. Unknown flags reach the build tool untouched.
#
# A FUNCTION, not an alias: aliases do not expand inside functions in a
# non-interactive shell, and mksync() calls this during `docker build`.
# --symlink-install is dev-only — a prod image copies install/ but never src/,
# so those links would dangle; DEVKIT_BUILD_TYPE=prod forces a real copy.
if [ "${ROS_DISTRO:-}" != "noetic" ] && [ "${ROS_VERSION:-2}" = "2" ]; then
    cbuild() {
        __require_cmd colcon || return 1
        local link_flag=(--symlink-install) extra=()
        [ "${DEVKIT_BUILD_TYPE:-dev}" = "prod" ] && link_flag=()
        [ -n "${COLCON_EXTRA_FLAGS:-}" ] && read -r -a extra <<< "${COLCON_EXTRA_FLAGS}"
        __parse_build_flags 2 "$@" || return 2
        __cmake_extra_args
        # Run from WS_ROOT so build/, install/, log/ and the colcon.meta link
        # land at the workspace root regardless of the caller's cwd.
        ( cd "${WS_ROOT}" && colcon build "${link_flag[@]}" "${extra[@]}" "${DEVKIT_BUILD_SELECT[@]}" \
            --cmake-args -Wno-dev --no-warn-unused-cli \
            -DCMAKE_BUILD_TYPE="${DEVKIT_BUILD_TYPE_ARG}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            "${DEVKIT_CMAKE_EXTRA[@]}" "${DEVKIT_BUILD_PASSTHRU[@]}" ) || return 1
        __refresh_links
    }
    cbt() { (cd "${WS_ROOT}" && colcon test "$@"); }
    cbtr() { (cd "${WS_ROOT}" && colcon test-result --all "$@"); }
    alias rt='ros2 topic list'
    alias rte='ros2 topic echo'
    alias rth='ros2 topic hz'
    alias rn='ros2 node list'
    alias rs='ros2 service list'
    alias rp='ros2 param list'
    alias rr='ros2 run'
    alias rl='ros2 launch'
    alias ri='ros2 interface show'
else
    # catkin_make fills devel/, never install/ — a prod build must run the
    # install target explicitly or the image ships no ROS artifacts.
    cbuild() {
        __require_cmd catkin_make || return 1
        local extra=()
        [ -n "${COLCON_EXTRA_FLAGS:-}" ] && read -r -a extra <<< "${COLCON_EXTRA_FLAGS}"
        __parse_build_flags 1 "$@" || return 2
        __cmake_extra_args
        set -- "${DEVKIT_BUILD_PASSTHRU[@]}"
        DEVKIT_CMAKE_EXTRA+=("-DCMAKE_BUILD_TYPE=${DEVKIT_BUILD_TYPE_ARG}")
        if [ "${DEVKIT_BUILD_TYPE:-dev}" = "prod" ]; then
            ( cd "${WS_ROOT}" && catkin_make install "${DEVKIT_BUILD_SELECT[@]}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                -DCMAKE_INSTALL_PREFIX="${WS_ROOT}/install" "${DEVKIT_CMAKE_EXTRA[@]}" "${extra[@]}" "$@" ) || return 1
            __require_install_artifacts "install() (catkin CMakeLists.txt)" || return 1
        else
            ( cd "${WS_ROOT}" && catkin_make "${DEVKIT_BUILD_SELECT[@]}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                "${DEVKIT_CMAKE_EXTRA[@]}" "${extra[@]}" "$@" ) || return 1
        fi
        __refresh_links
    }
    cbt() { (cd "${WS_ROOT}" && catkin_make run_tests "$@"); }
    cbtr() { (cd "${WS_ROOT}" && catkin_test_results "$@"); }
    alias rt='rostopic list'
    alias rte='rostopic echo'
    alias rth='rostopic hz'
    alias rn='rosnode list'
    alias rs='rosservice list'
    alias rp='rosparam list'
    alias rr='rosrun'
    alias rl='roslaunch'
    alias ri='rosmsg show'
fi

# --- Python & Virtualenv (uv) ------------------------------------------------
uvr() { uv run "$@"; }
uvp() { uv pip install "$@"; }
uvl() { uv pip list; }

# uvs [<uv sync args>…]
#   Install the project's Python dependencies from src/pyproject.toml (or
#   dependencies/requirements.txt). Honours UV_EXTRA (cpu/gpu) and
#   UV_SYNC_FLAGS; the `dev` group comes along except in prod builds.
uvs() {
    local venv="${WS_VENV:-${WS_ROOT}/install/.venv}"
    local pyproject="${WS_SRC:-${WS_ROOT}/src}/pyproject.toml"
    local req_file="${WS_ROOT}/dependencies/requirements.txt"
    local sync_flags=()
    [ -n "${UV_SYNC_FLAGS:-}" ] && read -r -a sync_flags <<< "${UV_SYNC_FLAGS}"
    # uv installs the `dev` group by default; a prod venv must not carry
    # ruff and pytest. Dev builds keep them — mtest/mlint need them.
    if [ "${DEVKIT_BUILD_TYPE:-dev}" = "prod" ]; then
        sync_flags+=(--no-default-groups --no-editable --locked)
        if [ -f "$pyproject" ] && [ ! -f "${WS_SRC}/uv.lock" ]; then
            log_error "Production requires src/uv.lock. Run 'mksync' and commit the lockfile."
            return 1
        fi
    fi
    [ -x "${WS_VENV_PY:-}" ] || mkenv || return 1

    if [ -f "$pyproject" ]; then
        local extra_args=()
        if [ -n "${UV_EXTRA:-}" ]; then
            extra_args=(--extra "${UV_EXTRA}")
        fi
        # --python pins the interpreter the venv already has; without it uv
        # REPLACES a mismatching venv, turning `mksync --share` pure and
        # losing rospy. UV_PROJECT_ENVIRONMENT is needed too: during
        # `docker build` nothing has exported it yet.
        UV_PROJECT_ENVIRONMENT="$venv" \
            uv sync --project "${WS_SRC:-${WS_ROOT}/src}" --python "${WS_VENV_PY}" \
                "${extra_args[@]}" "${sync_flags[@]}" "$@"
    elif [ -f "$req_file" ] && grep -qv '^[[:space:]]*#' "$req_file" 2>/dev/null; then
        uv pip install --python "${WS_VENV_PY}" -r "$req_file" "$@"
    else
        log_info "No Python dependency manifest found. Skipping uv sync."
    fi
}

# Project type: ROS | CPP | PYTHON.
# `-print -quit`: bare -quit suppresses find's implicit -print and yields "".
# __cmake_entry — the directory whose CMakeLists.txt a build would configure,
# or nothing. The ONE answer for the detector, mbuild and the prod builder's
# COPY set; root first, then src/, never thirdparty.
__cmake_entry() {
    local src="${WS_SRC:-${WS_ROOT}/src}"
    if   [ -f "${WS_ROOT}/CMakeLists.txt" ]; then printf '%s' "${WS_ROOT}"
    elif [ -f "${src}/CMakeLists.txt" ];     then printf '%s' "${src}"
    else return 1; fi
}

__detect_project_type() {
    local src="${WS_SRC:-${WS_ROOT}/src}"
    if [ -n "${ROS_DISTRO:-}" ] && [ -d "$src" ]; then
        if [ -n "$(find "$src" -name thirdparty -prune -o -name package.xml -print -quit 2>/dev/null)" ]; then
            echo "ROS"; return
        fi
    fi
    if __cmake_entry >/dev/null 2>&1; then echo "CPP"; else echo "PYTHON"; fi
}

# mkenv [--share] [<uv venv args>…]
#   Create install/.venv with a project-named prompt. ROS images force --share
#   to use the system interpreter and its dependencies.
mkenv() {
    local venv_dir="${WS_VENV:-${WS_ROOT}/install/.venv}"
    local prompt="${COMPOSE_PROJECT_NAME:-.venv}"
    local share=() py="${UV_PYTHON:-3.10}" label="Pure"
    __parse_share_flag "$@"
    if [ "$DEVKIT_SHARE_MODE" = true ]; then
        share=(--system-site-packages); py="${SYS_PYTHON_EXE}"; label="Shared"
    fi
    if command -v uv >/dev/null 2>&1; then
        # --seed brings pip, setuptools and wheel: 18 MB of package manager the
        # runtime never calls, and the whole content of a prod pip manifest.
        local seed=(--seed)
        [ "${DEVKIT_BUILD_TYPE:-dev}" != prod ] || seed=()
        # --clear when the directory exists without a usable interpreter: an
        # empty root-created .venv (Docker's mount-source, or any in-container
        # root run) made every later mksync fail with uv's raw "Permission
        # denied" / "already exists", with nothing suggesting a way out.
        local clear=()
        [ ! -d "$venv_dir" ] || [ -x "${WS_VENV_PY:-}" ] || clear=(--clear)
        uv venv "$venv_dir" --python "$py" "${share[@]}" ${seed[@]+"${seed[@]}"} ${clear[@]+"${clear[@]}"} \
            --prompt "$prompt" "${DEVKIT_REMAINING_ARGS[@]}" || {
                log_error "Could not create ${venv_dir}."
                log_detail "If it exists but is unusable (root-owned from a container run), remove it: 'mclean --all'." >&2
                return 1; }
    else
        # The fallback must honour --share too, or a noetic workspace (where it
        # is forced) silently ends up without rospy.
        python3 -m venv "${share[@]}" --prompt "$prompt" "$venv_dir" || return 1
    fi
    __refresh_links   # ${WS_ROOT}/.venv should point at the new environment now
    log_ok "${label} venv '${prompt}' created: ${venv_dir}"
    source "${venv_dir}/bin/activate"
}

activate() {
    local venv_dir="${WS_VENV:-${WS_ROOT}/install/.venv}"
    if [ -f "${venv_dir}/bin/activate" ]; then
        source "${venv_dir}/bin/activate"
        # Re-entrant already: activate calls `deactivate nondestructive` first.
        devkit_venv_prompt
        log_ok "Activated virtualenv: ${venv_dir}"
    else
        log_warn "Virtualenv not found at ${venv_dir}. Run 'mkenv' first."
    fi
}

alias sync_deps='bash ${WS_SCRIPTS}/setup_sync_deps.sh'

# mksync [--share] [<uv sync args>…]
#   One-shot workspace init: venv → Python deps → rosdep/vcs → build → source.
mksync() {
    __parse_share_flag "$@"
    local mkenv_args=()
    [ "$DEVKIT_SHARE_MODE" = true ] && mkenv_args=(--share)
    # Snapshot now: mkenv() re-runs __parse_share_flag and overwrites the globals.
    local uvs_args=("${DEVKIT_REMAINING_ARGS[@]}")

    # 1. venv → activate → Python packages → system/ROS dependencies
    if [ -x "$WS_VENV_PY" ] && [ "$DEVKIT_SHARE_MODE" = true ] && \
       ! grep -q '^include-system-site-packages = true' "$WS_VENV/pyvenv.cfg"; then
        log_error "Existing venv is isolated. Run 'mkenv --share' once, then retry mksync."
        return 1
    fi
    { [ -x "${WS_VENV_PY}" ] || mkenv "${mkenv_args[@]}"; } && \
    activate && \
    uvs "${uvs_args[@]}" && \
    bash "${WS_SCRIPTS}/setup_sync_deps.sh" --rosdep || return 1

    # 2. Build with whatever the project layout calls for
    mkbuild
}

# mkbuild [--debug|--release] [<build args>…]
#   Build with whatever the project layout calls for: ROS → cbuild (+ overlay
#   sourced), CMake → mbuild, pure Python → nothing. The one dispatcher mksync
#   and the IDE's pre-launch task share.
mkbuild() {
    local project_type
    project_type=$(__detect_project_type)
    case "$project_type" in
        "ROS")
            log_info "ROS workspace detected — building..."
            cbuild "$@" && __smart_source ;;
        "CPP")
            log_info "Pure C++ project detected — running mbuild..."
            mbuild "$@" ;;
        *)
            log_ok "Pure Python project — no build step needed." ;;
    esac
}

# mdebugenv
#   Write the SOURCED environment (ROS + overlay + venv + GPU) to
#   .vscode/.debug.env for the VS Code debuggers' envFile. A debugger's parent
#   process cannot source setup.bash, and the static copies launch.json used to
#   carry drifted from colcon's per-package prefixes, ROS 1's devel/ and the GPU
#   library path. Only single-line values; the file is regenerated every run.
mdebugenv() {
    local out="${WS_ROOT}/.vscode/.debug.env" kv n=0
    mkdir -p "${WS_ROOT}/.vscode" || return 1
    ( __smart_source >/dev/null 2>&1 || true
      : > "$out"
      while IFS= read -r -d '' kv; do
          case "$kv" in *$'\n'*) continue ;; esac
          case "${kv%%=*}" in
              PATH|PYTHONPATH|LD_LIBRARY_PATH|PKG_CONFIG_PATH|VIRTUAL_ENV|AMENT_*|CMAKE_PREFIX_PATH|COLCON_*|ROS*|RMW_*|CYCLONEDDS_*|FASTRTPS_*|LIBGL_*|MESA_*|GALLIUM_DRIVER|VK_ICD_FILENAMES|GBM_BACKEND|QT_*|GDK_BACKEND|__NV_*|__GLX_*|__VK_*|__EGL_*)
                  printf '%s\n' "$kv" >> "$out" ;;
          esac
      done < <(env -0) )
    n="$(grep -c . "$out" 2>/dev/null || echo 0)"
    log_ok "Debugger environment written: ${out#"$WS_ROOT"/} (${n} variables)"
}

# --- Quality loop (test / lint) -----------------------------------------------
# mtest [<runner args>…]
#   ROS → colcon test + test-result, CMake → ctest, Python → pytest. The runner
#   comes from the same project-type detection mksync uses.
mtest() {
    local project_type
    project_type=$(__detect_project_type)
    case "$project_type" in
        ROS) cbt "$@" && cbtr ;;
        CPP)
            if [ ! -d "${WS_ROOT}/build" ]; then
                log_error "No build directory — run 'mbuild' first."
                return 1
            fi
            # cd, not --test-dir: that flag arrived in CMake 3.20 and 20.04
            # (noetic) ships 3.16, which IGNORES it and tests the cwd instead —
            # mtest was green there without running the project's tests.
            __require_cmd ctest || return 1
            ( cd "${WS_ROOT}/build" && ctest --output-on-failure "$@" ) || return 1
            # A CMake project can still carry python tests, and GETTING_STARTED
            # tells a fork to add a CMakeLists.txt to the same tree: running
            # ctest alone dropped them silently and `make test` stayed green.
            if [ -n "$(find "${WS_SRC:-${WS_ROOT}/src}" -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | head -n 1)" ]; then
                __pytest "$@"
            fi ;;
        *)  __pytest "$@" ;;
    esac
}

# The venv's pytest (from the dev group). "No tests ran" and "no runner
# installed" are different answers — say which.
__pytest() {
    local tests_dir="${WS_SRC:-${WS_ROOT}/src}"
    if [ ! -x "${WS_VENV_PY:-}" ]; then
        log_error "No virtualenv — run 'mksync' first."
        return 1
    fi
    if ! "${WS_VENV_PY}" -m pytest --version >/dev/null 2>&1; then
        log_error "pytest is not installed in ${WS_VENV_PY}."
        log_detail "It ships in the 'dev' dependency-group of src/pyproject.toml; run 'uvs' to install it." >&2
        return 1
    fi
    local rc=0
    "${WS_VENV_PY}" -m pytest "$tests_dir" "$@" || rc=$?
    # Exit 5 = nothing collected. A project without tests yet is not failing,
    # and a template that goes red on a fresh clone teaches people to ignore it.
    if [ "$rc" -eq 5 ]; then
        log_info "No tests collected under ${tests_dir} — add test_*.py files there."
        return 0
    fi
    return "$rc"
}

# mlint [--fix]
#   ruff (Python) and clang-format (C/C++ when installed) in check mode; --fix
#   applies what can be applied. Same rules the editor uses on save
#   (.editorconfig → [tool.ruff] and .clang-format).
mlint() {
    local fix=false src="${WS_SRC:-${WS_ROOT}/src}" rc=0 checked=0
    # Also the repository root when a project lives there (__cmake_entry's first
    # choice): a root-level .py was never linted while ruff reported clean.
    local roots=("$src") entry
    entry="$(__cmake_entry 2>/dev/null || true)"
    [ "$entry" != "${WS_ROOT}" ] || roots=("${WS_ROOT}/src" "${WS_ROOT}")
    case "${1:-}" in
        --fix)  fix=true; shift ;;
        -h|--help) echo "Usage: mlint [--fix]   (ruff for Python, clang-format for C/C++)"; return 0 ;;
        "") ;;
        *) log_error "mlint: unknown option: $1"; return 2 ;;
    esac

    if [ -x "${WS_VENV_PY:-}" ] && "${WS_VENV_PY}" -m ruff --version >/dev/null 2>&1; then
        checked=1
        if [ "$fix" = true ]; then
            "${WS_VENV_PY}" -m ruff check --fix "${roots[@]}" || rc=1
            "${WS_VENV_PY}" -m ruff format "${roots[@]}" || rc=1
        else
            "${WS_VENV_PY}" -m ruff check "${roots[@]}" || rc=1
            "${WS_VENV_PY}" -m ruff format --check "${roots[@]}" || rc=1
        fi
    else
        log_warn "ruff is not installed — skipping the Python half."
        log_detail "It ships in the 'dev' dependency-group of src/pyproject.toml; run 'mksync' or 'uvs'." >&2
    fi

    # clang-format is opt-in (it pulls libllvm); the editor uses the copy
    # bundled with the C/C++ extension.
    local cpp_files=()
    while IFS= read -r cpp_file; do cpp_files+=("$cpp_file"); done < <(
        find "$src" -path '*/thirdparty' -prune -o -type f \
            \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) \
            -print 2>/dev/null)
    if [ "${#cpp_files[@]}" -gt 0 ]; then
        if command -v clang-format >/dev/null 2>&1; then
            checked=1
            if [ "$fix" = true ]; then
                clang-format -i "${cpp_files[@]}" || rc=1
            else
                clang-format --dry-run --Werror "${cpp_files[@]}" || rc=1
            fi
        else
            # FAIL, not skip: `make lint` is the CI style gate, and reporting
            # "Lint clean" with C/C++ sources present and no formatter is the
            # answer this function's own comment below calls the worst one.
            log_error "${#cpp_files[@]} C/C++ file(s) present but clang-format is not installed."
            log_detail "Uncomment 'clang-format # dev' in dependencies/apt.txt and run 'make build', or set DEVKIT_SKIP_CLANG_FORMAT=1 to accept an unchecked C/C++ half." >&2
            case "${DEVKIT_SKIP_CLANG_FORMAT:-}" in
                1|true|yes|on) log_warn "DEVKIT_SKIP_CLANG_FORMAT set — continuing without the C/C++ half." ;;
                *) rc=1 ;;
            esac
        fi
    fi

    # "Clean" must mean something ran: reporting success with no checker present
    # is the worst possible answer for a CI gate.
    if [ "$checked" -eq 0 ]; then
        log_error "Nothing was checked — no linter is available for this workspace."
        log_detail "Run 'mksync' (installs ruff from the dev dependency-group), or add sources under ${src}." >&2
        return 1
    fi
    [ "$rc" -eq 0 ] && log_ok "Lint clean." || log_error "Lint reported findings."
    return "$rc"
}

# pyv: one-glance answer to "which python am I actually running?"
pyv() {
    printf '  %-11s: %s (%s)\n' "python3" "$(command -v python3)" "$(python3 -V 2>&1 | cut -d' ' -f2)"
    printf '  %-11s: %s\n' "venv" "${VIRTUAL_ENV:-inactive}"
    command -v uv >/dev/null 2>&1 && printf '  %-11s: %s\n' "uv" "$(uv --version 2>/dev/null | cut -d' ' -f2)"
    python3 -c 'import sys; print("  {:<11}: {}".format("sys.prefix", sys.prefix))' 2>/dev/null
}

uvpython() {
    if [ -x "${WS_VENV_PY:-}" ]; then
        "${WS_VENV_PY}" "$@"
    else
        python3 "$@"
    fi
}

syspython() {
    /usr/bin/python3 "$@"
}

# --- Navigation & Utilities --------------------------------------------------
alias cw='cd "${WS_ROOT}"'
alias cs='cd "${WS_SRC}"'
alias cc='cd "${WS_CONFIG}"'

alias ll='ls -alF'
alias la='ls -A'
alias g='git'
alias k='killall'
alias k9='killall -9'

alias ccs='ccache -s'
alias ccc='ccache -C'

# --- Hardware & GPU Diagnostics ---------------------------------------------
# gpu [mode]
#   status (default) | opencv_args | auto | nvidia | tegra | intel | amd | igpu | cpu
#   Sourced, so a mode switch applies to the current shell. setup_gpu.sh owns
#   the vocabulary and answers --help; a second copy of the list here drifted.
# A mode change must reach the CALLER's environment, so those stay sourced.
# The read-only views must not: setup_gpu.sh strips colour by rewiring stdout,
# and sourced into the caller that rewiring stayed after `gpu status` returned.
gpu() {
    case "${1:-status}" in
        status|-h|--help) ( source "${WS_SCRIPTS}/setup_gpu.sh" "${1:-status}" ) ;;
        *)                source "${WS_SCRIPTS}/setup_gpu.sh" "$1" ;;
    esac
}

alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "No display / glxinfo unavailable"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'

# gpu_test — actually RENDER a frame for 5 s. `gpus` reports what the stack
# claims; this proves frames come out.
gpu_test() {
    if ! command -v glxgears >/dev/null 2>&1; then
        log_warn "glxgears not installed (apt: mesa-utils)."; return 1
    fi
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        log_warn "No DISPLAY/WAYLAND_DISPLAY — cannot render."; return 1
    fi
    log_info "Rendering for 5s..."
    local out
    out="$(timeout 6 glxgears -info 2>&1 | grep -E "GL_RENDERER|frames in" | head -3 || true)"
    if [ -z "$out" ]; then
        log_error "No frames rendered — check 'gpus' and 'make xauth'."; return 1
    fi
    echo "$out" | sed 's/^/    /'
}

# The first question after a GPU setup: does the ML stack see the device?
torch_check() {
    local py="${WS_VENV_PY:-}"
    [ -x "$py" ] || py=python3
    "$py" - <<'PY' 2>/dev/null || log_warn "PyTorch not installed — add it to src/pyproject.toml (the commented cpu/gpu example) and run uvs."
import torch
print(f"    torch      {torch.__version__}")
print(f"    CUDA build {torch.version.cuda or 'cpu-only'}")
avail = torch.cuda.is_available()
print(f"    CUDA avail {avail}")
if avail:
    print(f"    device     {torch.cuda.get_device_name(0)}")
elif getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
    print("    device     Apple MPS")
PY
}
alias pyt='torch_check'

# --- Modern CMake & C++ Shortcuts --------------------------------------------
# mbuild [--debug|--release] [-- <cmake args>]
#   Plain CMake build of the repository root (or src/ when the root has no
#   CMakeLists.txt): configure, build with all cores, and install for a prod
#   build. Default RelWithDebInfo; --pkg is refused (ROS builds only).
mbuild() {
    local src_dir
    if ! src_dir="$(__cmake_entry)"; then
        log_error "No CMakeLists.txt in ${WS_ROOT} or ${WS_SRC:-${WS_ROOT}/src}."
        return 1
    fi
    __require_cmd cmake || return 1
    __parse_build_flags cmake "$@" || return 2
    __cmake_extra_args
    cmake -B "${WS_ROOT}/build" -S "$src_dir" -Wno-dev --no-warn-unused-cli \
          -DCMAKE_BUILD_TYPE="${DEVKIT_BUILD_TYPE_ARG}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
          -DCMAKE_INSTALL_PREFIX="${WS_ROOT}/install" "${DEVKIT_CMAKE_EXTRA[@]}" "${DEVKIT_BUILD_PASSTHRU[@]}" \
        && cmake --build "${WS_ROOT}/build" -j"$(nproc 2>/dev/null || echo 4)" || return 1

    if [ "${DEVKIT_BUILD_TYPE:-dev}" = "prod" ]; then
        cmake --install "${WS_ROOT}/build" || return 1
        __require_install_artifacts "install(TARGETS ... DESTINATION bin/lib)" || return 1
    fi
    __refresh_links
}

# mclean [--all]
#   Empty build/, log/ and the install output. --all also removes install/
#   itself and the virtualenv (re-run mksync afterwards).
#
# ${WS_ROOT:?}: an unset root would make this `rm -rf /build /log`.
# These are volume mount points, so rm empties them but cannot remove them
# (EBUSY) — hence the suppressed stderr; leftover CONTENT is the real failure.
mclean() {
    # Same scope as the host's `make clean`: build/, devel/, log/ and everything
    # in install/ except the venv. Naming install/bin and install/lib alone left
    # colcon's per-package trees (install/<pkg>/…), install/share and a ROS 1
    # devel/ behind while reporting success.
    local keep_venv=true
    local what="build, devel, log and install output (the virtualenv is kept)"
    # A destructive command must not swallow an unknown argument — falling
    # through to the default clean would delete the build output.
    case "${1:-}" in
        "") ;;
        --all)
            keep_venv=false
            what="ALL build output including install/ and the virtualenv (re-run mksync)" ;;
        -h|--help) echo "Usage: mclean [--all]   (--all also removes install/ and the venv)"; return 0 ;;
        *) log_error "mclean: unknown option: $1"; return 2 ;;
    esac
    # Empty the directories rather than removing them: build/ and install/ are
    # compose volume mount points, and unlinking those fails with EBUSY.
    local dir
    for dir in build devel log; do
        [ -d "${WS_ROOT:?}/${dir}" ] || continue
        find "${WS_ROOT:?}/${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    done
    if [ -d "${WS_ROOT:?}/install" ]; then
        if [ "$keep_venv" = true ]; then
            find "${WS_ROOT:?}/install" -mindepth 1 -maxdepth 1 ! -name '.venv' \
                -exec rm -rf {} + 2>/dev/null || true
        else
            find "${WS_ROOT:?}/install" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        fi
    fi
    # What is LEFT decides the exit status, and the venv is left on purpose.
    local leftover
    leftover="$(find "${WS_ROOT:?}/build" "${WS_ROOT:?}/devel" "${WS_ROOT:?}/log" "${WS_ROOT:?}/install" \
        -mindepth 1 -maxdepth 1 $([ "$keep_venv" = true ] && printf '%s' "! -name .venv") \
        -print -quit 2>/dev/null || true)"
    if [ -n "$leftover" ]; then
        log_error "Some entries could not be removed (root-owned? permissions?): ${leftover}"
        return 1
    fi
    log_ok "Emptied ${what}."
}

# --- Tab Completions ---------------------------------------------------------
complete -W "status opencv_args auto nvidia tegra intel amd igpu cpu" gpu 2>/dev/null || true
complete -W "--debug --release --pkg --meta" cbuild 2>/dev/null || true
complete -W "--debug --release" mbuild 2>/dev/null || true
complete -W "--rosdep --force" sync_deps 2>/dev/null || true
complete -W "--all" mclean 2>/dev/null || true
complete -W "--fix" mlint 2>/dev/null || true
complete -W "--brief" hwcheck 2>/dev/null || true
complete -W "--share" mksync mkenv 2>/dev/null || true

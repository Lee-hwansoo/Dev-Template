#!/bin/bash
# =============================================================================
# scripts/check_deps.sh — pre-ship inspection of an install tree: missing shared
# libraries (ldd), the ROS Python bindings, and plaintext source exposure.
# `check_deps.sh --help` carries the arguments and the knobs.
# =============================================================================
set -euo pipefail

# WS_ROOT / WS_VENV_PY from the path SSOT (it ignores a WORKSPACE_PATH that is
# not a tree here). Before the flag parse, so the log verbs exist.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh" 2>/dev/null || true
LOG_PREFIX="[Check Deps]"
# Colour boundary: this script's ldd/sed passthrough is not routed through the
# log verbs, so the escapes those lines carry are stripped here when redirected.
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

usage() {
    cat <<'EOF'
Usage: check_deps.sh [target_dir]

Scan an install tree for missing shared libraries, verify the ROS Python
bindings, and report (or strip) plaintext source shipped in the artifact.

Options:
  -h, --help  Show this help.
  --runtime  Audit the final image and record its installed package manifests.

Environment:
  DEVKIT_STRIP_SOURCE=1    Byte-compile .py to .pyc and delete the .py source
  DEVKIT_FAIL_ON_SOURCE=1  Exit non-zero if plaintext project source remains
EOF
}

# An unknown flag must not become a directory name: `check_deps --help` once
# failed with "Target directory '--help' does not exist".
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --runtime) RUNTIME_AUDIT=1; shift ;;
    --*) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
esac

TARGET_DIR="${1:-${WS_ROOT}/install}"

# A missing install tree must fail: this gates the prod builder stages.
if [ ! -d "$TARGET_DIR" ]; then
    log_error "Target directory '$TARGET_DIR' does not exist."
    log_detail "Build your workspace first (e.g. 'cbuild' or 'mksync')." >&2
    exit 1
fi

log_info "Scanning ELF binaries in ${TARGET_DIR}..."

missing=0
# The four magic bytes, not `file`: that package plus libmagic-mgc is 7.4 MB in
# every shipped artifact for a test the shell can do itself.
is_elf() { [ "$(LC_ALL=C head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }
while IFS= read -r -d '' binary; do
    if is_elf "$binary"; then
        # Driver libraries are injected by --nv / NVIDIA Container Toolkit.
        unresolved="$(ldd "$binary" 2>/dev/null | awk '/not found/ && $1 !~ /^(libcuda\.so|libnvidia-)/ {print}' || true)"
        if [ -n "$unresolved" ]; then
            log_error "Missing libraries in ${binary}:"
            printf '    %s\n' "$unresolved"
            missing=$((missing + 1))
        fi
    fi
done < <(find "$TARGET_DIR" -type f \( -perm -u+x -o -name '*.so*' \) \
              ! -name '*.py' ! -name '*.pyc' -print0)

while IFS= read -r -d '' link; do
    [ -e "$link" ] || { log_error "Dangling installed symlink: $link"; missing=$((missing + 1)); }
done < <(find "$TARGET_DIR" -type l -print0)

# Check ROS Python bindings
if [ -d "/opt/ros/${ROS_DISTRO:-}" ]; then
    log_info "Verifying ROS (${ROS_DISTRO}) Python bindings..."
    # Plain RUN layers (prod builders) have no ROS environment, so the import
    # below would fail spuriously. setup.bash is neither `set -u`- nor
    # `set -e`-clean (its chain can end on a false test), so relax both.
    if [ -z "${AMENT_PREFIX_PATH:-}${ROS_PACKAGE_PATH:-}" ] && [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
        set +eu; source "/opt/ros/${ROS_DISTRO}/setup.bash" || true; set -eu
    fi
    py_bin="python3"
    [ -x "${WS_VENV_PY:-}" ] && py_bin="${WS_VENV_PY}"

    case "$ROS_DISTRO" in
        noetic)
            if ! "$py_bin" -c "import rospy" 2>/dev/null; then
                log_error "ROS 1 (noetic) 'rospy' module not found in $py_bin"
                log_detail "Run 'mksync --share' to enable system site-packages." >&2
                missing=$((missing + 1))
            else
                log_ok "ROS 1 'rospy' module verified."
            fi
            ;;
        *)
            if ! "$py_bin" -c "import rclpy" 2>/dev/null; then
                log_error "ROS 2 (${ROS_DISTRO}) 'rclpy' module not found in $py_bin"
                missing=$((missing + 1))
            else
                log_ok "ROS 2 'rclpy' module verified."
            fi
            ;;
    esac
fi

# =============================================================================
# Source exposure. A prod image copies install/ and never src/, but colcon
# copies ament_python modules verbatim into install/ — so Python source ships
# in plaintext unless removed here.
#
# Byte-compilation is OBFUSCATION, NOT ENCRYPTION: .pyc decompiles. For real
# protection compile to native code (C++, Nuitka/Cython).
# =============================================================================
# .venv is third-party, not project source. Launch files are read AS SOURCE by
# ros2 launch and cannot be compiled, so they are counted separately.
project_py() {
    find "$TARGET_DIR" -path "*/.venv" -prune -o -type f -name '*.py' \
        ! -path "*/launch/*" -print 2>/dev/null || true
}

py_files=()
while IFS= read -r py_file; do py_files+=("$py_file"); done < <(project_py)
launch_count="$(find "$TARGET_DIR" -path "*/.venv" -prune -o -type f -name '*.py' -path "*/launch/*" -print 2>/dev/null | wc -l)"

log_info "Source exposure: ${#py_files[@]} python module(s), ${launch_count} launch script(s)."

# An entry point is invoked by NAME — an executable bit or a shebang (ROS
# install(PROGRAMS), rosrun, a console script): deleting its .py leaves a .pyc
# nothing calls. Those stay as source; DEVKIT_FAIL_ON_SOURCE then decides.
is_entry_point() { [ -x "$1" ] || { IFS= read -r first < "$1" && [ "${first#\#!}" != "$first" ]; }; }
entry_points=(); modules=()
for f in ${py_files[@]+"${py_files[@]}"}; do
    if is_entry_point "$f"; then entry_points+=("$f"); else modules+=("$f"); fi
done

case "${DEVKIT_STRIP_SOURCE:-}" in
    1|true|yes|on)
        if [ "${#entry_points[@]}" -gt 0 ]; then
            log_warn "${#entry_points[@]} executable python entry point(s) keep their source (called by name, a .pyc would not be):"
            for f in "${entry_points[@]}"; do log_detail "${f#"$TARGET_DIR"/}"; done
        fi
        if [ "${#modules[@]}" -gt 0 ]; then
            # -b writes foo.pyc beside foo.py (legacy layout), so deleting the
            # source still leaves an importable module.
            if python3 -m compileall -b -q "${modules[@]}" >/dev/null 2>&1; then
                stripped=0
                for f in "${modules[@]}"; do
                    [ -f "${f%.py}.pyc" ] && { rm -f "$f"; stripped=$((stripped + 1)); }
                done
                find "$TARGET_DIR" -path "*/.venv" -prune -o -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
                log_ok "Stripped ${stripped}/${#modules[@]} module(s) to bytecode (obfuscation, not encryption)."
            else
                log_error "Byte-compilation failed; refusing to delete source."
                missing=$((missing + 1))
            fi
        fi
        ;;
    *)
        [ "${#py_files[@]}" -gt 0 ] && \
            log_detail "Set DEVKIT_STRIP_SOURCE=1 to ship bytecode instead of .py source."
        ;;
esac

remaining="$(project_py | wc -l)"
if [ "$remaining" -gt 0 ]; then
    log_warn "${remaining} plaintext python file(s) will ship in this artifact."
    case "${DEVKIT_FAIL_ON_SOURCE:-}" in
        1|true|yes|on)
            log_error "DEVKIT_FAIL_ON_SOURCE is set — failing the build."
            [ "${#entry_points[@]}" -eq 0 ] \
                || log_detail "Executable entry points cannot be stripped; ship them as source, wrap them in a non-Python launcher, or drop DEVKIT_FAIL_ON_SOURCE."
            missing=$((missing + 1)) ;;
    esac
fi

if [ "$missing" -eq 0 ]; then
    log_ok "All shared library and binding dependencies satisfied!"
else
    log_error "Found $missing issue(s)."
    exit 1
fi

if [ "${RUNTIME_AUDIT:-0}" = 1 ]; then
    "$WS_VENV_PY" -c 'import sys; assert sys.prefix.endswith("install/.venv"), sys.prefix'
    DEVKIT_METADATA_BASE=/etc/devkit/build/devkit-release.json DEVKIT_MANIFEST_PHASE=runtime \
        bash "$WS_SCRIPTS/util_release_metadata.sh" /etc/devkit/devkit-release.json
fi

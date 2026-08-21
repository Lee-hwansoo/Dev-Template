#!/bin/bash
# =============================================================================
# scripts/check_deps.sh
# Pre-ship inspection of an install tree: missing shared libraries (ldd),
# active ROS Python bindings (rospy/rclpy), and shipped source exposure.
#
# Usage: check_deps.sh [target_dir]
#
# Environment:
#   DEVKIT_STRIP_SOURCE=1    Byte-compile .py to .pyc and delete the .py source
#   DEVKIT_FAIL_ON_SOURCE=1  Exit non-zero if plaintext project source remains
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${WORKSPACE_PATH:-${SCRIPT_DIR}/..}"

usage() {
    cat <<'EOF'
Usage: check_deps.sh [target_dir]

Scan an install tree for missing shared libraries, verify the ROS Python
bindings, and report (or strip) plaintext source shipped in the artifact.

Options:
  -h, --help  Show this help.

Environment:
  DEVKIT_STRIP_SOURCE=1    Byte-compile .py to .pyc and delete the .py source
  DEVKIT_FAIL_ON_SOURCE=1  Exit non-zero if plaintext project source remains
EOF
}

# An unknown flag must not be read as a directory name: `check_deps --help`
# would otherwise fail with "Target directory '--help' does not exist".
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --*) echo -e "  \033[31m[ERROR]\033[0m Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# Colour boundary only (this script prints its own SGR literals).
source "${WS_ROOT}/scripts/util_logging.sh" 2>/dev/null || true
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

TARGET_DIR="${1:-${WS_ROOT}/install}"

# A missing install tree must fail: this script gates the prod builder stages,
# and a build that produced nothing would otherwise pass the gate silently.
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "  \033[31m[ERROR]\033[0m Target directory '$TARGET_DIR' does not exist."
    echo -e "  \033[36m[Hint]\033[0m Build your workspace first (e.g. 'cbuild' or 'mksync')."
    exit 1
fi

echo -e "  \033[34m[Check Deps]\033[0m Scanning ELF binaries in ${TARGET_DIR}..."

missing=0
# Candidate filter (executables + shared objects, no scripts) keeps the per-file
# `file` probe off the thousands of assets a real install tree carries.
while IFS= read -r -d '' binary; do
    if file "$binary" 2>/dev/null | grep -qE "ELF.*(executable|shared object)"; then
        if ldd "$binary" 2>/dev/null | grep -q "not found"; then
            echo -e "  \033[31m[MISSING]\033[0m $binary:"
            ldd "$binary" 2>/dev/null | grep "not found" | sed 's/^/    /'
            missing=$((missing + 1))
        fi
    fi
done < <(find "$TARGET_DIR" -type f \( -perm -u+x -o -name '*.so*' \) \
              ! -name '*.py' ! -name '*.pyc' -not -path "*/.*" -print0)

# Check ROS Python bindings
if [ -n "${ROS_DISTRO:-}" ]; then
    echo -e "  \033[34m[Check Deps]\033[0m Verifying ROS (${ROS_DISTRO}) Python bindings..."
    # Plain RUN layers (prod builders) have no ROS environment, so the import
    # below would fail spuriously. setup.bash is neither `set -u`- nor
    # `set -e`-clean (its chain can end on a false test), so relax both.
    if [ -z "${AMENT_PREFIX_PATH:-}${ROS_PACKAGE_PATH:-}" ] && [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
        set +eu; source "/opt/ros/${ROS_DISTRO}/setup.bash" || true; set -eu
    fi
    py_bin="python3"
    [ -x "${WS_ROOT}/install/.venv/bin/python3" ] && py_bin="${WS_ROOT}/install/.venv/bin/python3"

    case "$ROS_DISTRO" in
        noetic)
            if ! "$py_bin" -c "import rospy" 2>/dev/null; then
                echo -e "  \033[31m[ERROR]\033[0m ROS 1 (noetic) 'rospy' module not found in $py_bin"
                echo -e "  \033[36m[Hint]\033[0m Run 'mksync --share' to enable system site-packages."
                missing=$((missing + 1))
            else
                echo -e "  \033[32m[OK]\033[0m ROS 1 'rospy' module verified."
            fi
            ;;
        *)
            if ! "$py_bin" -c "import rclpy" 2>/dev/null; then
                echo -e "  \033[33m[WARN]\033[0m ROS 2 (${ROS_DISTRO}) 'rclpy' module not found in $py_bin"
            else
                echo -e "  \033[32m[OK]\033[0m ROS 2 'rclpy' module verified."
            fi
            ;;
    esac
fi

# =============================================================================
# Source exposure
# -----------------------------------------------------------------------------
# Production images copy install/ and never src/ — but that is not the same as
# "no source ships": colcon copies ament_python modules verbatim into
# install/<pkg>/lib/pythonX.Y/site-packages/, so a Python node's source is
# shipped in plaintext unless it is removed here.
#
# NOTE: byte-compilation is OBFUSCATION, NOT ENCRYPTION — .pyc is decompilable.
# It prevents casual reading and accidental disclosure, nothing more. For real
# protection, compile to native code (C++ nodes, or Nuitka/Cython).
# =============================================================================
# .venv holds third-party packages, not project source: excluded throughout.
# Launch files are read AS SOURCE by the ROS 2 launch system and cannot be
# byte-compiled without breaking `ros2 launch`, so they are reported separately.
project_py() {
    find "$TARGET_DIR" -path "*/.venv" -prune -o -type f -name '*.py' \
        ! -path "*/launch/*" -print 2>/dev/null || true
}

mapfile -t py_files < <(project_py)
launch_count="$(find "$TARGET_DIR" -path "*/.venv" -prune -o -type f -name '*.py' -path "*/launch/*" -print 2>/dev/null | wc -l)"

echo -e "  \033[34m[Check Deps]\033[0m Source exposure: ${#py_files[@]} python module(s), ${launch_count} launch script(s)."

case "${DEVKIT_STRIP_SOURCE:-}" in
    1|true|yes|on)
        if [ "${#py_files[@]}" -gt 0 ]; then
            # -b writes foo.pyc beside foo.py (legacy layout), so deleting the
            # source still leaves an importable module.
            if python3 -m compileall -b -q "${py_files[@]}" >/dev/null 2>&1; then
                stripped=0
                for f in "${py_files[@]}"; do
                    [ -f "${f%.py}.pyc" ] && { rm -f "$f"; stripped=$((stripped + 1)); }
                done
                find "$TARGET_DIR" -path "*/.venv" -prune -o -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
                echo -e "  \033[32m[OK]\033[0m Stripped ${stripped}/${#py_files[@]} module(s) to bytecode (obfuscation, not encryption)."
            else
                echo -e "  \033[31m[ERROR]\033[0m Byte-compilation failed; refusing to delete source."
                missing=$((missing + 1))
            fi
        fi
        ;;
    *)
        [ "${#py_files[@]}" -gt 0 ] && \
            echo -e "  \033[36m[Hint]\033[0m Set DEVKIT_STRIP_SOURCE=1 to ship bytecode instead of .py source."
        ;;
esac

remaining="$(project_py | wc -l)"
if [ "$remaining" -gt 0 ]; then
    echo -e "  \033[33m[WARN]\033[0m ${remaining} plaintext python file(s) will ship in this artifact."
    case "${DEVKIT_FAIL_ON_SOURCE:-}" in
        1|true|yes|on)
            echo -e "  \033[31m[ERROR]\033[0m DEVKIT_FAIL_ON_SOURCE is set — failing the build."
            missing=$((missing + 1)) ;;
    esac
fi

if [ "$missing" -eq 0 ]; then
    echo -e "  \033[32m[OK]\033[0m All shared library and binding dependencies satisfied!"
else
    echo -e "  \033[31m[ERROR]\033[0m Found $missing issue(s)."
    exit 1
fi

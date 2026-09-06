#!/bin/bash
# =============================================================================
# scripts/util_setup_links.sh — the workspace convenience symlinks
# (colcon.meta, .venv, compile_commands.json). `make clean` drops them; an
# interactive shell recreates them.
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
LOG_PREFIX="[Links]"

usage() {
    cat <<'EOF'
Usage: util_setup_links.sh [--verbose] [--skip-compile-commands]

Synchronize workspace helper links such as colcon.meta, .venv, and
compile_commands.json.

Options:
  --verbose                Print link synchronization messages.
  --skip-compile-commands  Skip compile_commands.json aggregation for fast shell startup.
  -h, --help               Show this help.
EOF
}

VERBOSE=false
SYNC_COMPILE_COMMANDS=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose) VERBOSE=true; shift ;;
        --skip-compile-commands) SYNC_COMPILE_COMMANDS=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

COLCON_META_SRC="${WS_CONFIG}/colcon.meta"
VENV_DIR_SRC="${WS_VENV}"

# Function to safely create a symlink
# Usage: safe_link <src> <dest> <description>
safe_link() {
    local src="$1"
    local dest="$2"
    local desc="${3:-$2}"

    # Guard: prevent catastrophic operations on empty or root paths
    if [[ -z "$src" || -z "$dest" || "$dest" == "/" ]]; then
        return 0
    fi

    # Source must exist (file, directory, or symlink) to create a link
    [[ -e "$src" ]] || return 0

    # If destination is a real directory (not a symlink), we cannot replace it
    [[ -d "$dest" && ! -L "$dest" ]] && return 0

    # Idempotency: skip if already pointing to the correct source
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
        return 0
    fi

    # Remove existing entry (symlink or regular file) and re-create
    # Use -f instead of -rf: the target is always a symlink or file, never a directory we own
    rm -f "$dest"
    # Link RELATIVE to the workspace when both ends live in it. The workspace is
    # bind-mounted, so an absolute container path ("/workspace/config/…") is
    # written into the host tree too, where it dangles — one `make start` then
    # broke `make verify` on the host.
    local target="$src"
    case "$src" in "${WS_ROOT}/"*) case "$dest" in "${WS_ROOT}/"*) target="${src#"${WS_ROOT}/"}" ;; esac ;; esac
    ln -sf "$target" "$dest"

    if [ "$VERBOSE" = true ]; then
        log_ok "$desc synchronized."
    fi
}

# 1. colcon.meta (Build Optimization Configuration)
safe_link "$COLCON_META_SRC" "${WS_ROOT}/colcon.meta" "Colcon configuration"

# 2. .venv (IDE Integration)
safe_link "$VENV_DIR_SRC" "${WS_ROOT}/.venv" "Virtual environment"

# 3. compile_commands.json (C++ IntelliSense)
# If we have multiple package-specific build directories (e.g. ROS colcon), merge them into a single compile_commands.json
if [ "$SYNC_COMPILE_COMMANDS" = true ] && [ -d "${WS_ROOT}/build" ]; then
    if [ "$VERBOSE" = true ]; then
        log_info "Aggregating compile_commands.json from all sub-packages..."
    fi
    if ! BUILD_DIR="${WS_ROOT}/build" python3 -c "
import json, glob, os
build_dir = os.environ['BUILD_DIR']
output_file = os.path.join(build_dir, 'compile_commands.json')
sub_files = [f for f in glob.glob(os.path.join(build_dir, '**/compile_commands.json'), recursive=True)
             if os.path.abspath(f) != os.path.abspath(output_file)]

if sub_files:
    all_commands = []
    for f in sub_files:
        with open(f, 'r', encoding='utf-8') as file:
            data = json.load(file)
            if isinstance(data, list):
                all_commands.extend(data)
    with open(output_file, 'w') as file:
        json.dump(all_commands, file, indent=2)
"; then
        log_warn "Failed to aggregate compile_commands.json. Check package build outputs for invalid JSON."
    fi
fi

COMPILE_COMMANDS_SRC="${WS_ROOT}/build/compile_commands.json"
safe_link "$COMPILE_COMMANDS_SRC" "${WS_ROOT}/compile_commands.json" "Compile commands"

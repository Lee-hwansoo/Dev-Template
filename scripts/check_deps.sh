#!/bin/bash
# =============================================================================
# scripts/check_deps.sh
# Verifies build artifacts for missing runtime shared library dependencies
#
# Scans the target directory for ELF files and shared objects, using ldd to
# identify missing dependencies.
# =============================================================================

TARGET_DIR=${1:-/workspace/install}
MISSING_COUNT=0

# Load logging utility
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sanity Check]"

log_info "Scanning for missing dependencies in $TARGET_DIR..."

if [ ! -d "$TARGET_DIR" ]; then
    log_error "Target directory '$TARGET_DIR' does not exist."
    log_info "Make sure you have built your project (e.g., 'cb' or 'make install') before checking dependencies."
    exit 1
fi

# Find executable files and shared libraries (.so) - use process substitution to preserve MISSING_COUNT
while IFS= read -r -d '' file; do
    # Check if it's an ELF file (only run ldd on binary files)
    if file "$file" | grep -qE 'ELF|shared object'; then
        MISSING=$(ldd "$file" 2>/dev/null | grep "not found")
        if [ -n "$MISSING" ]; then
            log_error "Missing dependencies for: $file\n$(echo "$MISSING" | sed 's/^/  /')"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
    fi
done < <(find "$TARGET_DIR" -type f \( -executable -o -name "*.so*" \) ! -name "*.py" -print0)

if [ $MISSING_COUNT -gt 0 ]; then
    log_error "$MISSING_COUNT files have missing dependencies."
    log_info "Please add missing packages to dependencies/apt.txt (with # runtime comment)."
    exit 1
else
    log_ok "All runtime dependencies are satisfied."
    exit 0
fi

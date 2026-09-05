#!/bin/bash
# =============================================================================
# scripts/show_welcome.sh — the container MOTD. Its rows are advertised surface:
# check [advertised-shortcuts] resolves every name printed here.
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || source "/tmp/util_paths.sh"
devkit_require "util_logging.sh"
LOG_PREFIX="[Welcome]"
# The banner, sections and rows below are built from the exported palette, not
# from the log verbs, so the strip happens at the output boundary: `bash
# scripts/show_welcome.sh > motd.txt` must not capture escapes.
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

case "${1:-}" in
    ""|-h|--help) ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
esac

print_banner WELCOME
print_env_info

# Curated quick-start guide. Sections are "@Title" markers; entries are
# "name|description". The column width is derived from the widest name, so the
# MOTD stays aligned when entries are added and nothing is hardcoded.
WELCOME_ROWS=(
    "@Quick Start"
    "mksync|Fully initialize workspace (venv + deps + build)"
    "@Build & Sync"
    "cbuild|colcon build (--debug, --release, --pkg, --meta)"
    "cbt / cbtr|colcon test / test results"
    "sync_deps|Sync external repos from .repos file"
    "check_deps|Verify missing runtime libraries in install/"
    "@ROS & Apps"
    "rt / rn / rl|List topics / nodes / launch files"
    "s / sb|Source workspace / Source bashrc"
    "@Environment"
    "mkenv / activate|Setup & Enter Python virtualenv"
    "uvs / uvr|uv sync / uv run"
    "@Diagnostics"
    "hwcheck|Run full hardware & environment diagnostics"
    "gpus|Show detailed GPU & Display info"
)

welcome_col=0
for row in "${WELCOME_ROWS[@]}"; do
    [[ $row == @* ]] && continue
    name="${row%%|*}"
    (( ${#name} > welcome_col )) && welcome_col=${#name}
done

for row in "${WELCOME_ROWS[@]}"; do
    if [[ $row == @* ]]; then
        print_section "${row#@}"
    else
        name="${row%%|*}"
        desc="${row#*|}"
        printf "  ${GREEN}%-*s${NC} : %s\n" "$welcome_col" "$name" "$desc"
    fi
done

echo -e "\n  Type ${CYAN}h${NC} or ${CYAN}help${NC} to see the full alias & shortcut guide."
echo -e "  Workspace: ${CYAN}${WS_ROOT:-/workspace}${NC} (mapped from host)\n"

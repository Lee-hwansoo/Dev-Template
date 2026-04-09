#!/bin/bash
# =============================================================================
# scripts/utils_logging.sh
# Centralized logging utility for standardized shell output
#
# Provides color-coded logging functions (INFO, OK, WARN, ERROR, DEBUG)
# with support for timestamps, custom prefixes, and file-based logging.
# =============================================================================

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Load settings (defaults)
LOG_SHOW_TIME="${LOG_SHOW_TIME:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"

_log_base() {
    local type="$1"
    local color="$2"
    local symbol="$3"
    local msg="$4"

    local time_str=""
    if [ "${LOG_SHOW_TIME}" = "true" ]; then
        time_str="${CYAN}[$(date '+%H:%M:%S')]${NC} "
    fi

    local prefix="${LOG_PREFIX:+${CYAN}${LOG_PREFIX}${NC} }"

    # Create log file directory if it doesn't exist (only once for disk I/O optimization)
    if [ -n "${LOG_FILE}" ]; then
        local log_dir
        log_dir=$(dirname "${LOG_FILE}")
        [ ! -d "$log_dir" ] && mkdir -p "$log_dir"
    fi

    # Process multi-line messages (prevents missing the last newline)
    while IFS= read -r line || [ -n "$line" ]; do
        # Only add prefix to the line if it's not empty, otherwise just print the prefix
        if [ -z "$line" ]; then
            local full_msg="${time_str}${prefix}${color}[${type}]${NC}"
        else
            local full_msg="${time_str}${prefix}${color}[${type}]${NC} ${symbol:+${symbol} }$line"
        fi

        # Output ERROR/WARN to standard error (stderr, >&2) for shell pipe compatibility
        if [ "$type" = "ERROR" ] || [ "$type" = "WARN" ]; then
            echo -e "$full_msg" >&2
        else
            echo -e "$full_msg"
        fi

        # File logging (record after removing colors)
        if [ -n "${LOG_FILE}" ]; then
            echo -e "$full_msg" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
        fi
    done <<< "$msg"
}

log_info()  { _log_base "INFO"  "${BLUE}"   ""   "$1"; }
log_ok()    { _log_base "OK"    "${GREEN}"  "✓"  "$1"; }
log_warn()  { _log_base "WARN"  "${YELLOW}" "⚠"  "$1"; }
log_error() { _log_base "ERROR" "${RED}"    "✗"  "$1"; }
log_debug() {
    if [ "${DEBUG_MODE}" = "true" ]; then
        _log_base "DEBUG" "${PURPLE}" "⚙" "$1"
    fi
}

# Export color variables for independent use in Makefile, etc.
export RED GREEN YELLOW BLUE CYAN PURPLE NC

# =============================================================================
# DevKit Branding & Banners
# =============================================================================

# print_devkit_banner [type]
#   type: WELCOME (Large), DIAG (Diagnostics), SETUP (Maintenance), COMPACT (Small)
print_devkit_banner() {
    local type="${1:-WELCOME}"
    local T1='\033[38;2;45;212;191m' # Teal

    case "$type" in
        WELCOME)
            echo -e "${T1}=================================================${NC}"
            echo -e "  ${T1}██████╗ ███████╗██╗   ██╗██╗  ██╗██╗████████╗${NC}"
            echo -e "  ${T1}██╔══██╗██╔════╝██║   ██║██║ ██╔╝██║╚══██╔══╝${NC}"
            echo -e "  ${T1}██║  ██║█████╗  ██║   ██║█████╔╝ ██║   ██║   ${NC}"
            echo -e "  ${T1}██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═██╗ ██║   ██║   ${NC}"
            echo -e "  ${T1}██████╔╝███████╗ ╚████╔╝ ██║  ██╗██║   ██║   ${NC}"
            echo -e "  ${T1}╚═════╝ ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚═╝   ╚═╝   ${NC}"
            echo -e "${T1}=================================================${NC}"
            ;;
        DIAG)
            echo -e "${T1}================================${NC}"
            echo -e "  ${T1}██████╗ ██╗ █████╗ ██████╗  ${NC}"
            echo -e "  ${T1}██╔══██╗██║██╔══██╗██╔════╝ ${NC}"
            echo -e "  ${T1}██║  ██║██║███████║██║  ███╗${NC}"
            echo -e "  ${T1}██║  ██║██║██╔══██║██║   ██║${NC}"
            echo -e "  ${T1}██████╔╝██║██║  ██║╚██████╔╝${NC}"
            echo -e "  ${T1}╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ ${NC}"
            echo -e "${T1}================================${NC}"
            ;;
        SETUP)
            echo -e "${T1}==============================================${NC}"
            echo -e "  ${T1}███████╗███████╗████████╗██╗   ██╗██████╗ ${NC}"
            echo -e "  ${T1}██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${NC}"
            echo -e "  ${T1}███████╗█████╗     ██║   ██║   ██║██████╔╝${NC}"
            echo -e "  ${T1}╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${NC}"
            echo -e "  ${T1}███████║███████╗   ██║   ╚██████╔╝██║     ${NC}"
            echo -e "  ${T1}╚══════╝╚══════╝   ╚═╝    ╚═══╝   ╚═╝     ${NC}"
            echo -e "${T1}==============================================${NC}"
            ;;
        *)
            local label="DevKit"
            local full_text="${label} | ${type}"
            local padding=$(( (33 - ${#full_text}) / 2 ))
            local left_pad=""
            [ $padding -gt 0 ] && left_pad=$(printf '%*s' $padding "")
            echo -e "${T1}=================================${NC}"
            echo -e "${left_pad}${T1}${full_text}${NC}"
            echo -e "${T1}=================================${NC}"
            ;;
    esac
}

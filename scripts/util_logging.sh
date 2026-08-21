#!/bin/bash
# =============================================================================
# scripts/util_logging.sh
# Centralized logging utility for standardized shell output
#
# Provides color-coded logging functions (INFO, OK, WARN, ERROR, DEBUG)
# with support for timestamps, custom prefixes, and file-based logging.
#
# THIS FILE IS PROVIDED API. DevKit is a base kit, so every verb below exists
# for the project code built on top of it — a symbol with no in-tree caller is
# a feature, not dead code. scripts/verify_repo.sh check [provided-api] asserts the
# whole surface stays callable; extend it when you add a verb.
# =============================================================================

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
DIM='\033[2m'
TEAL='\033[38;2;45;212;191m'

# Load settings (defaults)
LOG_SHOW_TIME="${LOG_SHOW_TIME:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"

_log_base() {
    local type="$1" color="$2" symbol="$3" msg="$4"

    # 1. Resolve Log Path & Ensure Directory (Once per function call)
    local log_out=""
    if [[ -n "${LOG_FILE:-}" ]]; then
        log_out="${LOG_FILE}"
        [[ "${log_out}" != /* ]] && log_out="${WORKSPACE_PATH:-/workspace}/${log_out}"
        # Best-effort: logging must never crash the caller (e.g. under `set -e`).
        # If the directory cannot be created, silently disable file logging.
        mkdir -p "$(dirname "$log_out")" 2>/dev/null || log_out=""
    fi

    # 2. Metadata Pre-calculation
    local timestamp="" prefix=""
    [[ "${LOG_SHOW_TIME}" == "true" ]] && timestamp="${CYAN}[$(date '+%H:%M:%S')]${NC} "
    [[ -n "${LOG_PREFIX:-}" ]] && prefix="${CYAN}${LOG_PREFIX}${NC} "

    # 3. Stream Processing (Clean & Fast)
    while IFS= read -r line || [[ -n "$line" ]]; do
        local content="${color}[${type}]${NC}${symbol:+ ${symbol}}${line:+ $line}"
        local full_msg="${timestamp}${prefix}${content}"

        # Output to Console
        if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
            echo -e "$full_msg" >&2
        else
            echo -e "$full_msg"
        fi

        # Robust File Logging (ANSI Strip) — best-effort, never abort the caller.
        if [[ -n "$log_out" ]]; then
            echo -e "$full_msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$log_out" 2>/dev/null || true
        fi
    done <<< "$msg"
}

log_info()  { _log_base "INFO"  "${BLUE}"   ""   "$1"; }
log_ok()    { _log_base "OK"    "${GREEN}"  "✓"  "$1"; }
log_warn()  { _log_base "WARN"  "${YELLOW}" "⚠"  "$1"; }
log_error() { _log_base "ERROR" "${RED}"    "✗"  "$1"; }

# log_debug — the consumer of DEBUG_MODE (.env.example → compose → container).
log_debug() {
    if [ "${DEBUG_MODE}" = "true" ]; then
        _log_base "DEBUG" "${PURPLE}" "⚙" "$1"
    fi
}

# log_detail [message] - Indented auxiliary information (a hint under a finding)
log_detail() {
    echo -e "    ${CYAN}→${NC} $1"
}

# log_step_done [message] - Completion of a step
log_step_done() {
    echo -e "  ${GREEN}✓${NC} $1"
}

# devkit_enable_error_trap
#   Installs a diagnostic ERR trap that records WHERE a fatal abort occurred
#   (line + command) instead of dying silently. Intended for scripts that run
#   under `set -e` (the trap fires on the same conditions `set -e` exits on, so
#   guarded failures in if/&&/|| are unaffected). Logging only — it does not
#   change control flow. `set -E` makes the trap fire inside functions too.
#   Call once, after LOG_PREFIX is set.
devkit_enable_error_trap() {
    set -E
    trap 'devkit_err_rc=$?; log_error "aborted (exit ${devkit_err_rc}) at line ${LINENO}: ${BASH_COMMAND}"' ERR
}

# devkit_auto_color: honour NO_COLOR and non-terminal output.
# DevKit's diagnostics emit SGR escapes as literals throughout, so instead of
# threading a colour variable through every printf we strip them at the output
# boundary when stdout is not a terminal (CI logs, pipes, `> file`).
# Call once, early, from any script whose output a user may redirect.
devkit_auto_color() {
    [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ] || return 0
    command -v sed >/dev/null 2>&1 || return 0
    local re=$'s/\033\\[[0-9;]*m//g'   # $'\033': BSD sed has no \x1b
    # stderr first: the process substitution is forked before the redirection is
    # applied, so its >&2 still points at the REAL stderr. Warnings and errors
    # are the lines a user greps out of a redirected log — they must be plain too.
    exec 2> >(sed -E "$re" >&2)
    exec > >(sed -E "$re")
}

# The palette and the pre-formatted status tags are exported so project scripts
# can build their own lines (`echo -e "  $INFO ..."`) without re-deriving them.
export RED GREEN YELLOW BLUE CYAN PURPLE NC DIM TEAL

INFO="${BLUE}[INFO]${NC}"
OK="${GREEN}[OK]${NC}"
WARN="${YELLOW}[WARN]${NC}"
ERROR="${RED}[ERROR]${NC}"
DEBUG="${PURPLE}[DEBUG]${NC}"

export INFO OK WARN ERROR DEBUG

# =============================================================================
# DevKit Branding & Banners
# =============================================================================

# print_banner [type]
#   type: WELCOME (MOTD), DIAG (diagnostics), SETUP (maintenance),
#         GUIDE (help screens), or any label → boxed "DevKit | <label>".
print_banner() {
    local type="${1:-WELCOME}"

    case "$type" in
        WELCOME)
            echo -e "${TEAL}=================================================${NC}"
            echo -e "  ${TEAL}██████╗ ███████╗██╗   ██╗██╗  ██╗██╗████████╗${NC}"
            echo -e "  ${TEAL}██╔══██╗██╔════╝██║   ██║██║ ██╔╝██║╚══██╔══╝${NC}"
            echo -e "  ${TEAL}██║  ██║█████╗  ██║   ██║█████╔╝ ██║   ██║   ${NC}"
            echo -e "  ${TEAL}██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═██╗ ██║   ██║   ${NC}"
            echo -e "  ${TEAL}██████╔╝███████╗ ╚████╔╝ ██║  ██╗██║   ██║   ${NC}"
            echo -e "  ${TEAL}╚═════╝ ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚═╝   ╚═╝   ${NC}"
            echo -e "${TEAL}=================================================${NC}"
            ;;
        DIAG)
            echo -e "${TEAL}================================${NC}"
            echo -e "  ${TEAL}██████╗ ██╗ █████╗ ██████╗  ${NC}"
            echo -e "  ${TEAL}██╔══██╗██║██╔══██╗██╔════╝ ${NC}"
            echo -e "  ${TEAL}██║  ██║██║███████║██║  ███╗${NC}"
            echo -e "  ${TEAL}██║  ██║██║██╔══██║██║   ██║${NC}"
            echo -e "  ${TEAL}██████╔╝██║██║  ██║╚██████╔╝${NC}"
            echo -e "  ${TEAL}╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝ ${NC}"
            echo -e "${TEAL}================================${NC}"
            ;;
        SETUP)
            echo -e "${TEAL}==============================================${NC}"
            echo -e "  ${TEAL}███████╗███████╗████████╗██╗   ██╗██████╗ ${NC}"
            echo -e "  ${TEAL}██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${NC}"
            echo -e "  ${TEAL}███████╗█████╗     ██║   ██║   ██║██████╔╝${NC}"
            echo -e "  ${TEAL}╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${NC}"
            echo -e "  ${TEAL}███████║███████╗   ██║   ╚██████╔╝██║     ${NC}"
            echo -e "  ${TEAL}╚══════╝╚══════╝   ╚═╝    ╚═══╝   ╚═╝     ${NC}"
            echo -e "${TEAL}==============================================${NC}"
            ;;
        GUIDE)
            echo -e "${TEAL}====================================${NC}"
            echo -e "  ${TEAL}██╗  ██╗███████╗██╗     ██████╗ ${NC}"
            echo -e "  ${TEAL}██║  ██║██╔════╝██║     ██╔══██╗${NC}"
            echo -e "  ${TEAL}███████║█████╗  ██║     ██████╔╝${NC}"
            echo -e "  ${TEAL}██╔══██║██╔══╝  ██║     ██╔═══╝ ${NC}"
            echo -e "  ${TEAL}██║  ██║███████╗███████╗██║     ${NC}"
            echo -e "  ${TEAL}╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ${NC}"
            echo -e "${TEAL}====================================${NC}"
            ;;
        *)
            local label="DevKit"
            local full_text="${label} | ${type}"
            local padding=$(( (33 - ${#full_text}) / 2 ))
            local left_pad=""
            [ $padding -gt 0 ] && left_pad=$(printf '%*s' $padding "")
            echo -e "${TEAL}=================================${NC}"
            echo -e "${left_pad}${TEAL}${full_text}${NC}"
            echo -e "${TEAL}=================================${NC}"
            ;;
    esac
}

# print_section [title] - Creates a professional left-aligned divider
print_section() {
    local title="$1"
    local total_len=50
    local title_len=$(( ${#title} + 4 )) # +4 for "[ " and " ]"
    local pad_len=$(( total_len - title_len ))
    [ $pad_len -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "" | tr ' ' '=')

    printf "\n${TEAL}[ %s ] %s${NC}\n" "$title" "$padding"
}

# print_env_info - Displays a standardized project dashboard (Single Source of Truth)
print_env_info() {
    # 1. Detect Python Environment Mode
    local venv_status="${RED}None${NC}"
    local v_path="${WS_VENV:-${WORKSPACE_PATH:-/workspace}/install/.venv}"
    if [ -d "$v_path" ]; then
        if grep -q "include-system-site-packages = true" "${v_path}/pyvenv.cfg" 2>/dev/null; then
            venv_status="${YELLOW}SHARED${NC}"
        else
            venv_status="${BLUE}PURE${NC}"
        fi
    fi

    # 2. Path Normalization (Relative to Workspace Root)
    local root="${WS_ROOT:-${WORKSPACE_PATH:-/workspace}}"
    local v_rel="${v_path#$root/}"

    # 3. Identity + bind-mount writability. A UID/GID mismatch against the mounted
    #    workspace is the most common container failure, so surface it on entry.
    local my_uid my_gid ws_warn=""
    my_uid="$(id -u)"; my_gid="$(id -g)"
    if [ -d "$root" ] && [ ! -w "$root" ]; then
        ws_warn=" ${RED}(NOT writable — uid mismatch? run 'hwcheck')${NC}"
    fi

    # 4. ROS is reported only when it is actually installed: compose passes
    #    ROS_DISTRO to every service, so the non-ROS image would claim "humble".
    local ros_status="None"
    [ -d "/opt/ros/${ROS_DISTRO:-}" ] && ros_status="${ROS_DISTRO}"

    # 5. Output Unified Dashboard
    echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | User: ${PURPLE}$(whoami) (${my_uid}:${my_gid})${NC} | WS: ${GREEN}${root}${NC}${ws_warn} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC} | ROS: ${YELLOW}${ros_status}${NC} | Python: ${CYAN}${v_rel}${NC}(${venv_status})"
}

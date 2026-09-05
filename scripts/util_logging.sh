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

# _log_plain [fd] — true when colour must be dropped for that stream.
# THE single definition of that rule: the verbs below use it, and so do the
# in-container shell functions, which cannot call devkit_auto_color.
_log_plain() { [ -n "${NO_COLOR:-}" ] || [ ! -t "${1:-1}" ]; }

# _log_resolve_file — resolve LOG_FILE once per process into __DEVKIT_LOG_PATH
# (empty when unset or unusable). Once, not per line: dirname + mkdir on every
# line costs two forks before anything is printed.
_log_resolve_file() {
    [ "${__DEVKIT_LOG_SEEN-unset}" = "${LOG_FILE:-}" ] && return 0
    __DEVKIT_LOG_SEEN="${LOG_FILE:-}"; __DEVKIT_LOG_PATH=""
    # off/none/false/0 turn file logging off. An empty value cannot carry that
    # meaning: compose defines LOG_FILE for every service, so a caller with its
    # own default (the entrypoint's boot log) would see empty as "unset".
    case "${LOG_FILE:-}" in
        ""|off|none|false|0|OFF|NONE|FALSE) return 0 ;;
    esac
    case "$LOG_FILE" in
        /*) __DEVKIT_LOG_PATH="$LOG_FILE" ;;
        *)  __DEVKIT_LOG_PATH="${WORKSPACE_PATH:-/workspace}/${LOG_FILE}" ;;
    esac
    # Best-effort: logging must never crash the caller, so an unusable path
    # silently disables the file half.
    mkdir -p "${__DEVKIT_LOG_PATH%/*}" 2>/dev/null || __DEVKIT_LOG_PATH=""
}

# _log_write <fd> <line> <plain-line> — the single exit point for every verb:
# console on the given stream, LOG_FILE gets the colourless form. The plain
# string is BUILT by the caller, never stripped here: `echo | sed` would cost
# two more forks per line, and the entrypoint logs every boot line to a file.
_log_write() {
    if [ "$1" = 2 ]; then echo -e "$2" >&2; else echo -e "$2"; fi
    _log_resolve_file
    [ -n "${__DEVKIT_LOG_PATH:-}" ] || return 0
    # The FILE always carries a date and time, whatever LOG_SHOW_TIME says: that
    # knob is about console noise, while this file accumulates across container
    # restarts. printf's %()T is a builtin — no `date` fork per line.
    local when; printf -v when '%(%F %T)T' -1
    echo -e "${when} $3" >> "$__DEVKIT_LOG_PATH" 2>/dev/null
    return 0
}

_log_base() {
    local type="$1" color="$2" symbol="$3" msg="$4"

    # Colour follows the stream this line lands on, so `cmd 2> err.log` and
    # `cmd | tee out.log` are both plain. WARN, ERROR and DEBUG are
    # diagnostics: they go to stderr, where they cannot corrupt piped data.
    local nc="${NC}" cyan="${CYAN}" fd=1
    case "$type" in ERROR|WARN|DEBUG) fd=2 ;; esac
    _log_plain "$fd" && { color=""; nc=""; cyan=""; }

    local stamp="" prefix="" prefix_plain=""
    if [[ "${LOG_SHOW_TIME}" == "true" ]]; then
        local now; printf -v now '%(%H:%M:%S)T' -1
        stamp="${cyan}[${now}]${nc} "
    fi
    if [[ -n "${LOG_PREFIX:-}" ]]; then
        prefix="${cyan}${LOG_PREFIX}${nc} "; prefix_plain="${LOG_PREFIX} "
    fi

    # A multi-line message gets the tag on every line, so a captured command's
    # output stays attributable. Two spaces at the START — content sits at two,
    # headings at column 0 (print_section), a nested hint at four (log_detail).
    while IFS= read -r line || [[ -n "$line" ]]; do
        local tail="${symbol:+ ${symbol}}${line:+ $line}"
        _log_write "$fd" "  ${stamp}${prefix}${color}[${type}]${nc}${tail}" \
                         "${prefix_plain}[${type}]${tail}"
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
    local c="${CYAN}" n="${NC}"; _log_plain && { c=""; n=""; }
    _log_write 1 "    ${c}→${n} $1" "    → $1"
}

# log_step_done [message] — completion of a step.
log_step_done() {
    local c="${GREEN}" n="${NC}"; _log_plain && { c=""; n=""; }
    _log_write 1 "  ${c}✓${n} $1" "  ✓ $1"
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

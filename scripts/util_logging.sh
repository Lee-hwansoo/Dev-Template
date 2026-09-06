#!/bin/bash
# =============================================================================
# scripts/util_logging.sh — the log verbs, banners and palette every DevKit
# script uses. Knobs: LOG_PREFIX (which component is speaking; every executed
# script sets one), LOG_SHOW_TIME (console timestamps — the file is always
# stamped), DEBUG_MODE, NO_COLOR, and LOG_FILE, a path (workspace-relative
# unless absolute) that also receives every line without colour, or
# off/none/false/0 to disable the file half.
#
# PROVIDED API: a verb with no in-tree caller is a feature, not dead code.
# check [provided-api] keeps the surface callable — extend it when you add one.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
DIM='\033[2m'
TEAL='\033[38;2;45;212;191m'

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
    # restarts. printf's %()T is a builtin — no `date` fork per line — but it
    # arrived in bash 4.2, and macOS still ships 3.2, where it printed nothing.
    local when=""
    if [ "${__DEVKIT_PRINTF_TIME:-}" = 1 ]; then printf -v when '%(%F %T)T' -1
    else when="$(date '+%F %T')"; fi
    echo -e "${when} $3" >> "$__DEVKIT_LOG_PATH" 2>/dev/null
    return 0
}

# printf '%()T' is bash 4.2+; probe once so the per-line path stays fork-free
# where it can be, and falls back to `date` on the shells that lack it.
if [ -z "${__DEVKIT_PRINTF_TIME:-}" ]; then
    if printf -v __devkit_t '%(%F)T' -1 2>/dev/null && [ -n "${__devkit_t:-}" ]; then
        __DEVKIT_PRINTF_TIME=1
    else __DEVKIT_PRINTF_TIME=0; fi
    unset __devkit_t
fi

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

# log_detail — an indented hint under a finding. Redirect it (`>&2`) to keep a
# hint with the error it explains; the colour check follows fd 1.
log_detail() {
    local c="${CYAN}" n="${NC}"; _log_plain && { c=""; n=""; }
    _log_write 1 "    ${c}→${n} $1" "    → $1"
}

# log_step_done [message] — completion of a step.
log_step_done() {
    local c="${GREEN}" n="${NC}"; _log_plain && { c=""; n=""; }
    _log_write 1 "  ${c}✓${n} $1" "  ✓ $1"
}

# devkit_enable_error_trap — log WHERE a `set -e` abort happened (line +
# command) instead of dying silently. Logging only; `set -E` reaches functions.
# Call once, after LOG_PREFIX.
devkit_enable_error_trap() {
    set -E
    trap 'devkit_err_rc=$?; log_error "aborted (exit ${devkit_err_rc}) at line ${LINENO}: ${BASH_COMMAND}"' ERR
}

# devkit_auto_color — strip SGR escapes at the output boundary when stdout is
# not a terminal, so raw `echo -e` lines need no colour variable threaded
# through them. Call once, early, in any script a user may redirect.
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

# Exported so project scripts can build their own lines: echo -e "  $INFO …"
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

# print_section [title] — a left-aligned section divider at column 0.
print_section() {
    local title="$1"
    local total_len=50
    local title_len=$(( ${#title} + 4 )) # +4 for "[ " and " ]"
    local pad_len=$(( total_len - title_len ))
    [ $pad_len -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "" | tr ' ' '=')

    printf "\n${TEAL}[ %s ] %s${NC}\n" "$title" "$padding"
}

# print_env_info — the one-line project dashboard the MOTD and the diagnostics
# both print, so "which workspace am I in" has a single answer.
print_env_info() {
    local venv_status="${RED}None${NC}"
    local v_path="${WS_VENV:-${WORKSPACE_PATH:-/workspace}/install/.venv}"
    if [ -d "$v_path" ]; then
        if grep -q "include-system-site-packages = true" "${v_path}/pyvenv.cfg" 2>/dev/null; then
            venv_status="${YELLOW}SHARED${NC}"
        else
            venv_status="${BLUE}PURE${NC}"
        fi
    fi

    local root="${WS_ROOT:-${WORKSPACE_PATH:-/workspace}}"
    local v_rel="${v_path#$root/}"

    # A UID/GID mismatch against the mounted workspace is the most common
    # container failure, so surface writability on entry.
    local my_uid my_gid ws_warn=""
    my_uid="$(id -u)"; my_gid="$(id -g)"
    if [ -d "$root" ] && [ ! -w "$root" ]; then
        ws_warn=" ${RED}(NOT writable — uid mismatch? run 'hwcheck')${NC}"
    fi

    # ROS is reported only when actually installed: compose passes ROS_DISTRO to
    # every service, so the non-ROS image would otherwise claim "humble".
    local ros_status="None"
    [ -d "/opt/ros/${ROS_DISTRO:-}" ] && ros_status="${ROS_DISTRO}"

    echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | User: ${PURPLE}$(whoami) (${my_uid}:${my_gid})${NC} | WS: ${GREEN}${root}${NC}${ws_warn} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC} | ROS: ${YELLOW}${ros_status}${NC} | Python: ${CYAN}${v_rel}${NC}(${venv_status})"
}

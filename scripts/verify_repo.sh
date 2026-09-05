#!/bin/bash
# =============================================================================
# scripts/verify_repo.sh
# Fast repository validation for DevKit.
#
# Every check below asserts a CONTRACT that a past regression actually broke —
# not the mere presence of a string. Checks are ordered cheap-first and the
# whole suite is expected to finish in about a second offline (measured: ~1.1 s,
# dominated by the per-script process spawns in [cli-convention]).
#
# Checks are identified by a STABLE SLUG ([env-bridge], [provided-api], …), not
# by position: docs and code comments cite them, and renumbering on every insert
# is how those references went stale before.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

# Strip colour when piped/redirected or NO_COLOR is set. Inlined rather than
# sourced: this script must not depend on the files it is validating.
if { [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; } && command -v sed >/dev/null 2>&1; then
    _nocolor=$'s/\033\\[[0-9;]*m//g'   # $'\033': BSD sed has no \x1b
    exec 2> >(sed -E "$_nocolor" >&2)     # log_err writes here; strip it too
    exec > >(sed -E "$_nocolor")
fi

FAILED=0
log_ok()  { echo -e "  \033[0;32m[OK]\033[0m $*"; }
log_err() { echo -e "  \033[0;31m[ERROR]\033[0m $*" >&2; FAILED=$((FAILED+1)); }
log_info(){ echo -e "  \033[0;34m[INFO]\033[0m $*"; }

log_info "Verifying DevKit repository structure, shell syntax, and contracts..."

# =============================================================================
# [required-files] Required files & executable permissions
# =============================================================================
for f in \
    Makefile docker-compose.common.yml docker-compose.dev.yml \
    docker/Dockerfile docker/entrypoint.sh docker/prod_entrypoint.sh \
    config/util_aliases.sh config/util_paths.sh config/devkit_make_completion.bash \
    scripts/check_env.sh scripts/setup_gpu.sh scripts/util_apt_helper.sh \
    scripts/apptainer_bake.sh scripts/apptainer_run.sh scripts/slurm_run.sh \
    dependencies/apt.txt dependencies/apt_ros.txt \
    src/example/starter_node.cpp src/example/starter_node.py
do
    [ -f "$f" ] || log_err "Missing required file: $f"
done

for f in docker/entrypoint.sh docker/prod_entrypoint.sh \
          scripts/apptainer_bake.sh scripts/apptainer_run.sh \
          scripts/slurm_run.sh scripts/verify_repo.sh; do
    [ -f "$f" ] && [ ! -x "$f" ] && log_err "Missing executable permission: $f"
done

[ "$FAILED" -eq 0 ] && log_ok "All required repository files and permissions present."

# =============================================================================
# [shell-syntax] Shell script syntax check
# =============================================================================
sh_errors=0
while IFS= read -r -d '' script; do
    bash -n "$script" 2>/dev/null || { log_err "Syntax error in $script"; sh_errors=$((sh_errors+1)); }
done < <(find . \( -name "*.sh" -o -name "*.bash" \) -not -path "*/.*" -print0)
[ "$sh_errors" -eq 0 ] && log_ok "All shell scripts passed syntax check (bash -n)."

# =============================================================================
# [phony-targets] Makefile dry-run: every .PHONY target must be resolvable
# =============================================================================
# The awk below assumes a single-line .PHONY; a wrapped declaration would make
# this AND check [tab-completion] under-count together and still "pass" — refuse the wrap.
grep -q '^\.PHONY:.*\\$' Makefile \
    && log_err ".PHONY uses a line continuation — the parsers here and in tab completion assume one line."
phony_targets="$(awk '/^\.PHONY:/ { sub(/^\.PHONY:[[:space:]]*/, ""); print }' Makefile)"
bad_targets=()
for t in $phony_targets; do
    grep -qE "^${t}:" Makefile || bad_targets+=("$t")
done
if [ "${#bad_targets[@]}" -eq 0 ] && make -n help >/dev/null 2>&1; then
    log_ok "Makefile parses and every .PHONY target is defined ($(echo "$phony_targets" | wc -w) targets)."
else
    log_err "Makefile parse error or .PHONY entries without a rule: ${bad_targets[*]:-<none>}"
fi

# =============================================================================
# [find-quit] find(1) misuse: '-quit' without '-print' silently returns nothing
# =============================================================================
# (this file is excluded: it necessarily mentions the pattern it lints for)
quit_misuse="$(grep -rnE --include='*.sh' --include='*.bash' --exclude='verify_repo.sh' \
    -e '-quit' . | grep -v -- '-print -quit' || true)"
if [ -n "$quit_misuse" ]; then
    log_err "find ... -quit without -print (the implicit -print is suppressed, output is always empty):"
    sed 's/^/    /' <<< "$quit_misuse" >&2
else
    log_ok "No 'find -quit' misuse (every early-exit find keeps an explicit -print)."
fi

# =============================================================================
# [host-detect-contract] Host detection contract: check_env.sh must emit every HOST_*/WSL_* key
#     that docker-compose consumes, otherwise mounts silently fall back to
#     placeholder defaults (lost GPU/X11/Wayland/ssh-agent passthrough).
# =============================================================================
# `|| true`: a broken check_env.sh must surface as THIS check failing, not as
# the whole suite aborting under set -e with no output.
emitted="$(bash scripts/check_env.sh --makefile 2>/dev/null | awk -F' :=' '{print $1}' || true)"
# Anti-vacuous: an empty emit list means the detector broke, not "nothing to check".
[ "$(wc -w <<< "$emitted")" -ge 20 ] \
    || log_err "check_env.sh emitted $(wc -w <<< "$emitted") keys (expected ≥20) — detector output collapsed."
missing_emits=()
for var in $(grep -ohE '\$\{(HOST_[A-Z0-9_]+|WSL_LIB_DIR_MOUNT)' docker-compose*.yml | tr -d '${' | sort -u); do
    grep -qx "$var" <<< "$emitted" || missing_emits+=("$var")
done
if [ "${#missing_emits[@]}" -eq 0 ]; then
    log_ok "Host detection contract: all compose HOST_*/WSL_* variables are emitted by check_env.sh."
else
    log_err "check_env.sh does not emit compose variable(s): ${missing_emits[*]}"
fi

# =============================================================================
# [apt-tag-filter] APT tag-filter contract (dependencies/apt*.txt tag system)
#     - no ros_distro  → apt_ros.txt must be skipped entirely
#     - runtime        → '# dev' / '# gui' entries must never appear
# =============================================================================
apt_dry() { DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR="${ROOT_DIR}/dependencies" \
            bash scripts/util_apt_helper.sh install-packages "$@" 2>/dev/null; }
apt_errors=0
# Each selection is resolved ONCE; the loop below must not re-invoke the helper.
apt_all_nodistro="$(apt_dry all || true)"
apt_runtime_humble="$(apt_dry runtime humble || true)"
# Anti-vacuous: empty selections would make every assertion below pass trivially.
{ [ -n "$apt_all_nodistro" ] && [ -n "$apt_runtime_humble" ]; } \
    || { log_err "APT dry-run selection came back empty — util_apt_helper.sh or the manifests broke."; apt_errors=1; }
grep -q '^ros-' <<< "$apt_all_nodistro" && { log_err "install-packages without a distro must not select ROS packages (non-ROS image stages have no ROS apt repo)."; apt_errors=1; }
for tagged in $(awk -F'#' '/#[^#]*(dev|gui)([[:space:],]|$)/ && !/^[[:space:]]*#/ {gsub(/[[:space:]]/,"",$1); print $1}' dependencies/apt_ros.txt); do
    if grep -qF "${tagged//\$\{ROS_DISTRO\}/humble}" <<< "$apt_runtime_humble"; then
        log_err "runtime filter leaked a dev/gui package: ${tagged}"
        apt_errors=1
    fi
done
[ "$apt_errors" -eq 0 ] && log_ok "APT tag-filter contract holds (no-distro selection excludes ros-*, runtime excludes dev/gui)."

# =============================================================================
# [gpu-env-persist] GPU environment persistence: `docker exec` shells do not run the
#     entrypoint, so setup_gpu.sh must leave its env in GPU_ENV_FILE.
# =============================================================================
gpu_env_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
if ( GPU_ENV_FILE="${gpu_env_probe}/gpu_env.sh" HOME="$gpu_env_probe" \
     bash -c 'source scripts/setup_gpu.sh cpu' >/dev/null 2>&1 ) \
   && grep -q "LIBGL_ALWAYS_SOFTWARE" "${gpu_env_probe}/gpu_env.sh" 2>/dev/null; then
    log_ok "setup_gpu.sh persists the GPU environment for non-entrypoint shells."
else
    log_err "setup_gpu.sh did not write GPU_ENV_FILE; 'make shell' sessions would lose GPU settings."
fi
# The persisted file must PREPEND, never assign: it is generated during boot,
# before ROS is sourced, so a whole-path snapshot wipes /opt/ros/<distro>/lib in
# every shell that re-reads it — `import rclpy` then dies on a missing
# librcl_action.so. Reproduced in a running container before this was fixed.
gpu_ld_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
( LD_LIBRARY_PATH=/probe/boot GPU_ENV_FILE="${gpu_ld_probe}/gpu_env.sh" HOME="$gpu_ld_probe" \
  bash -c 'source scripts/setup_gpu.sh igpu' ) >/dev/null 2>&1
if grep -qE '^export LD_LIBRARY_PATH=' "${gpu_ld_probe}/gpu_env.sh" 2>/dev/null; then
    log_err "setup_gpu.sh persists LD_LIBRARY_PATH as an assignment; re-sourcing it drops the ROS library path."
elif [ -s "${gpu_ld_probe}/gpu_env.sh" ]; then
    kept="$(LD_LIBRARY_PATH=/opt/ros/probe/lib bash -c "source '${gpu_ld_probe}/gpu_env.sh'; printf %s \"\$LD_LIBRARY_PATH\"" 2>/dev/null || true)"
    case "$kept" in
        *"/opt/ros/probe/lib"*) log_ok "Persisted GPU env prepends to LD_LIBRARY_PATH (the ROS path survives a re-source)." ;;
        *) log_err "sourcing the persisted GPU env lost the pre-existing LD_LIBRARY_PATH (got: ${kept:-empty})." ;;
    esac
fi
rm -rf "$gpu_ld_probe"
rm -rf "$gpu_env_probe"

# =============================================================================
# [build-entrypoints] Build entry points must be callable from non-interactive shells.
#     Aliases are not expanded inside functions during `docker build`.
# =============================================================================
non_interactive_callables="$(bash -lc '
    WORKSPACE_PATH='"${ROOT_DIR}"' source config/util_aliases.sh 2>/dev/null
    for fn in cbuild mbuild mksync mkenv; do
        printf "%s=%s " "$fn" "$(type -t "$fn" 2>/dev/null || echo missing)"
    done' 2>/dev/null)"
if [[ "$non_interactive_callables" == *"cbuild=function"* && "$non_interactive_callables" == *"mbuild=function"* \
   && "$non_interactive_callables" == *"mksync=function"* ]]; then
    log_ok "Build entry points (cbuild/mbuild/mksync) are functions — callable from docker build."
else
    log_err "cbuild/mbuild/mksync must be functions, not aliases: ${non_interactive_callables}"
fi

# =============================================================================
# [detector-cache] Detector cache safety: the write must be atomic and a failed probe fatal.
#     A partial cache would be reused forever (wildcard guard) and every host
#     mount would silently degrade to its placeholder default.
# =============================================================================
if grep -q 'mktemp "$(DETECTED_ENV_FILE)' Makefile && grep -q 'DETECT_STATUS),fail' Makefile; then
    log_ok "Host detection cache is written atomically and fails the build on error."
else
    log_err "Makefile must write detected-env.mk via mktemp+mv and \$(error) on failure."
fi

# =============================================================================
# [advertised-shortcuts] Advertised vs. defined commands: every shortcut named in the in-container
#      help or the MOTD must actually resolve in an interactive shell.
# =============================================================================
# Extract only the NAME column of the help/MOTD tables, not every quoted string
# in the file (a literal like "prod" in unrelated code is not a shortcut).
# Extracted per source so one collapsing (e.g. the help printf column width
# changes and the sed stops matching) is caught instead of silently shrinking
# the checked set to whatever the other source still yields.
adv_names() { tr '/' '\n' | sed 's/\[.*//; s/<.*//' | tr -d ' ' | grep -E '^[a-z_][a-z_0-9]*$'; }
adv_help="$(sed -n 's/.*%-20s.*\\n" *"\([^"]*\)".*/\1/p' config/util_aliases.sh | adv_names || true)"
adv_motd="$(sed -n 's/^ *"\([a-z_0-9 /]*\)|.*/\1/p' scripts/show_welcome.sh | adv_names || true)"
[ "$(wc -w <<< "$adv_help")" -ge 20 ] \
    || log_err "Help-text shortcut extraction collapsed ($(wc -w <<< "$adv_help") names, expected ≥20) — did the printf format change?"
[ "$(wc -w <<< "$adv_motd")" -ge 5 ] \
    || log_err "MOTD shortcut extraction collapsed ($(wc -w <<< "$adv_motd") names, expected ≥5)."
advertised="$(printf '%s\n%s\n' "$adv_help" "$adv_motd" | sort -u | sed '/^$/d')"
defined="$(bash --norc -ic 'WORKSPACE_PATH='"$ROOT_DIR"' source config/util_aliases.sh >/dev/null 2>&1
    compgen -a; compgen -A function' 2>/dev/null | sort -u || true)"
undefined="$(comm -23 <(echo "$advertised") <(echo "$defined") | grep -vE '^(help|noetic|share)$' || true)"
if [ -z "$undefined" ]; then
    log_ok "Every advertised in-container shortcut resolves to an alias or function."
else
    log_err "Advertised but undefined shortcut(s): $(echo "$undefined" | tr '\n' ' ')"
fi

# =============================================================================
# [env-bridge] Runtime env must reach non-login shells (`make shell` = docker exec bash,
#      which reads /etc/bash.bashrc but never /etc/profile.d).
# =============================================================================
bridge_errors=0
grep -q '__DEVKIT_ENV_BRIDGE' docker/entrypoint.sh || { log_err "entrypoint.sh must bridge /etc/profile.d into /etc/bash.bashrc (interactive shells)."; bridge_errors=1; }
# Non-interactive bash reads only $BASH_ENV — and it must NOT point at ~/.bashrc,
# whose stock "return if not interactive" guard discards everything after it.
grep -q 'BASH_ENV=/etc/devkit/shell-env.sh' docker/Dockerfile \
    || { log_err "Dockerfile BASH_ENV must point at the guard-free hook (/etc/devkit/shell-env.sh), not ~/.bashrc."; bridge_errors=1; }
grep -q 'DEVKIT_SHELL_ENV' docker/entrypoint.sh \
    || { log_err "entrypoint.sh must generate the BASH_ENV hook for non-interactive shells."; bridge_errors=1; }
# The image stages the rosdep cache as root; without seeding it, every non-root
# shell fails `mksync` with "rosdep has not been initialized".
grep -q 'seed_rosdep_cache' docker/entrypoint.sh \
    || { log_err "entrypoint.sh must seed /opt/ros_cache into the container user's HOME."; bridge_errors=1; }
# init_ros_env.sh is reached only through ~/.bashrc: its DDS settings must be
# persisted too, or scripted runs silently use a different RMW configuration.
grep -q 'devkit-ros.sh' docker/entrypoint.sh \
    || { log_err "entrypoint.sh must persist ROS/DDS env (CYCLONEDDS_URI, RMW) for non-interactive shells."; bridge_errors=1; }
# Structural parity: one file defines the environment for every shell flavour.
# Match the sourcing construct, not the filename: a comment mentioning
# init_bash.sh would satisfy a bare grep for the path.
grep -qE '\. +"\$\{WORKSPACE_PATH:-/workspace\}/config/init_bash\.sh"' docker/entrypoint.sh \
    || { log_err "The shared shell hook must source config/init_bash.sh, or non-interactive shells lose ROS/venv/paths."; bridge_errors=1; }
grep -q 'cat .*config/init_bash.sh >>' docker/Dockerfile \
    && { log_err "Dockerfile must not bake a COPY of init_bash.sh into ~/.bashrc; point at the live hook instead."; bridge_errors=1; }
# Shell-independent path: rc hooks reach bash only, so the entrypoint must also
# offer an exec-wrapper mode for bare binaries, sh and compose/k8s commands.
grep -qF '"--env"' docker/entrypoint.sh \
    || { log_err "entrypoint.sh must provide '--env <cmd>' so non-bash processes get the DevKit environment."; bridge_errors=1; }
# Pattern-exact on purpose: `make exec` probes the running image for --env support
# before using it, and a mis-quoted pattern (it was '"'"'"--env"'"'"' once) never
# matches, silently degrading every `make exec` to a plain bash shell.
grep -qF "grep -q '\"--env\"' /entrypoint.sh" Makefile \
    || { log_err "'make exec' must probe /entrypoint.sh for the exact pattern the entrypoint carries ('\"--env\"'), or it always falls back to bash."; bridge_errors=1; }
# Behavioural: sourcing it without a terminal must be SILENT (no banner
# polluting script stdout) and must still resolve the environment.
noninteractive_out="$(cd "$ROOT_DIR" && WORKSPACE_PATH="$ROOT_DIR" bash -c 'source config/init_bash.sh' 2>/dev/null || true)"
noninteractive_marker="$(cd "$ROOT_DIR" && WORKSPACE_PATH="$ROOT_DIR" bash -c 'source config/init_bash.sh >/dev/null 2>&1; printf %s "${__DEVKIT_ENV_READY:-}"' 2>/dev/null || true)"
[ -n "$noninteractive_out" ] && { log_err "config/init_bash.sh writes to stdout in a non-interactive shell (would corrupt scripted output)."; bridge_errors=1; }
# Interactive but with no terminal — `docker exec … bash -ic '<cmd>'` — must stay
# silent too: the MOTD used to be reprinted over every scripted call's output.
motd_leak="$(bash --norc -ic "WORKSPACE_PATH='${ROOT_DIR}' source config/init_bash.sh; :" </dev/null 2>/dev/null | head -3 || true)"
[ -z "$motd_leak" ] || { log_err "the MOTD prints in an interactive shell with no terminal; scripted 'bash -ic' output gets a banner."; bridge_errors=1; }
[ -z "$noninteractive_marker" ] && { log_err "config/init_bash.sh does not resolve the environment in a non-interactive shell."; bridge_errors=1; }
# Functions live PER PROCESS: a child shell inherits the environment but not the
# definitions. With the readiness marker already exported, `make exec CMD='mksync'`
# reached a shell where the guard short-circuited and nothing was defined.
child_fns="$(__DEVKIT_ENV_READY="$ROOT_DIR" WORKSPACE_PATH="$ROOT_DIR" bash -c \
    'source config/init_bash.sh >/dev/null 2>&1
     for f in mksync cbuild mbuild hwcheck check_deps; do declare -F "$f" >/dev/null || echo "$f"; done' \
    2>/dev/null || true)"
[ -z "$child_fns" ] \
    || { log_err "shell functions missing in a child shell ($(tr '\n' ' ' <<< "$child_fns")): 'make exec CMD=mksync' would fail."; bridge_errors=1; }
[ "$bridge_errors" -eq 0 ] && log_ok "Runtime env reaches login, interactive and non-interactive shells; rosdep cache seeded."

# =============================================================================
# [gpg-anchor] GPG trust anchor: the pinned fingerprint must exist and stay in sync with
#      the updater that maintains it (`make update-gpg`).
# =============================================================================
# `gpg --dearmor -o FILE` prompts "Overwrite?" on /dev/tty when FILE exists —
# and mktemp pre-creates it, while `docker build` has no tty. Every dearmor call
# must therefore carry --yes. This silently broke every ROS 1 image build.
tty_bound="$(grep -nE '^[^#]*gpg([^|#]*)--dearmor' scripts/*.sh config/*.sh 2>/dev/null \
    | grep -v 'verify_repo.sh' | grep -v -- '--yes' || true)"
if [ -n "$tty_bound" ]; then
    log_err "a 'gpg --dearmor' call lacks --yes and will abort under 'docker build' (no /dev/tty):"
    sed 's/^/    /' <<< "$tty_bound" >&2
fi
pinned_fp="$(awk -F'"' '/^ROS_GPG_FINGERPRINT=/{print $2; exit}' scripts/util_apt_helper.sh)"
if [ -n "$pinned_fp" ] \
   && grep -q "STRICT_GPG_CHECK" scripts/util_apt_helper.sh \
   && grep -q '\^ROS_GPG_FINGERPRINT=' scripts/setup_ros_gpg.sh; then
    log_ok "ROS key is fingerprint-pinned (${pinned_fp:0:16}…) and 'make update-gpg' targets it."
else
    log_err "ROS GPG pin missing or setup_ros_gpg.sh no longer matches util_apt_helper.sh."
fi

# =============================================================================
# [knob-consumers] Documented knobs need a live consumer, not just a definition. A logging
#       helper with no in-tree caller still implements DEBUG_MODE — deleting it
#       as "dead code" silently removes the documented feature.
# =============================================================================
knob_consumer_errors=0
if grep -q '^DEBUG_MODE=' .env.example; then
    grep -q '^log_debug()' scripts/util_logging.sh \
        || { log_err "DEBUG_MODE is documented in .env.example but log_debug() no longer exists."; knob_consumer_errors=1; }
    # 2>&1: debug is a diagnostic and goes to stderr, where it cannot corrupt
    # the stdout of a script that emits data (check_env.sh --makefile).
    ( set -euo pipefail; source scripts/util_logging.sh; DEBUG_MODE=true; log_debug probe ) 2>&1 | grep -q probe \
        || { log_err "DEBUG_MODE=true does not produce log_debug output."; knob_consumer_errors=1; }
    ( set -euo pipefail; source scripts/util_logging.sh; DEBUG_MODE=true; log_debug probe ) 2>/dev/null | grep -q probe \
        && { log_err "log_debug writes to stdout; a data-emitting script would ship debug lines as data."; knob_consumer_errors=1; }
fi
[ "$knob_consumer_errors" -eq 0 ] && log_ok "Documented knobs still have a working consumer (DEBUG_MODE → log_debug)."

# =============================================================================
# [env-reaches-detector] .env must actually reach the detector. make's `export` does not apply to
#       $(shell ...), so check_env.sh reads .env itself; and the cache it feeds
#       is included after .env, so it has to be invalidated when .env changes.
#       Get either wrong and `ROS_DISTRO=noetic` silently builds a humble image.
# =============================================================================
probe_env="$(mktemp "${TMPDIR:-/tmp}/devkit-env.XXXXXX")"
printf 'ROS_DISTRO=noetic\n' > "$probe_env"
# Capture first: `grep -q` exits on the first match, and the SIGPIPE that kills
# check_env.sh would fail the pipeline under `set -o pipefail`.
# Unset first: an explicit environment variable outranks .env by design, and
# `make verify` exports ROS_DISTRO into the recipe — without this the probe tests
# make's export instead of the .env reader, and `make verify` fails while a bare
# `bash scripts/verify_repo.sh` passes.
probe_out="$( unset ROS_DISTRO BASE_IMAGE
    DEVKIT_ENV_FILE="$probe_env" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
if grep -qx 'ROS_DISTRO := noetic' <<< "$probe_out"; then
    log_ok "check_env.sh honours ROS_DISTRO from .env (make's export never reaches \$(shell))."
else
    log_err "check_env.sh ignores .env: ROS_DISTRO/BASE_IMAGE fall back to the humble default and get cached."
fi
rm -f "$probe_env"
grep -q '\.env -nt "\$(DETECTED_ENV_FILE)"' Makefile \
    || log_err "the detection cache must be regenerated when .env is newer; it is included after .env and would override it."

# =============================================================================
# [provided-api] util_logging.sh is PROVIDED API, not application code. DevKit is a base
#       kit, so a verb with no in-tree caller still ships as a feature — the
#       rule check [knob-consumers] states for DEBUG_MODE, applied to the whole surface.
#       Probed by CALLING it: a rename, a syntax slip or a "dead code" sweep
#       fails here instead of silently shrinking what projects can rely on.
# =============================================================================
api_errors=0
for fn in log_info log_ok log_warn log_error log_debug log_detail log_step_done \
          devkit_enable_error_trap devkit_auto_color print_banner print_section print_env_info; do
    grep -q "^${fn}()" scripts/util_logging.sh \
        || { log_err "util_logging.sh no longer defines ${fn}() — it is provided API for project code."; api_errors=1; }
done
# One bash per assertion group, not per symbol: the whole suite budget is ~1 s.
api_out="$(bash -c 'source scripts/util_logging.sh
    log_detail probe_detail; log_step_done probe_step; print_banner "Custom Label"' 2>/dev/null || true)"
for want in probe_detail probe_step 'DevKit | Custom Label'; do
    grep -qF -- "$want" <<< "$api_out" \
        || { log_err "util_logging.sh API probe lost '${want}' (log_detail / log_step_done / print_banner <label>)."; api_errors=1; }
done
# Each documented banner type must render its OWN wordmark. Dropping a case is
# silent otherwise: it falls through to the generic "DevKit | GUIDE" box, which
# is still 3 valid lines — so assert block-art (█) AND per-type uniqueness.
banner_probe="$(bash -c 'source scripts/util_logging.sh
    for t in WELCOME DIAG SETUP GUIDE; do printf "%s:" "$t"; print_banner "$t" | sed -n 2p; done' 2>/dev/null || true)"
{ [ "$(grep -c "█" <<< "$banner_probe")" -eq 4 ] \
  && [ "$(cut -d: -f2- <<< "$banner_probe" | sort -u | wc -l)" -eq 4 ]; } \
    || { log_err "print_banner lost a wordmark — WELCOME/DIAG/SETUP/GUIDE must each render distinct block art, not the generic box."; api_errors=1; }
# LOG_FILE must capture what a post-mortem needs — the hint under a finding and
# the step markers, not just the tagged verbs — and it must never contain the
# escapes the console got. Both were true only for _log_base before.
file_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
bash -c "source scripts/util_logging.sh
    export LOG_FILE='$file_probe/run.log'; LOG_PREFIX='[T]'
    log_error finding; log_detail explanation; log_step_done step" >/dev/null 2>&1
for want in finding explanation step; do
    grep -qF "$want" "$file_probe/run.log" 2>/dev/null \
        || { log_err "LOG_FILE lost the '${want}' line; a captured log must hold hints and steps too."; api_errors=1; }
done
# Every file line carries a date and time whatever LOG_SHOW_TIME says: the file
# accumulates across container restarts, so an undated entry places nothing.
[ "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$file_probe/run.log" 2>/dev/null)" -eq 3 ] \
    || { log_err "LOG_FILE lines are not all timestamped (expected 3 dated lines)."; api_errors=1; }
# …and it must be switchable off: compose defines LOG_FILE for every service, so
# an empty value cannot mean "off" for a caller that has its own default.
# WORKSPACE_PATH points at the probe, so an unhonoured sentinel WOULD leave a
# file there — without it the check passes for the wrong reason.
bash -c "source scripts/util_logging.sh
    export WORKSPACE_PATH='$file_probe' LOG_FILE=off; log_ok probe" >/dev/null 2>&1
[ ! -e "$file_probe/off" ] \
    || { log_err "LOG_FILE=off is treated as a path; file logging cannot be switched off."; api_errors=1; }
rm -rf "$file_probe"
# The file half must append the PLAIN argument. Not asserted by reading the
# file: this suite never runs on a terminal, so the console string carries no
# colour to leak there — only the structure can be checked.
grep -qE '\$3" >> "\$__DEVKIT_LOG_PATH"' scripts/util_logging.sh \
    || { log_err "_log_write no longer appends its plain argument to LOG_FILE; a captured log would carry ANSI."; api_errors=1; }

# Every executed script that logs says WHO is speaking: its lines land in
# `docker logs`, a make run or a boot log next to other components' output.
# The exemptions are structural, not oversights:
#   sourced-only libraries inherit the caller's prefix;
#   verify_repo.sh and util_apt_helper.sh carry private verbs (they cannot
#     depend on this file, or only one file is bind-mounted in their layer);
#   util_aliases.sh is sourced into the USER's shell, where a top-level
#     assignment would tag every later line and the commands are the user's own.
for prefix_file in scripts/*.sh docker/*.sh config/*.sh; do
    grep -qE '\blog_(ok|info|warn|error|debug) ' "$prefix_file" || continue
    case "$prefix_file" in
        scripts/util_logging.sh|scripts/util_gpu_detect.sh|scripts/util_sif_common.sh) continue ;;
        scripts/verify_repo.sh|scripts/util_apt_helper.sh) continue ;;
        config/util_paths.sh|config/util_aliases.sh) continue ;;
    esac
    grep -q 'LOG_PREFIX=' "$prefix_file" \
        || { log_err "${prefix_file} logs without a LOG_PREFIX; its lines cannot be attributed."; api_errors=1; }
done
# Values are bracketed Title Case, so a line reads as "[Component] [OK] …".
# --exclude this file: the pattern below is a check, not a prefix.
bad_prefix="$(grep -rhoE --exclude=verify_repo.sh 'LOG_PREFIX="[^"]*"' scripts/*.sh docker/*.sh \
              | grep -vE 'LOG_PREFIX="\[[A-Z][A-Za-z0-9]*( [A-Z$][A-Za-z0-9{}:_-]*)*\]"' || true)"
[ -z "$bad_prefix" ] \
    || { log_err "LOG_PREFIX must be bracketed Title Case: ${bad_prefix}"; api_errors=1; }

# One indentation rule across every screen: content at two columns, a heading at
# zero, a nested hint at four. log_ok printed at zero while log_step_done — in
# the same file — printed at two, so `make check` interleaved both.
indent_probe="$(bash -c 'source scripts/util_logging.sh
    LOG_PREFIX="[T]"; log_ok content; log_step_done step; log_detail hint
    print_section Heading' 2>/dev/null | grep -vE '^$' | sed -E 's/[^ ].*//' | awk '{print length}' | tr '\n' ' ')"
[ "$indent_probe" = "2 2 4 0 " ] \
    || { log_err "output indentation drifted (content/step/hint/heading columns: ${indent_probe}expected 2 2 4 0)."; api_errors=1; }

# The palette and status tags are exported so project scripts can build their own
# lines; a missing one splices an empty string into their output.
palette="$(bash -c 'source scripts/util_logging.sh
    for v in RED GREEN YELLOW BLUE CYAN PURPLE NC DIM TEAL INFO OK WARN ERROR DEBUG; do
        [ -n "${!v:-}" ] && printf "%s " "$v"
    done' 2>/dev/null || true)"
[ "$(wc -w <<< "$palette")" -eq 14 ] \
    || log_err "util_logging.sh exports $(wc -w <<< "$palette")/14 palette + status tags (\$INFO, \$DIM, … are provided API)."
# config/util_paths.sh is provided API too: a project's own scripts build on
# these names, and WS_BUILD/WS_DEPS/WS_LOGS have no in-tree caller by design.
path_api="$(bash -c 'source config/util_paths.sh >/dev/null 2>&1
    for v in WS_ROOT WS_SCRIPTS WS_CONFIG WS_DEPS WS_INSTALL WS_SRC WS_BUILD WS_LOGS WS_VENV WS_VENV_PY; do
        [ -n "${!v:-}" ] && printf "%s " "$v"
    done
    for fn in devkit_require devkit_env_value configure_git_safe_directory; do
        declare -F "$fn" >/dev/null && printf "%s " "$fn"
    done' 2>/dev/null || true)"
[ "$(wc -w <<< "$path_api")" -eq 13 ] \
    || { log_err "config/util_paths.sh exports $(wc -w <<< "$path_api")/13 path-API names (got: ${path_api})."; api_errors=1; }
# By EXECUTION, because the reader is what every pre-compose caller depends on.
env_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
printf 'K="v1"\r\nK=v2\n' > "$env_probe/.env"
[ "$(bash -c "source config/util_paths.sh >/dev/null 2>&1; devkit_env_value K '$env_probe/.env'" 2>/dev/null)" = "v2" ] \
    || { log_err "devkit_env_value must return the LAST assignment with quotes and CR stripped."; api_errors=1; }
rm -rf "$env_probe"
[ "$api_errors" -eq 0 ] && log_ok "Provided API intact (util_logging verbs and banners, util_paths path set and .env reader)."

# The shared-library table in docs/DEVELOPMENT.md is the map a contributor uses
# to find the owner of a rule before writing a second copy of it. A library that
# is not listed there is one nobody will find.
undocumented_libs=""
for lib in config/util_paths.sh scripts/util_*.sh; do
    grep -qF "\`${lib}\`" docs/DEVELOPMENT.md || undocumented_libs="${undocumented_libs} ${lib}"
done
[ -z "$undocumented_libs" ] \
    && log_ok "Shared libraries are all listed in the docs/DEVELOPMENT.md SSOT table." \
    || log_err "shared libraries missing from the docs/DEVELOPMENT.md SSOT table:${undocumented_libs}"

# =============================================================================
# [clean-semantics] `make clean` must not destroy the virtualenv. install/ holds both build
#       output and install/.venv, which costs a full `mksync` to rebuild; the
#       in-container `mclean` already preserves it, so the host target must too.
# =============================================================================
{ grep -q "rm -rf build devel log" Makefile \
  && grep -qF "find install -mindepth 1 -maxdepth 1 ! -name '.venv'" Makefile; } \
    && log_ok "'make clean' removes build/devel/log output while preserving install/.venv." \
    || log_err "'make clean' must remove build/ devel/ log/ and exclude install/.venv (KEEP_VENV=0 opts into deleting it)."
# The workspace convenience links point into build/ and install/ with the
# container path, so clean must drop them too or the tree keeps dead symlinks.
grep -q 'compile_commands.json .venv colcon.meta' Makefile \
    || log_err "'make clean' must remove the generated workspace symlinks (they dangle once build/install are gone)."
grep -q 'rmdir install' Makefile \
    || log_err "'make clean' must drop install/ once it is empty; the entrypoint recreates it as root, making a leftover un-removable."
# Match the compose invocation, not the phrase: the explanatory comment above
# it would satisfy a bare grep for '--rmi local'.
grep -qE '\$\(COMPOSE\).*down .*--rmi local' Makefile \
    || log_err "'make clean-all' must remove the images compose built for this project ('--rmi local'), or a full reset leaves GBs behind."
# stop/down must stay scoped to the selected ENV, or `make stop ENV=ros` also
# takes down a colleague's basic-* containers in the same project.
# Check the recipe lines, not the variable definition: `ENV_SERVICES :=` alone
# would satisfy a bare grep even after every use of it was deleted.
[ "$(grep -cE '^[[:space:]]+\$\(COMPOSE\).*(stop|down).*\$\(ENV_SERVICES\)' Makefile)" -ge 2 ] \
    || log_err "'make stop'/'make down' must target \$(ENV_SERVICES), not every profile."
# Same scoping for the targets that ATTACH to a container: an unfiltered
# `docker ps | head -1` sent `make exec ENV=ros` into a running basic container.
stray_attach="$(grep -nE "docker ps --filter \"label=com\.docker\.compose\.project=[^\"]*\" --format '\{\{\.Names\}\}' \| head" Makefile || true)"
[ -z "$stray_attach" ] \
    || log_err "attach targets pick the first project container instead of the ENV's: $(cut -d: -f1,2 <<< "$stray_attach" | tr '\n' ' ')"
# Per-recipe, not a global count: a helper that stopped being called would keep
# the count up while the target it was meant to guard attached to anything.
for attach_target in shell exec term stats logs top; do
    awk -v t="$attach_target" '$0 ~ "^"t":" {inside=1; next} inside && /^[^\t]/ {inside=0} inside' Makefile \
        | grep -qE '\$\((FIND|REQUIRE)_CONTAINER\)' \
        || log_err "'make ${attach_target}' does not resolve the container through \$(FIND_CONTAINER)/\$(REQUIRE_CONTAINER) — it can attach to the other ENV's container."
done

# =============================================================================
# [knob-implementations] Documented knobs must have an implementation (no advertised dead switches)
# =============================================================================
# One corpus, one pass: 20 recursive greps cost ~75 ms for no extra signal.
# Implementation files only: the tab completion ADVERTISES knobs (a KEY=VALUE
# candidate list) and would vouch for one nobody implements, and this script
# names every knob it checks.
knob_corpus="$(cat Makefile $(find scripts config -type f \( -name '*.sh' -o -name '*.bash' \) \
    ! -name 'verify_repo.sh' ! -name 'devkit_make_completion.bash') 2>/dev/null || true)"
dead_knobs=()
for knob in DEVKIT_SLURM_PARTITION DEVKIT_SLURM_GRES DEVKIT_SLURM_CPUS_PER_TASK DEVKIT_SLURM_NODES \
            DEVKIT_SLURM_NTASKS DEVKIT_SLURM_MEM DEVKIT_SLURM_TIME DEVKIT_SLURM_JOB_NAME \
            DEVKIT_SLURM_OUTPUT DEVKIT_SLURM_ERROR DEVKIT_SLURM_COMMENT DEVKIT_SLURM_EXTRA_ARGS \
            CONTAINER_DATA_ROOT CONTAINER_RUN_ROOT SLURM_DATA_ROOT SLURM_RUN_ROOT \
            APT_SNAPSHOT_DATE APT_SNAPSHOT_FALLBACK STRICT_GPG_CHECK DOCKER_DEV_CACHE_DIR \
            SYNC_TARGET_DIR CMAKE_EXTRA_ARGS CMAKE_C_STANDARD CMAKE_CXX_STANDARD OPENCV_CUDA \
            COLCON_EXTRA_FLAGS CUDA_VERSION KEEP_VENV TARGETARCH; do
    # Word-bounded and anchored to CODE: a substring match let KEEP_VENV pass
    # after every use became KEEP_VENVX, and a knob named only in a comment
    # would satisfy a plain grep just as well.
    grep -qE "^[^#]*(^|[^A-Za-z0-9_])${knob}([^A-Za-z0-9_]|$)" <<< "$knob_corpus" \
        || dead_knobs+=("$knob")
done
if [ "${#dead_knobs[@]}" -eq 0 ]; then
    log_ok "All documented environment knobs have an implementation."
else
    log_err "Documented but unimplemented knob(s): ${dead_knobs[*]}"
fi

# =============================================================================
# [render-probes] Rendering-stack probes must be timeout-guarded and emit key=value pairs.
#      An unguarded glxinfo/eglinfo against an unreachable DISPLAY hangs hwcheck
#      forever; a changed output shape silently blanks every diagnostic.
# =============================================================================
probe_errors=0
for fn in probe_gl probe_egl probe_vulkan probe_gl_libs; do
    grep -q "^${fn}()" scripts/util_gpu_detect.sh || { log_err "util_gpu_detect.sh is missing ${fn}()"; probe_errors=1; }
done
grep -q 'timeout "\$GPU_PROBE_TIMEOUT"' scripts/util_gpu_detect.sh \
    || { log_err "Rendering probes must run under 'timeout' (a stale DISPLAY would hang hwcheck)."; probe_errors=1; }
# The probes must survive a tool that prints usable data and then exits non-zero.
# Run with no display: exercises the guard/early-return paths in ~1 ms instead
# of paying a real 500 ms glxinfo round-trip on a machine that has one.
if ! ( set -euo pipefail; unset DISPLAY WAYLAND_DISPLAY; source scripts/util_gpu_detect.sh
       probe_gl >/dev/null 2>&1 || true; probe_egl >/dev/null 2>&1 || true
       probe_vulkan >/dev/null 2>&1 || true; probe_gl_libs >/dev/null 2>&1 || true ); then
    log_err "Rendering probes abort under 'set -euo pipefail' (callers use it)."
    probe_errors=1
fi
# Diagnostics must survive tools that exist but fail (timedatectl without a
# systemd bus, stub nvidia-smi, DISPLAY pointing nowhere): under `set -o
# pipefail` one unguarded assignment truncates the whole report.
unguarded="$(grep -nE '^[[:space:]]*[A-Z_]+=\$\((timedatectl|nvidia-smi|glxinfo|vulkaninfo|hostname|ip|df)' scripts/check_hardware.sh \
    | grep -v '|| true' || true)"
if [ -n "$unguarded" ]; then
    log_err "check_hardware.sh has an unguarded capture from a fallible tool (aborts the scan under pipefail):"
    sed 's/^/    /' <<< "$unguarded" >&2
    probe_errors=1
fi
# Diagnostics must not claim a subsystem that is absent: compose passes
# ROS_DISTRO to every service, so the non-ROS image reported "ROS: humble".
# Probed on this host, which has no /opt/ros at all.
if [ ! -d "/opt/ros/${ROS_DISTRO:-humble}" ]; then
    ros_claim="$(ROS_DISTRO=humble COMPOSE_PROJECT_NAME=probe bash -c \
        'source scripts/util_logging.sh; print_env_info' 2>/dev/null | sed -E $'s/\033\\[[0-9;]*m//g')"
    case "$ros_claim" in
        *"ROS: humble"*) log_err "print_env_info claims ROS is present from ROS_DISTRO alone; the non-ROS image reports a distro it does not have."; probe_errors=1 ;;
    esac
fi
grep -q 'd "/opt/ros/${ROS_DISTRO' scripts/check_hardware.sh \
    || { log_err "check_hardware.sh reports ROS from ROS_DISTRO alone (compose sets it on every service)."; probe_errors=1; }
[ "$probe_errors" -eq 0 ] && log_ok "Rendering-stack probes (GL/EGL/Vulkan/loader) are timeout-guarded and errexit-safe."

# =============================================================================
# [colour-discipline] Colour discipline: output must be plain when redirected or NO_COLOR is
#      set, otherwise CI logs and `> file` captures fill up with SGR escapes.
# =============================================================================
color_errors=0
if ! grep -q 'devkit_auto_color' scripts/util_logging.sh; then
    log_err "util_logging.sh must provide devkit_auto_color (NO_COLOR / non-TTY handling)."; color_errors=1
fi
for f in scripts/check_hardware.sh scripts/setup_gpu.sh scripts/check_wsl.sh \
         scripts/check_preflight.sh scripts/setup_sync_deps.sh scripts/check_deps.sh; do
    grep -q 'devkit_auto_color' "$f" || { log_err "$f does not call devkit_auto_color."; color_errors=1; }
done
# End-to-end on a real script: NO_COLOR must win even on a terminal.
NO_COLOR=1 bash scripts/check_wsl.sh 2>/dev/null | grep -q $'\033' \
    && { log_err "NO_COLOR=1 still yields ANSI from scripts/check_wsl.sh (devkit_auto_color not reached)."; color_errors=1; }
# bash's `echo` does not interpret \033 — the escape reaches the screen as
# literal text. `gpus` printed '\033[33m(/usr/lib/wsl/lib MISSING)' that way.
# `sed 's/#.*//'` first: this rule's own explanation names `echo` and \033.
raw_echo="$(grep -rn --exclude=verify_repo.sh -F '\033' Makefile scripts config docker \
             | sed 's/#.*//' | grep -E 'echo ([^-]|-[^e])' || true)"
[ -z "$raw_echo" ] \
    || { log_err "'echo' without -e cannot emit an escape (use printf): $(cut -d: -f1,2 <<< "$raw_echo" | tr '\n' ' ')"; color_errors=1; }
grep -q 'MAKE_TERMOUT' Makefile || { log_err "Makefile must drop colours when stdout is not a terminal (MAKE_TERMOUT)."; color_errors=1; }
# End-to-end, because the guard only covers recipes that USE the colour
# variables: a recipe hardcoding \033 ignores it and pollutes `make help > log`.
make_help_out="$(make help 2>/dev/null || true)"
grep -q $'\033' <<< "$make_help_out" \
    && { log_err "'make help' emits ANSI escapes into a pipe — a recipe hardcodes an escape instead of using \$(CYAN)/\$(NC)."; color_errors=1; }
# End-to-end on the shared mechanism (cheap): piping must yield plain text.
if bash -c 'source scripts/util_logging.sh; devkit_auto_color; echo -e "\033[32mx\033[0m"' 2>/dev/null | grep -q $'\033'; then
    log_err "devkit_auto_color does not strip ANSI when stdout is not a terminal."; color_errors=1
fi
# stderr too: warnings and errors are exactly what a user greps from a log.
if bash -c 'source scripts/util_logging.sh; devkit_auto_color; log_warn probe' 2>&1 >/dev/null | grep -q $'\033'; then
    log_err "devkit_auto_color leaves ANSI on stderr — log_warn/log_error pollute redirected logs."; color_errors=1
fi
# The log verbs must be plain off-TTY on their OWN, without devkit_auto_color:
# the in-container shell functions (config/util_aliases.sh) cannot call it, so
# this is what keeps `mksync | tee build.log` free of escapes. stdout and stderr
# are asserted separately — each verb resolves colour against the stream it uses.
if bash -c 'source scripts/util_logging.sh; log_ok probe; log_detail probe; log_step_done probe' 2>/dev/null | grep -q $'\033'; then
    log_err "log_ok/log_detail/log_step_done emit ANSI into a pipe without devkit_auto_color."; color_errors=1
fi
if bash -c 'source scripts/util_logging.sh; log_error probe' 2>&1 >/dev/null | grep -q $'\033'; then
    log_err "log_error emits ANSI into a redirected stderr without devkit_auto_color."; color_errors=1
fi
# …and the in-container commands must go through those verbs, not hand-rolled
# escapes, or the guarantee above stops covering the output a user actually pipes.
# __require_cmd, not a build entry point: it exercises log_error + log_detail
# together and touches no filesystem, so this stays safe in a real project tree.
alias_msg="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1; __require_cmd devkit-no-such-tool" 2>&1 || true)"
{ grep -q '\[ERROR\]' <<< "$alias_msg" && grep -q '→' <<< "$alias_msg" \
  && ! grep -q $'\033' <<< "$alias_msg"; } \
    || { log_err "config/util_aliases.sh prints raw escapes (or nothing) on failure — use log_error/log_warn/log_detail."; color_errors=1; }
help_piped="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1; __print_container_help" 2>/dev/null || true)"
{ [ -n "$help_piped" ] && ! grep -q $'\033' <<< "$help_piped"; } \
    || { log_err "in-container 'h' emits ANSI escapes into a pipe (or printed nothing) — it must drop colour off-TTY."; color_errors=1; }
[ "$color_errors" -eq 0 ] && log_ok "Colour output is TTY/NO_COLOR aware (scripts, Makefile and in-container help)."

# =============================================================================
# [reproducibility] Reproducibility inputs: the knobs that actually pin a build must exist.
#      This asserts the mechanism is wired, not that a given build is pinned —
#      docs/DEVELOPMENT.md lists what the user still has to pin themselves.
# =============================================================================
repro_errors=0
grep -q 'snapshot.ubuntu.com' scripts/util_apt_helper.sh || { log_err "APT snapshot pinning (APT_SNAPSHOT_DATE) is not implemented."; repro_errors=1; }
grep -q 'SOURCE_DATE_EPOCH' scripts/apptainer_bake.sh    || { log_err "bake does not forward SOURCE_DATE_EPOCH."; repro_errors=1; }
grep -q 'ROS_GPG_FINGERPRINT' scripts/util_apt_helper.sh || { log_err "ROS key is not fingerprint-pinned."; repro_errors=1; }
grep -q 'dpkg-query -W' scripts/util_release_metadata.sh || { log_err "Release metadata must record an APT manifest (unpinnable layers need auditability)."; repro_errors=1; }
grep -q 'Unpinned repositories' scripts/setup_sync_deps.sh || { log_err "sync_deps must lint .repos for unpinned branch refs."; repro_errors=1; }
# Production artifact self-containment. Asserted by EXECUTION, not by grepping
# for a variable name: the shipped image copies install/ and never src/ or
# build/, so `--symlink-install` would leave dangling links and a CMake build
# that never installs would ship nothing at all.
prod_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
mkdir -p "$prod_probe/bin" "$prod_probe/config" "$prod_probe/src"
cp config/util_aliases.sh config/util_paths.sh "$prod_probe/config/" 2>/dev/null || true
printf '#!/bin/sh\necho "$*"\n' > "$prod_probe/bin/colcon"
printf '#!/bin/sh\necho "$*"\n' > "$prod_probe/bin/catkin_make"
chmod +x "$prod_probe/bin/colcon" "$prod_probe/bin/catkin_make"
mkdir -p "$prod_probe/install/share/p"; : > "$prod_probe/install/share/p/f"
# $2 selects the ROS generation: 2 = colcon (default), 1 = catkin_make
build_flags() {
    env -i PATH="$prod_probe/bin:/usr/bin:/bin" HOME=/tmp WORKSPACE_PATH="$prod_probe" \
        ROS_DISTRO=humble ROS_VERSION="${2:-2}" ${1:+DEVKIT_BUILD_TYPE=$1} \
        bash -lc "source $prod_probe/config/util_aliases.sh 2>/dev/null; cbuild" 2>/dev/null
}
case "$(build_flags prod)" in
    *--symlink-install*) log_err "prod cbuild still passes --symlink-install (shipped install/ would contain dangling links into src/)."; repro_errors=1 ;;
esac
case "$(build_flags '')" in
    *--symlink-install*) ;;
    *) log_err "dev cbuild lost --symlink-install (edit-without-rebuild workflow broken)."; repro_errors=1 ;;
esac
# ROS 1: catkin_make writes to devel/, so prod must invoke the install target.
# Match the catkin_make SUBCOMMAND (first word), not any occurrence of the
# word: -DCMAKE_INSTALL_PREFIX=<path>/install would satisfy a loose *install*.
case "$(build_flags prod 1)" in
    install\ *|install) ;;
    *) log_err "ROS 1 prod cbuild does not run 'catkin_make install'; the runtime image copies install/ only."; repro_errors=1 ;;
esac
# Deployment goal: the shipped tree must not carry plaintext project source.
src_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"; mkdir -p "$src_probe/pkg/lib/python3/site-packages/pkg" "$src_probe/pkg/share/pkg/launch"
printf 'SECRET=1\n' > "$src_probe/pkg/lib/python3/site-packages/pkg/core.py"
printf 'x\n'        > "$src_probe/pkg/share/pkg/launch/a.launch.py"
DEVKIT_STRIP_SOURCE=1 bash scripts/check_deps.sh "$src_probe" >/dev/null 2>&1 || true
if [ -f "$src_probe/pkg/lib/python3/site-packages/pkg/core.py" ]; then
    log_err "DEVKIT_STRIP_SOURCE=1 did not remove plaintext source from the install tree."; repro_errors=1
elif [ ! -f "$src_probe/pkg/share/pkg/launch/a.launch.py" ]; then
    log_err "Source strip removed a launch file; 'ros2 launch' reads those as source."; repro_errors=1
fi
rm -rf "$src_probe"
grep -q 'cmake --install' config/util_aliases.sh \
    || { log_err "mbuild must install into install/ for prod builds; the runtime image never copies build/."; repro_errors=1; }
rm -rf "$prod_probe"
# The flag only helps if the Dockerfile actually sets it on the builder stages.
for stage_line in 'prod-dev-builder' 'prod-ros-builder'; do
    awk -v stage="$stage_line" '
        $0 ~ "AS " stage {inside=1}
        inside && /^FROM /  && $0 !~ "AS " stage {inside=0}
        inside && /mksync/  {found=1}
        inside && /mksync/ && /DEVKIT_BUILD_TYPE=prod/ {ok=1}
        END {exit (found && !ok) ? 1 : 0}' docker/Dockerfile \
        || { log_err "docker/Dockerfile: ${stage_line} runs mksync without DEVKIT_BUILD_TYPE=prod."; repro_errors=1; }
done
if [ -f src/pyproject.toml ] && [ ! -f src/uv.lock ]; then
    # Informational, never a failure: the TEMPLATE ships no lock (it would hand
    # every fork one moment's resolution). The derived project commits its own.
    log_info "No src/uv.lock here — DevKit ships none; run 'mksync' in your project and commit the lock there."
fi
[ "$repro_errors" -eq 0 ] && log_ok "Reproducibility inputs wired (APT snapshot, SOURCE_DATE_EPOCH, GPG pin)."

# =============================================================================
# [prod-entrypoint] Production entrypoint contract
# =============================================================================
# Both refusals, by exit code as well as message: this is PID 1 of the shipped
# artifact, so a supervisor reads the code, and the house convention is 1 for a
# failure and 2 for a usage error (not the sysexits values it once returned).
prod_errors=0
prod_rc=0
prod_out="$(WORKSPACE_PATH="/workspace/nonexistent_path_test" docker/prod_entrypoint.sh true 2>&1)" || prod_rc=$?
{ [ "$prod_rc" -eq 1 ] && grep -q "Workspace path does not exist" <<< "$prod_out"; } \
    || { log_err "prod_entrypoint.sh must exit 1 and say so on a missing workspace (got ${prod_rc}: ${prod_out%%$'\n'*})."; prod_errors=1; }
prod_rc=0
prod_out="$(env -u APP_COMMAND -u ROS_LAUNCH_COMMAND WORKSPACE_PATH="$ROOT_DIR" \
    docker/prod_entrypoint.sh 2>&1)" || prod_rc=$?
{ [ "$prod_rc" -eq 2 ] && grep -q "No production command configured" <<< "$prod_out"; } \
    || { log_err "prod_entrypoint.sh must exit 2 when no command is configured (got ${prod_rc}: ${prod_out%%$'\n'*})."; prod_errors=1; }
[ "$prod_errors" -eq 0 ] && log_ok "Production entrypoint refuses a missing workspace (1) and a missing command (2)."

# =============================================================================
# [tab-completion] Tab completion: targets derived from Makefile .PHONY, no dead knobs
# =============================================================================
completion_targets="$(bash -c '
    source config/devkit_make_completion.bash
    COMP_WORDS=(make ""); COMP_CWORD=1; COMPREPLY=()
    _devkit_make_completion; echo "${COMPREPLY[*]}"' 2>/dev/null)"
if [ "$(echo "$completion_targets" | wc -w)" -eq "$(echo "$phony_targets" | wc -w)" ]; then
    log_ok "Tab completion resolves all $(echo "$phony_targets" | wc -w) targets from Makefile .PHONY."
else
    log_err "Tab completion target list drifted from Makefile .PHONY (got: ${completion_targets})"
fi

# =============================================================================
# [vscode-json] VS Code JSON: no shell default expansion ${VAR:-default}
# =============================================================================
vscode_errors=0
if grep -rqE '\$\{[A-Za-z_][A-Za-z0-9_]*:-' .vscode .devcontainer 2>/dev/null; then
    log_err "VS Code JSON files must not use \${VAR:-default} shell expansion (VS Code treats it as substitution):"
    grep -rE '\$\{[A-Za-z_][A-Za-z0-9_]*:-' .vscode .devcontainer 2>/dev/null | sed 's/^/    /' >&2
    vscode_errors=1
fi
stray_ide_env="$(grep -rn '\${env:WS_' .vscode .devcontainer 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
[ -z "$stray_ide_env" ] \
    || { log_err "IDE config reads \${env:WS_*}, which is never set in the IDE process: $(cut -d: -f1,2 <<< "$stray_ide_env" | tr '\n' ' ')"; vscode_errors=1; }
# Every shell symbol and script the IDE config invokes must exist: a task
# calling a helper that was removed prints only "command not found", and no
# static JSON check notices.
ide_syms="$(grep -ohE '&& *[A-Za-z_][A-Za-z0-9_]*' .vscode/*.json .devcontainer/*.json 2>/dev/null \
            | sed 's/&& *//' | sort -u | tr '\n' ' ')"
# One bash for the whole group, and by DEFINITION lookup rather than grep: the
# build entry points live inside a ROS_VERSION branch, where a per-line grep
# reported a false miss.
ide_missing="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1
    for s in ${ide_syms}; do
        declare -F \"\$s\" >/dev/null 2>&1 || alias \"\$s\" >/dev/null 2>&1 || printf ' %s' \"\$s\"
    done" 2>/dev/null || true)"
[ -z "$ide_missing" ] \
    || { log_err "IDE tasks invoke shell symbols that no longer exist:${ide_missing}"; vscode_errors=1; }
# A setting must live in ONE file. devcontainer customizations are injected as
# remote settings, which .vscode/settings.json then overrides — so a key present
# in both is a copy that can only ever go stale.
for ide_key in $(sed -n '/"settings": {/,/}/p' .devcontainer/devcontainer.json 2>/dev/null \
                 | grep -oE '"[A-Za-z_][A-Za-z0-9_.]*":' | tr -d '":'); do
    grep -q "\"${ide_key}\"" .vscode/settings.json \
        && { log_err "'${ide_key}' is set in both .devcontainer/devcontainer.json and .vscode/settings.json."; vscode_errors=1; }
done
# Each IntelliSense profile must be documented: docs/DEBUGGING.md tells the user
# which one to pick, and it still named a "Host (Bind Mount)" profile that had
# been renamed twice.
while IFS= read -r ide_profile; do
    grep -qF "$ide_profile" docs/DEBUGGING.md \
        || { log_err "IntelliSense profile '${ide_profile}' is not documented in docs/DEBUGGING.md."; vscode_errors=1; }
done < <(grep -oE '"name": "[^"]+"' .vscode/c_cpp_properties.json | sed 's/"name": "//; s/"$//')
# Same rule for every F5 entry: a debug configuration nobody documents is a
# feature nobody finds. The compounds in particular had no mention anywhere.
# Parsed, not grepped: an `environment` entry also carries a "name" key.
ide_launch_names="$(python3 - <<'PYLAUNCH' 2>/dev/null || true
import json, re, pathlib
d = json.loads(re.sub(r'(?m)^\s*//.*$', '', pathlib.Path('.vscode/launch.json').read_text()))
for entry in d.get('configurations', []) + d.get('compounds', []):
    print(entry['name'])
PYLAUNCH
)"
[ "$(grep -c . <<< "$ide_launch_names")" -ge 10 ] \
    || { log_err "launch.json name extraction collapsed ($(grep -c . <<< "$ide_launch_names") found)."; vscode_errors=1; }
while IFS= read -r ide_launch; do
    grep -qF "$ide_launch" docs/DEBUGGING.md \
        || { log_err "debug configuration '${ide_launch}' is not documented in docs/DEBUGGING.md."; vscode_errors=1; }
done <<< "$ide_launch_names"
for ide_script in $(grep -ohE '(WS_SCRIPTS\}?|scripts)/[A-Za-z0-9_]+\.sh' .vscode/*.json .devcontainer/*.json 2>/dev/null \
                    | sed 's|.*/||' | sort -u); do
    [ -f "scripts/${ide_script}" ] \
        || { log_err "IDE tasks reference scripts/${ide_script}, which does not exist."; vscode_errors=1; }
done
[ "$vscode_errors" -eq 0 ] \
    && log_ok "VS Code / devcontainer JSON: no shell expansion, every invoked symbol and script resolves."

# =============================================================================
# [adopt] `make adopt` hands a fork the identity it owns. It edits tracked files,
#      so it must be surgical: a bare `sed s/^name = /` also renamed the
#      [[tool.uv.index]] entries and left [tool.uv.sources] pointing at indexes
#      that no longer existed.
# =============================================================================
adopt_errors=0
# Recipe comment lines (\t@#) dropped: the explanation below mentions
# [project] and would satisfy the grep on its own.
adopt_recipe="$(awk '/^adopt:/{inside=1} inside && /^[a-z]/ && !/^adopt:/{inside=0} inside' Makefile \
                | grep -v $'^\t@#')"
grep -q '\[project\]' <<< "$adopt_recipe" \
    || { log_err "'make adopt' does not scope its pyproject edit to the [project] table."; adopt_errors=1; }
grep -q 'origin NAME' Makefile \
    || { log_err "'make adopt' trusts an inherited NAME; the environment carries one (WSL exports NAME=<hostname>)."; adopt_errors=1; }
rc=0; make adopt >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] \
    || { log_err "'make adopt' without NAME must exit 2 (got ${rc})."; adopt_errors=1; }
# Every index [tool.uv.sources] names must exist — this is what a sloppy rename
# breaks, and uv fails only later, at sync time.
# …and the shipped default must already satisfy the rule adopt enforces: a fork
# that never runs adopt still has to `uv sync`.
uv_index_ok="$(python3 - <<'PYINDEX' 2>/dev/null || true
import re, tomllib, pathlib
d = tomllib.loads(pathlib.Path('src/pyproject.toml').read_text())
uv = d.get('tool', {}).get('uv', {})
index = {i['name'] for i in uv.get('index', [])}
refs = {e['index'] for v in uv.get('sources', {}).values() for e in v if 'index' in e}
name = d.get('project', {}).get('name', '')
if refs - index:
    print(f"[tool.uv.sources] names a missing index: {sorted(refs - index)}")
elif not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', name):
    print(f"[project] name '{name}' fails the rule 'make adopt' enforces")
else:
    print('ok')
PYINDEX
)"
[ "$uv_index_ok" = "ok" ] \
    || { log_err "src/pyproject.toml: ${uv_index_ok}."; adopt_errors=1; }
[ "$adopt_errors" -eq 0 ] \
    && log_ok "Adoption is surgical (scoped pyproject edit, explicit NAME, uv indexes intact)."

# =============================================================================
# [style-config] One declared style. Neither ruff nor clang-format reads
# =============================================================================
style_errors=0
ec_section_value() {   # ec_section_value <section-prefix> <key>
    awk -v sec="$1" -v key="$2" '
        index($0, sec) == 1 { inside = 1; next }
        /^\[/              { inside = 0 }
        inside && $1 == key { print $3; exit }' .editorconfig
}
ec_py="$(ec_section_value '[*.{py' max_line_length)"
ec_cpp="$(ec_section_value '[*.{c,cpp' max_line_length)"
ec_cpp_indent="$(ec_section_value '[*.{c,cpp' indent_size)"
# Anti-vacuous: an empty parse would make every comparison below pass.
{ [ -n "$ec_py" ] && [ -n "$ec_cpp" ] && [ -n "$ec_cpp_indent" ]; } \
    || { log_err ".editorconfig parse yielded no widths (py='${ec_py}' cpp='${ec_cpp}' indent='${ec_cpp_indent}')."; style_errors=1; }
ruff_cols="$(grep -oE '^line-length[[:space:]]*=[[:space:]]*[0-9]+' src/pyproject.toml | grep -oE '[0-9]+' || true)"
[ "${ruff_cols:-}" = "$ec_py" ] \
    || { log_err "ruff line-length is '${ruff_cols:-unset}' but .editorconfig says ${ec_py} — format-on-save fights the declared style."; style_errors=1; }
clang_cols="$(grep -oE '^ColumnLimit:[[:space:]]*[0-9]+' .clang-format 2>/dev/null | grep -oE '[0-9]+' || true)"
[ "${clang_cols:-}" = "$ec_cpp" ] \
    || { log_err ".clang-format ColumnLimit is '${clang_cols:-unset/missing}' but .editorconfig says ${ec_cpp}."; style_errors=1; }
clang_indent="$(grep -oE '^IndentWidth:[[:space:]]*[0-9]+' .clang-format 2>/dev/null | grep -oE '[0-9]+' || true)"
[ "${clang_indent:-}" = "$ec_cpp_indent" ] \
    || { log_err ".clang-format IndentWidth is '${clang_indent:-unset/missing}' but .editorconfig says ${ec_cpp_indent}."; style_errors=1; }
# The rulers a developer sees must be exactly those two limits.
for style_col in "$ec_py" "$ec_cpp"; do
    grep -qE "\"editor.rulers\": \[[^]]*\b${style_col}\b" .vscode/settings.json \
        || { log_err "editor.rulers does not include ${style_col}, the width .editorconfig declares."; style_errors=1; }
done
[ "$style_errors" -eq 0 ] \
    && log_ok "Style config agrees across .editorconfig, ruff, clang-format and the editor rulers (py ${ec_py}, c++ ${ec_cpp})."

# =============================================================================
# [dockerfile-policy] Dockerfile package policy (no libboost-all-dev / software-properties-common)
# =============================================================================
if grep -qE '(^|[[:space:]])libboost-all-dev([[:space:]\\]|$)' docker/Dockerfile; then
    log_err "Dockerfile must not install libboost-all-dev; use specific boost components."
elif grep -qE '(^|[[:space:]])software-properties-common([[:space:]\\]|$)' docker/Dockerfile; then
    log_err "Dockerfile must not install software-properties-common."
else
    log_ok "Dockerfile package policy checks passed (no bloated packages)."
fi

# =============================================================================
# [sif-contract] SIF pipeline contract: build args forwarded, inputs rejected loudly
# =============================================================================
# These pin the exact failure modes of the streamline refactor: bake dropping
# CUDA_VERSION (SIF silently ships without CUDA), bake swallowing typo'd flags,
# and the CUDA apt repo helper degrading to a no-op stub.
# '^[^#]*' anchors each grep to CODE — a mutation test showed the plain form
# was satisfied by its own explanatory comment after the code was deleted.
sif_errors=0
grep -Eq '^[^#]*CUDA_VERSION' scripts/apptainer_bake.sh \
    || { log_err "apptainer_bake.sh no longer forwards CUDA_VERSION — baked SIFs would silently ship without CUDA."; sif_errors=1; }
grep -Eq '^[^#]*sources\.list\.d/cuda\.list' scripts/util_apt_helper.sh \
    || { log_err "util_apt_helper.sh setup-cuda-repo no longer configures the NVIDIA repository."; sif_errors=1; }
rc=0; bash scripts/apptainer_bake.sh --bogus-flag >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { log_err "apptainer_bake.sh must reject unknown flags with exit 2, not silently ignore them."; sif_errors=1; }
grep -Eq '^[^#]*\$\{SYNC_TARGET_DIR' scripts/setup_sync_deps.sh \
    || { log_err "setup_sync_deps.sh no longer honours SYNC_TARGET_DIR (Dockerfile stages stage into /tmp)."; sif_errors=1; }
grep -Eq '^[^#]*source "/opt/ros/.*setup\.bash' scripts/check_deps.sh \
    || { log_err "check_deps.sh no longer sources the ROS environment — prod ROS 1 builds would fail their binding check."; sif_errors=1; }
# Execution-based: a typo'd ENV must die in make's read phase, before any
# recipe — probed on `down`, the target where a wrong profile deletes volumes
# (and detector-exempt, so this probe has no host-detection side effect).
rc=0; env_probe="$(make -n down ENV=__bogus__ 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && grep -q "ENV must be" <<< "$env_probe"; } \
    || { log_err "Makefile no longer rejects an invalid ENV on teardown — 'make down ENV=ros2' would remove the wrong profile's volumes."; sif_errors=1; }
# The CUDA pin's escape hatch: base stage must re-declare ARG STRICT_GPG_CHECK
# or the documented STRICT_GPG_CHECK=false override never reaches setup-cuda-repo.
awk '/^FROM .* AS base$/,/^FROM [^ ]* AS build-core$/' docker/Dockerfile | grep -q '^ARG STRICT_GPG_CHECK' \
    || { log_err "Dockerfile base stage lost 'ARG STRICT_GPG_CHECK' — the documented escape hatch cannot reach setup-cuda-repo."; sif_errors=1; }
# slurm command scheme: argv array preserved end-to-end (a "$*" join + bash -c
# re-parse would re-interpret metacharacters inside legitimate arguments).
{ grep -q 'CMD=( "$@" )' scripts/slurm_run.sh && grep -q '"${CMD\[@\]}"' scripts/slurm_run.sh; } \
    || { log_err "slurm_run.sh lost the argv-preserving CMD array scheme."; sif_errors=1; }
# Host/container path confusion: the Makefile exports WORKSPACE_PATH=/workspace
# to EVERY recipe, host-side ones included, so a script that trusts it resolves
# /workspace/scripts/... and dies. `make bake-prod` was broken exactly this way
# while the flag assertions above all passed.
[ "$(WORKSPACE_PATH=/nonexistent-devkit bash -c 'source config/util_paths.sh; printf %s "$WS_ROOT"')" = "$ROOT_DIR" ] \
    || { log_err "config/util_paths.sh trusts WORKSPACE_PATH even when it is not a DevKit tree here — host scripts resolve /workspace/..."; sif_errors=1; }
grep -qE '^WS_ROOT="\$\{WORKSPACE_PATH' scripts/apptainer_bake.sh scripts/apptainer_run.sh \
    && { log_err "apptainer_*.sh derive the repo root from WORKSPACE_PATH (the container path) but run on the host."; sif_errors=1; }
# `apptainer exec` does not run the image ENTRYPOINT, so both run paths must
# route the command through /entrypoint.sh or the job starts with no ROS/venv
# environment at all — verified against a real SIF, where `import rclpy` failed.
sif_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
cat > "${sif_probe}/rt" <<'STUB'
#!/bin/sh
# Stands in for `apptainer exec <sif> …`: the image has an entrypoint, and it
# accepts --env only when DEVKIT_PROBE_DEV=1.
case "$*" in
    *"test -x /entrypoint.sh") exit 0 ;;
    *grep*) [ "${DEVKIT_PROBE_DEV:-0}" = 1 ] && exit 0 || exit 1 ;;
esac
exit 1
STUB
chmod +x "${sif_probe}/rt"
entry_probe() {
    DEVKIT_PROBE_DEV="$1" bash -c "source scripts/util_sif_common.sh
        sif_entry_args '${sif_probe}/rt' img.sif" 2>/dev/null
}
[ "$(entry_probe 1)" = "/entrypoint.sh --env" ] \
    || { log_err "sif_entry_args drops the dev entrypoint's --env wrapper; a SIF command loses the ROS environment."; sif_errors=1; }
[ "$(entry_probe 0)" = "/entrypoint.sh" ] \
    || { log_err "sif_entry_args passes --env to a production entrypoint that does not accept it."; sif_errors=1; }
rm -rf "$sif_probe"
for sif_runner in scripts/apptainer_run.sh scripts/slurm_run.sh; do
    grep -qE '^[^#]*sif_entry_args' "$sif_runner" \
        || { log_err "${sif_runner} no longer routes the command through /entrypoint.sh; a SIF run loses the ROS environment."; sif_errors=1; }
done
# One runtime resolution for bake, run and the job script: the copies drifted
# and run/slurm died with a bare "singularity: command not found".
for sif_caller in scripts/apptainer_bake.sh scripts/apptainer_run.sh scripts/slurm_run.sh; do
    grep -qE '^[^#]*sif_runtime' "$sif_caller" \
        || { log_err "${sif_caller} resolves the apptainer/singularity binary itself instead of via sif_runtime."; sif_errors=1; }
done
# slurm submits the PRODUCTION artifact; probing for a *-slurm.sif never hits.
grep -qE '^[^#]*ARTIFACT_MODE="prod"' scripts/apptainer_run.sh \
    || { log_err "apptainer_run.sh no longer maps SIF_MODE=slurm onto the prod artifact — the default probe finds nothing."; sif_errors=1; }
# RUN_ARGS must survive make without a second round of shell parsing: the
# documented RUN_ARGS='python3 -c "print(1)"' produced an unbalanced-quote
# syntax error when it was passed as an argument instead of via the environment.
bash -n <<< "$(make -n run-sif RUN_ARGS='python3 -c "print(1)"' 2>/dev/null)" 2>/dev/null \
    || { log_err "'make run-sif RUN_ARGS=...' emits invalid shell when RUN_ARGS contains quotes (pass it through the environment)."; sif_errors=1; }
sif_root_probe="$(SIF_FILE=/nonexistent.sif WORKSPACE_PATH=/nonexistent-devkit \
    bash scripts/apptainer_run.sh --mode prod --env ros 2>&1 || true)"
grep -q 'SIF artifact not found' <<< "$sif_root_probe" \
    || { log_err "apptainer_run.sh cannot resolve the repository root when WORKSPACE_PATH points at the container: ${sif_root_probe%%$'\n'*}"; sif_errors=1; }
[ "$sif_errors" -eq 0 ] && log_ok "SIF pipeline contract: build args forwarded, bad inputs rejected, CUDA repo wired."

# =============================================================================
# [security-defaults] Security defaults: fail-closed GPG, unprivileged containers, TLS snapshot
# =============================================================================
# All greps anchored to code ('^[^#]*') — unanchored ones are satisfied by
# comments mentioning the old value (proven by mutation testing).
sec_errors=0
grep -Eq '^[^#]*STRICT_GPG_CHECK: \$\{STRICT_GPG_CHECK:-true\}' docker-compose.common.yml \
    || { log_err "STRICT_GPG_CHECK compose default regressed to fail-open."; sec_errors=1; }
grep -Eq '^[^#]*privileged: \$\{PRIVILEGED:-false\}' docker-compose.common.yml \
    || { log_err "PRIVILEGED compose default regressed to true (container escape is trivial when privileged)."; sec_errors=1; }
# Universal, not existential: ANY http:// snapshot mirror line is a regression
# (a single reverted sed line still passed the old at-least-one-https check).
grep -Eq '^[^#]*http://snapshot\.ubuntu\.com' scripts/util_apt_helper.sh \
    && { log_err "A snapshot mirror regressed to http:// (Check-Valid-Until is off — TLS is the only anti-rollback control)."; sec_errors=1; }
grep -Eq '^[^#]*NVIDIA_GPG_FINGERPRINT="[A-F0-9]{40}"' scripts/util_apt_helper.sh \
    || { log_err "NVIDIA CUDA key fingerprint pin removed (TOFU regression)."; sec_errors=1; }
# Shipped images must restore docker-clean (init-apt's keep-cache only serves
# BuildKit cache mounts; left in place, runtime apt installs hoard .debs forever).
[ "$(grep -c 'apt.conf.d/docker-clean' docker/Dockerfile)" -ge 3 ] \
    || { log_err "A terminal image stage (dev/ros/prod-base) lost its docker-clean restore — runtime apt would hoard .deb files."; sec_errors=1; }
# `make term` must probe with a binary the image actually ships: xset lives in
# x11-xserver-utils (not installed) and made the target report "no display" on a
# working X11 host. xdpyinfo comes from x11-utils, which the image does install.
grep -q 'xset q' Makefile \
    && { log_err "'make term' probes X11 with xset, absent from the image (x11-xserver-utils); use xdpyinfo."; sec_errors=1; }
grep -qE '(^|[[:space:]])x11-utils([[:space:]\\]|$)' docker/Dockerfile \
    || { log_err "x11-utils dropped from the image; 'make term' has no way left to probe the display."; sec_errors=1; }
grep -Eq '^[^#]*for E in.*"local:' Makefile \
    && { log_err "xhost 'local:' grant reintroduced — it admits EVERY local user, not just root."; sec_errors=1; }
# make setup writes the username into COMPOSE_PROJECT_NAME: without the tr
# sanitize, LDAP/AD names (John.Doe, LAB\user) break every compose invocation.
grep -Eq "^[^#]*tr -c 'a-z0-9_-'" Makefile \
    || { log_err "make setup lost the username sanitize — non-[a-z0-9_-] usernames would break compose project naming."; sec_errors=1; }
# mclean rm -rf roots must use ${WS_ROOT:?}: with util_paths sourced '|| true',
# a plain ${WS_ROOT} expands empty and deletes /build /log /install.
awk '/^mclean\(\)/,/^}/' config/util_aliases.sh | grep -E '\$\{WS_ROOT\}/' -q \
    && { log_err "mclean references \${WS_ROOT} without :? — empty WS_ROOT turns cleanup into rm -rf /build /install."; sec_errors=1; }
# Empty-array "${arr[@]}" is fatal under set -u on bash < 4.4 — the RHEL 7/8
# bash SLURM nodes run. Guarded form is ${arr[@]+"${arr[@]}"}.
grep -nE '"\$\{(GPU_FLAGS|BIND_OPTS|SBATCH_OPTS)\[@\]\}"' scripts/slurm_run.sh scripts/apptainer_run.sh \
    | grep -qFv '[@]+' \
    && { log_err "Unguarded empty-array expansion in the SLURM path — fatal under set -u on bash<4.4."; sec_errors=1; }
# Functional probe: --makefile emit must stay one 'KEY := value' line per key
# even when a host value carries a newline (else detected-env.mk is injectable).
nl_bad="$(WORKSPACE_PATH=$'x\ninjected' bash scripts/check_env.sh --makefile 2>/dev/null | grep -cvE '^[A-Z0-9_]+ := ' || true)"
[ "${nl_bad:-1}" -eq 0 ] \
    || { log_err "check_env.sh --makefile emitted a non 'KEY := value' line — newline in a host value injects make code into the cache."; sec_errors=1; }
# Execution, not grep: the pin only protects a build if a mismatch actually
# aborts, and the documented STRICT_GPG_CHECK=false escape hatch must still let
# it through. Probed with the distro keyring, so this stays offline and instant.
gpg_probe_key=/usr/share/keyrings/ubuntu-archive-keyring.gpg
if [ -f "$gpg_probe_key" ] && command -v gpg >/dev/null 2>&1; then
    gpg_probe() { STRICT_GPG_CHECK="$1" bash -c 'source scripts/util_apt_helper.sh >/dev/null 2>&1
        verify_key_fingerprint "'"$gpg_probe_key"'" 0000000000000000000000000000000000000000 probe hint' 2>&1; }
    # Capture, then inspect: under `set -o pipefail` the (correct) non-zero exit
    # of a mismatch would fail `| grep` and read as a missing message.
    gpg_strict_rc=0; gpg_strict_out="$(gpg_probe "")" || gpg_strict_rc=$?
    if [ "$gpg_strict_rc" -eq 0 ]; then
        log_err "a GPG fingerprint mismatch does NOT abort by default — the pin is decorative."; sec_errors=1
    elif ! grep -q FATAL <<< "$gpg_strict_out"; then
        log_err "a GPG fingerprint mismatch aborts without saying so (no FATAL line to diagnose)."; sec_errors=1
    fi
    gpg_probe false >/dev/null 2>&1 \
        || { log_err "STRICT_GPG_CHECK=false no longer continues past a mismatch (documented escape hatch broken)."; sec_errors=1; }
fi
[ "$sec_errors" -eq 0 ] && log_ok "Security defaults: fail-closed GPG pins, unprivileged containers, TLS snapshot, scoped xhost, guarded rm/arrays."

# =============================================================================
# [deprecated-entrypoints] Deprecated entry points must keep working. DevKit is a base kit: renaming
#      a target breaks the CI of every project built on it, so the pre-streamline
#      spellings forward to the current name. Asserted by DRY-RUN (they must
#      resolve AND delegate), plus: they must stay OUT of .PHONY/help so tab
#      completion and the guide never advertise them.
# =============================================================================
compat_errors=0
while read -r old new; do
    probe="$(make -n "$old" 2>&1 || true)"
    grep -q "is deprecated" <<< "$probe" \
        || { log_err "'make ${old}' no longer warns that it is deprecated (or the rule is gone)."; compat_errors=1; }
    # Skip the notice line first: it names the new target itself, so a plain
    # grep is satisfied by the deprecation message even with no delegation left.
    grep -v 'is deprecated' <<< "$probe" | grep -qE "(make .*${new}|devkit_make_completion)" \
        || { log_err "'make ${old}' no longer delegates to '${new}' — existing CI would silently do nothing."; compat_errors=1; }
    grep -qE "^\.PHONY:.*(^| )${old}( |$)" Makefile \
        && { log_err "deprecated target '${old}' is in .PHONY — tab completion would advertise it."; compat_errors=1; }
done <<'PAIRS'
check-host check
env-check check
completion setup
completion-install setup
PAIRS
# The in-container spelling: a function, so `hw_check --brief` still forwards.
compat_shell="$(bash --norc -ic "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1
    type -t hw_check; type -t hwcheck" 2>/dev/null)"
grep -q function <<< "$compat_shell" \
    || { log_err "hw_check() is gone — scripts calling the pre-streamline name would break."; compat_errors=1; }
# OPENCV_CUDA is a documented knob with a documented consumer (`gpu opencv_args`).
[ "$(OPENCV_CUDA=off bash scripts/setup_gpu.sh opencv_args 2>/dev/null)" = "-DWITH_CUDA=OFF" ] \
    || { log_err "OPENCV_CUDA=off no longer forces -DWITH_CUDA=OFF via 'gpu opencv_args'."; compat_errors=1; }
[ "$compat_errors" -eq 0 ] && log_ok "Deprecated entry points still forward (4 make targets, hw_check) and OPENCV_CUDA is wired."

# =============================================================================
# [cli-convention] CLI convention: every user-facing script answers --help with exit 0 and
#      rejects an unknown flag non-zero. Regressions here are silent and ugly:
#      `check_deps --help` once died with "Target directory '--help' does not
#      exist", and check_env.sh treated a typo'd mode as its shell-output
#      default — which would cache a detected-env.mk make cannot parse.
# =============================================================================
cli_errors=0
for cli in check_deps check_env check_hardware setup_gpu setup_sync_deps \
           apptainer_bake apptainer_run slurm_run util_apt_helper util_release_metadata show_welcome; do
    bash "scripts/${cli}.sh" --help >/dev/null 2>&1 \
        || { log_err "scripts/${cli}.sh does not answer --help with exit 0."; cli_errors=1; }
    rc=0; bash "scripts/${cli}.sh" --devkit-bogus-flag >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
        || { log_err "scripts/${cli}.sh accepts an unknown flag silently — a typo would run the wrong mode."; cli_errors=1; }
done
[ "$cli_errors" -eq 0 ] && log_ok "CLI convention holds (11 scripts: --help exits 0, unknown flags rejected)."

# =============================================================================
# [doc-references] Every check citation in the docs and in code comments must
#      resolve to a real check. Numbered ids drifted silently (two different
#      checks were both cited as [22]); slugs only help if the reference is
#      verified, so assert every cited slug exists here.
# =============================================================================
cited="$(grep -rhoE '(check|verify|verify`) \[[a-z][a-z-]+\]' README.md docs/*.md docker/Dockerfile \
             config/*.sh scripts/*.sh 2>/dev/null | grep -oE '\[[a-z][a-z-]+\]' | tr -d '[]' | sort -u)"
# Anti-vacuous: the citations exist (docs reference the suite in several places).
[ "$(wc -w <<< "$cited")" -ge 5 ] \
    || log_err "check-citation scan collapsed ($(wc -w <<< "$cited") found) — did the reference style change?"
dangling=()
for slug in $cited; do
    grep -q "^# \[${slug}\]" scripts/verify_repo.sh || dangling+=("$slug")
done
if [ "${#dangling[@]}" -eq 0 ]; then
    log_ok "Every documented check citation resolves ($(wc -w <<< "$cited") slugs cited)."
else
    log_err "Docs/comments cite check(s) that do not exist: ${dangling[*]}"
fi

# =============================================================================
# [venv-identity] The virtualenv is NAMED after the project and the prompt shows
#      it. Both were lost once: mkenv dropped `--prompt`, so uv fell back to the
#      directory basename (every project looked like "(.venv)"), and init_bash.sh
#      assigns PS1 AFTER activation, which discarded activate's own marker.
# =============================================================================
venv_errors=0
# Continuations joined first: the flag sits on the next physical line, and a
# per-line grep would report a false regression (it did).
venv_cmds="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' config/util_aliases.sh)"
# EVERY creation path, not just one: mkenv has two (uv, and the python3 -m venv
# fallback) and naming only one of them would hide the other.
venv_creates="$(grep -cE '(uv venv|python3 -m venv) ' <<< "$venv_cmds" || true)"
venv_named="$(grep -cE '(uv venv|python3 -m venv) [^|]*--prompt' <<< "$venv_cmds" || true)"
{ [ "$venv_creates" -ge 2 ] && [ "$venv_creates" -eq "$venv_named" ]; } \
    || { log_err "${venv_named}/${venv_creates} venv creation paths pass --prompt: an unnamed one renders as the generic '(.venv)'."; venv_errors=1; }
grep -qE '^[^#]*COMPOSE_PROJECT_NAME' config/util_aliases.sh \
    || { log_err "the venv prompt is no longer derived from COMPOSE_PROJECT_NAME."; venv_errors=1; }
# One source for the path: a stray ${WS_ROOT}/install/.venv outside the
# ${WS_VENV:-…} fallback drifts the moment WS_VENV changes.
stray_venv="$(grep -nE '\$\{WS_ROOT\}/install/\.venv' config/util_aliases.sh | grep -v 'WS_VENV:-' || true)"
[ -z "$stray_venv" ] \
    || { log_err "venv path hardcoded outside \${WS_VENV}: $(cut -d: -f1,2 <<< "$stray_venv" | tr '\n' ' ')"; venv_errors=1; }
# Rendered, not grepped: PS1 is re-expanded at every prompt, so an active venv
# must surface there regardless of the order activation and PS1 happen in.
ps1_probe="$(bash --norc -ic "VIRTUAL_ENV_PROMPT=__probe__
    WORKSPACE_PATH='${ROOT_DIR}' source config/init_bash.sh >/dev/null 2>&1
    printf %s \"\${PS1@P}\"" 2>/dev/null || true)"
grep -q '(__probe__)' <<< "$ps1_probe" \
    || { log_err "the interactive prompt does not show the active virtualenv (PS1 lost \${VIRTUAL_ENV_PROMPT})."; venv_errors=1; }
grep -q 'VIRTUAL_ENV_DISABLE_PROMPT' config/init_bash.sh \
    || { log_err "VIRTUAL_ENV_DISABLE_PROMPT is unset — running 'activate' would stack a second venv marker."; venv_errors=1; }
# `uv sync` must pin the interpreter the venv already has: compared against
# UV_PYTHON (3.10 from the image) uv REPLACES a mismatching environment, which
# turns the shared venv `mksync --share` builds for noetic back into a pure one
# and loses rospy. Reproduced before this pin existed.
# The image pre-sets VIRTUAL_ENV, so activation must not be skipped on that
# basis: a fake venv plus a pre-set VIRTUAL_ENV must still get activated.
act_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
mkdir -p "$act_probe/config" "$act_probe/install/.venv/bin"
cp config/init_bash.sh config/util_paths.sh "$act_probe/config/"
printf 'VIRTUAL_ENV_PROMPT=probe-name\n' > "$act_probe/install/.venv/bin/activate"
act_seen="$(VIRTUAL_ENV="$act_probe/install/.venv" WORKSPACE_PATH="$act_probe" \
    bash --norc -c "source '$act_probe/config/init_bash.sh' >/dev/null 2>&1; printf %s \"\${VIRTUAL_ENV_PROMPT:-}\"" 2>/dev/null || true)"
[ "$act_seen" = "probe-name" ] \
    || { log_err "config/init_bash.sh skips activation when VIRTUAL_ENV is pre-set by the image — no deactivate, no prompt (got: '${act_seen}')."; venv_errors=1; }
rm -rf "$act_probe"
grep -qE 'uv sync [^|]*--python' <<< "$venv_cmds" \
    || { log_err "uvs no longer pins 'uv sync --python <venv>': uv would replace a shared venv and drop rospy."; venv_errors=1; }
[ "$venv_errors" -eq 0 ] && log_ok "Virtualenv identity: project-named, single path source, shown in the prompt, interpreter pinned."

# =============================================================================
# [build-flags] The MOTD advertises `cbuild (--debug, --release, --pkg, --meta)`.
#      Those four were dropped in a rewrite while the advertisement stayed, so
#      assert BOTH directions: every advertised flag is handled by the parser,
#      and the resulting command line actually carries the effect (probed with a
#      stub colcon, so no build runs).
# =============================================================================
flag_errors=0
adv_flags="$(sed -n 's/^ *"cbuild|[^(]*(\([^)]*\)).*/\1/p' scripts/show_welcome.sh | tr -d ' ' | tr ',' ' ')"
[ "$(wc -w <<< "$adv_flags")" -ge 4 ] \
    || { log_err "the MOTD build-flag advertisement could not be parsed ($adv_flags) — did the row change shape?"; flag_errors=1; }
for flag in $adv_flags; do
    grep -qE "^[[:space:]]*${flag}\)" config/util_aliases.sh \
        || { log_err "MOTD advertises 'cbuild ${flag}' but __parse_build_flags does not handle it."; flag_errors=1; }
done
# The other flag the help table advertises, from a different parser.
grep -qE '^[[:space:]]*--share\)' config/util_aliases.sh \
    || { log_err "the help table advertises 'mksync [--share]' but __parse_share_flag no longer handles it."; flag_errors=1; }
# The IDE is a third advertiser: .vscode/tasks.json invokes cbuild with these
# flags, and all four tasks were silently broken while the parser was missing.
for flag in $(grep -oE 'cbuild [^"'"'"']*' .vscode/tasks.json | grep -oE '\-\-[a-z-]+' | sort -u); do
    grep -qE "^[[:space:]]*${flag}\)" config/util_aliases.sh \
        || { log_err ".vscode/tasks.json runs 'cbuild ${flag}' but __parse_build_flags does not handle it."; flag_errors=1; }
done
flag_probe="$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX")"
mkdir -p "$flag_probe/bin" "$flag_probe/config"
cp config/util_aliases.sh config/util_paths.sh "$flag_probe/config/"
printf '#!/bin/sh\necho "$*"\n' > "$flag_probe/bin/colcon"; chmod +x "$flag_probe/bin/colcon"
flag_run() { env -i PATH="$flag_probe/bin:/usr/bin:/bin" HOME=/tmp WORKSPACE_PATH="$flag_probe" \
    ROS_VERSION=2 bash -lc "source $flag_probe/config/util_aliases.sh 2>/dev/null; cbuild $1" 2>/dev/null; }
# Default: an unoptimised build is a silent performance regression.
case "$(flag_run '')"        in *-DCMAKE_BUILD_TYPE=RelWithDebInfo*) ;; *) log_err "cbuild lost its default -DCMAKE_BUILD_TYPE=RelWithDebInfo."; flag_errors=1 ;; esac
case "$(flag_run --debug)"   in *-DCMAKE_BUILD_TYPE=Debug*)          ;; *) log_err "cbuild --debug no longer selects a Debug build."; flag_errors=1 ;; esac
case "$(flag_run --release)" in *-DCMAKE_BUILD_TYPE=Release*)        ;; *) log_err "cbuild --release no longer selects a Release build."; flag_errors=1 ;; esac
case "$(flag_run '--pkg a b')" in *"--packages-select a b"*)         ;; *) log_err "cbuild --pkg no longer maps to --packages-select."; flag_errors=1 ;; esac
case "$(flag_run --meta)"    in *--metas*colcon.meta*)               ;; *) log_err "cbuild --meta no longer passes config/colcon.meta to colcon (the file would be inert)."; flag_errors=1 ;; esac
rm -rf "$flag_probe"
[ "$flag_errors" -eq 0 ] && log_ok "Advertised build flags work (default RelWithDebInfo, --debug/--release/--pkg/--meta)."

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$FAILED" -gt 0 ]; then
    echo -e "  \033[0;31m[FAIL]\033[0m ${FAILED} verification check(s) failed!" >&2
    exit 1
fi
log_ok "DevKit repository verification complete!"

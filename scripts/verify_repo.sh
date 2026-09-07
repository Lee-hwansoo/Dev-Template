#!/bin/bash
# =============================================================================
# scripts/verify_repo.sh — every check asserts a CONTRACT a past regression
# actually broke, not the presence of a string. Cheap-first and offline.
# Checks carry a STABLE SLUG ([env-bridge], …) because docs cite them.
# Every grep here is anchored to CODE ('^[^#]*' or an explicit --exclude): an
# unanchored one is satisfied by the comment that explains it.
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

# Plain echo, like the colour block above: this script must not depend on the
# files it validates. Guarding argv matters here too — a typo'd flag used to run
# the whole suite and exit 0, reporting success for a request it never honoured.
case "${1:-}" in
    "") ;;
    -h|--help)
        echo "Usage: verify_repo.sh   (no options; validates repository structure and contracts)"
        exit 0 ;;
    *) echo "verify_repo.sh: unknown option: $1" >&2; exit 2 ;;
esac

# Hermetic under `make verify`: the Makefile's bare `export` (compose needs it)
# hands every make variable to this script — COMPOSE_PROJECT_NAME made the
# clean-cache probes abort on the developer's running container,
# HOST_WORKSPACE_PATH aimed their path guard at the real tree, IMAGE_TAG beat a
# probe's .env. Drop exactly what make defined (its own settings and every key
# the .env files carry), keep the ambient locale, and the two entry points agree.
if [ -n "${MAKELEVEL:-}" ]; then
    _keep_lang="${LANG-}" _keep_lc="${LC_ALL-}" _keep_tz="${TZ-}"
    # Listed from a CLEAN environment: with the exports present, make reports
    # every `?=` setting as origin "environment" and would list none of them.
    for _mk_var in $(env -i PATH="$PATH" HOME="${HOME:-/}" make -pn help 2>/dev/null \
                     | awk '/^# makefile/ { getline; sub(/[[:space:]]*[:?+]*=.*/, ""); if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print }'); do
        unset "$_mk_var" 2>/dev/null || true
    done
    unset MAKEFLAGS MFLAGS MAKELEVEL MAKE_TERMOUT MAKE_TERMERR
    [ -z "$_keep_lang" ] || export LANG="$_keep_lang"; [ -z "$_keep_lc" ] || export LC_ALL="$_keep_lc"; [ -z "$_keep_tz" ] || export TZ="$_keep_tz"
    unset _mk_var _keep_lang _keep_lc _keep_tz
fi

FAILED=0
log_ok()  { echo -e "  \033[0;32m[OK]\033[0m $*"; }
# log_err marks the GROUP it was called in, so no check has to remember a flag
# name: `group` opens one, `ok <line>` closes it and prints only if nothing in
# between failed. Fifty hand-named *_errors flags did this before, and a check
# that set the neighbouring group's flag reported the wrong group green.
log_err() { echo -e "  \033[0;31m[ERROR]\033[0m $*" >&2; FAILED=$((FAILED+1)); GROUP_FAILED=1; }
group()   { GROUP_FAILED=0; }
ok()      { [ "${GROUP_FAILED:-0}" -eq 0 ] && log_ok "$1"; return 0; }
# A skip is not a failure: it says what this host could not check.
log_warn() { echo -e "  \033[0;33m[WARN]\033[0m $*" >&2; }
log_info(){ echo -e "  \033[0;34m[INFO]\033[0m $*"; }

# A PATH for probes that must HIDE a tool: minimal, but still holding the shell
# and the core utilities wherever this host keeps them. Hardcoding /usr/bin:/bin
# broke every such probe on a host that keeps bash in /usr/local/bin.
probe_min_path="$(dirname "$(command -v bash)"):$(dirname "$(command -v sed)"):/usr/bin:/bin"

# upstream_checks — the template's OWN content: README wording, starter examples,
# the doc map. A fork replaces those (GETTING_STARTED's ownership table) and
# must still pass, so they run only where the project still carries the
# template's name, or on request (DEVKIT_UPSTREAM=1; =0 forces them off). Kit
# BEHAVIOUR is checked everywhere.
upstream_checks() {
    case "${DEVKIT_UPSTREAM:-}" in 1) return 0 ;; 0) return 1 ;; esac
    [ "$(sed -n 's/^name = "\(.*\)"/\1/p' src/pyproject.toml 2>/dev/null)" = devkit ]
}

# docker_live — a usable docker daemon on this host. The few probes that need a
# real container run only here (the macOS runner has none) and say so.
docker_live() {
    [ -n "${DOCKER_LIVE:-}" ] || { DOCKER_LIVE=no; command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && DOCKER_LIVE=yes; }
    [ "$DOCKER_LIVE" = yes ]
}

# ONE directory per run, removed however the run ends. Each group used to
# mktemp and rm its own, so an interrupted suite (Ctrl-C, or a probe failing
# under errexit) left them behind — 45 had accumulated here. An in-process
# list would not do: several probes call probe_dir inside a command
# substitution, whose array assignment dies with the subshell.
# NOT exported: a nested run (a probe that invokes this script) would inherit
# the parent's root and its own EXIT trap would delete the tree the parent is
# still using — which is exactly how a probe workspace vanished mid-run once.
DEVKIT_PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devkit-run.XXXXXX")"
probe_cleanup() {
    # A probe may hold root-owned files (a container writing into a bind
    # mount), so a failure to remove them must not derail the exit.
    rm -rf "$DEVKIT_PROBE_ROOT" 2>/dev/null || true
}
trap probe_cleanup EXIT INT TERM

# probe_dir [name…] — a scratch tree for one check, with symlinks to the named
# top-level directories so a script under test resolves WS_ROOT there and never
# writes into the repo. Every check that needs a workspace of its own builds it
# here, so the cleanup rule lives in one place.
probe_dir() {
    local dir name
    dir="$(mktemp -d "${DEVKIT_PROBE_ROOT}/probe.XXXXXX")"
    for name in "$@"; do ln -s "${ROOT_DIR}/${name}" "${dir}/${name}"; done
    printf '%s' "$dir"
}

# The libraries that are SOURCED only: they define functions and never look at
# argv, so the CLI convention and the bash 3.2 run both skip them. One list.
sourced_only='util_logging.sh util_gpu_detect.sh util_sif_common.sh verify_repo.sh'

# probe_farm <dir> [extra tool…] — a PATH directory holding only the tools named
# (plus the shell basics every script needs), so a probe measures the code and
# not what the host happens to have installed. Three probes hand-rolled this
# loop; the mlint one then read the runner's own clang-format and inverted its
# answer on CI.
probe_farm() {
    local dir="$1" tool path; shift
    mkdir -p "$dir"
    for tool in sh bash sed awk grep find cut tr cat head tail env dirname basename \
                ls sort wc make mkdir mktemp mv rm "$@"; do
        path="$(command -v "$tool" 2>/dev/null || true)"
        [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
    done
    printf '%s' "$dir"
}

# make_probe [extra file…] — a tree a `make` can run in: the four directories a
# recipe resolves, the Makefile and .env.example, and the path resolved
# PHYSICALLY. Fourteen checks built this by hand and five of them skipped the
# `pwd -P`, which is why a probe on a host with a symlinked TMPDIR (macOS:
# /var → /private/var) compared its own path against what the recipe recorded
# and disagreed.
make_probe() {
    local dir name
    dir="$(cd "$(probe_dir scripts config docker dependencies)" && pwd -P)"
    cp "${ROOT_DIR}/Makefile" "${ROOT_DIR}/.env.example" "$@" "${dir}/"
    # …under a project name of its own, written where a local name BELONGS: the
    # probe's own .env, which the kit already resolves over .env.example. No
    # second spelling of the rule `make adopt` owns, and it is what a real fork
    # looks like. The copied .env.example carries the REPOSITORY's name, so
    # without this a probe spoke for the developer's project: `make clean` saw
    # their running container and `make adopt` their volumes, both refused —
    # correctly — and `make verify` could not run on a fork with its stack up.
    name="devkit-probe-$(printf '%s' "${dir##*/}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$name" > "${dir}/.env"
    printf '%s' "$dir"
}

# bake_argv <mode> <env> [VAR=value…] — the argv apptainer_bake.sh hands docker,
# captured from a stub. Several groups read a --build-arg out of it.
bake_argv() {
    local mode="$1" env_name="$2" dir; shift 2
    dir="$(mktemp -d "${DEVKIT_PROBE_ROOT}/bake.XXXXXX")"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 1\n' "$dir" > "$dir/docker"
    printf '#!/bin/sh\nexit 0\n' > "$dir/apptainer"
    chmod +x "$dir/docker" "$dir/apptainer"
    ( PATH="$dir:$probe_min_path" env "$@" bash scripts/apptainer_bake.sh --mode "$mode" --env "$env_name" ) >/dev/null 2>&1 || true
    cat "$dir/argv" 2>/dev/null; rm -rf "$dir"
}

log_info "Verifying DevKit repository structure, shell syntax, and contracts..."

# =============================================================================
# [required-files] Required files & executable permissions
# =============================================================================
for f in \
    Makefile docker-compose.common.yml docker-compose.dev.yml \
    docker/Dockerfile docker/entrypoint.sh docker/prod_entrypoint.sh \
    config/util_aliases.sh config/util_paths.sh config/devkit_make_completion.bash \
    config/cyclonedds.xml config/colcon.meta \
    scripts/check_env.sh scripts/setup_gpu.sh scripts/util_apt_helper.sh \
    scripts/apptainer_bake.sh scripts/apptainer_run.sh scripts/slurm_run.sh \
    scripts/util_sif_common.sh scripts/util_logging.sh \
    dependencies/apt.txt dependencies/apt_ros.txt \
    VERSION .clang-format .gitattributes \
    $(upstream_checks && echo docs/GETTING_STARTED.md docs/DEVELOPMENT.md docs/DEPENDENCIES.md docs/DEPLOY.md docs/DIAGNOSTICS.md) \
    $(upstream_checks && echo src/example/starter_node.cpp src/example/starter_node.py src/example/test_starter_node.py)
do
    [ -f "$f" ] || log_err "Missing required file: $f"
done

for f in docker/entrypoint.sh docker/prod_entrypoint.sh \
          scripts/apptainer_bake.sh scripts/apptainer_run.sh \
          scripts/slurm_run.sh scripts/verify_repo.sh; do
    [ -f "$f" ] && [ ! -x "$f" ] && log_err "Missing executable permission: $f"
done

# A UTF-8 BOM is invisible, and GNU grep silently ignores a leading one — so it
# breaks '^#' matching, hides a shebang from the kernel and makes an
# intentionally empty placeholder non-empty, with nothing to see in a diff.
bom_files="$(python3 - <<'PYBOM'
import os
bad = []
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if not d.startswith('.')
               and d not in ('build', 'install', 'log', 'logs', 'thirdparty')]
    for f in files:
        p = os.path.join(root, f)
        # Skip links: a dangling one (a bind-mounted workspace collects them)
        # made this walk abort with a traceback instead of reporting anything.
        if os.path.islink(p):
            continue
        try:
            with open(p, 'rb') as fh:
                head = fh.read(3)
        except OSError:
            continue
        if head == b'\xef\xbb\xbf':
            bad.append(p[2:])
print(' '.join(sorted(bad)))
PYBOM
)"
[ -z "$bom_files" ] || log_err "file(s) start with a UTF-8 BOM: ${bom_files}"
# `* text=auto eol=lf` in .gitattributes is the only thing standing between a
# Windows clone and CRLF in every shebang; nothing referenced it before.
grep -qE '^\*[[:space:]]+text=auto[[:space:]]+eol=lf' .gitattributes 2>/dev/null \
    || log_err ".gitattributes does not force LF ('* text=auto eol=lf'); a core.autocrlf clone breaks every script."
# A tracked file must not be ignored: the bare 'colcon.meta' pattern also hid
# config/colcon.meta, so a tree bootstrapped from an export shipped without it
# and 'cbuild --meta' found nothing.
# --no-index: without it check-ignore stays silent for files already tracked,
# which is exactly the case being tested.
ignored_tracked="$(git ls-files 2>/dev/null | git check-ignore --no-index --stdin 2>/dev/null | tr '\n' ' ' || true)"
[ -z "$ignored_tracked" ] \
    || log_err "tracked file(s) are matched by .gitignore: ${ignored_tracked}"

# The workspace is BIND-MOUNTED, so a helper link written with an absolute
# container path is written into the host tree too, where it dangles. One
# `make start` then left a broken colcon.meta and this very scan aborted with a
# traceback instead of reporting anything.
link_probe="$(probe_dir)"
mkdir -p "$link_probe/config" "$link_probe/scripts"
cp scripts/util_setup_links.sh "$link_probe/scripts/"
ln -s "${ROOT_DIR}/config/util_paths.sh" "$link_probe/config/util_paths.sh"
ln -s "${ROOT_DIR}/config/util_logging.sh" "$link_probe/config/util_logging.sh" 2>/dev/null || true
: > "$link_probe/config/colcon.meta"
( WORKSPACE_PATH="$link_probe" bash "$link_probe/scripts/util_setup_links.sh" ) >/dev/null 2>&1 || true
link_target="$(readlink "$link_probe/colcon.meta" 2>/dev/null || echo '<none>')"
# The aggregated compile_commands.json follows its inputs: written from the
# per-package files, REMOVED with the last of them (the editor kept a deleted
# file's flags), and a plain-CMake build/ (CMakeCache.txt) keeps its own.
link_run() { ( WORKSPACE_PATH="$link_probe" bash "$link_probe/scripts/util_setup_links.sh" ) >/dev/null 2>&1 || true; }
mkdir -p "$link_probe/build/pkg"; printf '[{"file":"removed.cpp","command":"cc","directory":"/w"}]\n' > "$link_probe/build/pkg/compile_commands.json"
link_run
grep -q 'removed.cpp' "$link_probe/build/compile_commands.json" 2>/dev/null && [ -L "$link_probe/compile_commands.json" ] \
    || log_err "util_setup_links.sh did not aggregate a package's compile_commands.json (or link it at the root)."
rm -rf "$link_probe/build/pkg"; link_run
{ [ ! -e "$link_probe/build/compile_commands.json" ] && [ ! -L "$link_probe/compile_commands.json" ]; } \
    || log_err "after the last package is removed, the aggregated compile_commands.json (or its root link) is left behind with stale entries."
: > "$link_probe/build/CMakeCache.txt"; printf '[]\n' > "$link_probe/build/compile_commands.json"; link_run
[ -f "$link_probe/build/compile_commands.json" ] \
    || log_err "util_setup_links.sh deleted a compile_commands.json that plain CMake (CMakeCache.txt) wrote."
case "$link_target" in
    /*) log_err "util_setup_links.sh writes an ABSOLUTE link (${link_target}); across a bind mount it dangles on the other side." ;;
    '<none>') log_err "util_setup_links.sh created no colcon.meta link; cbuild --meta would find nothing." ;;
esac
# …and a dangling link must not stop the scan above from reporting. The REAL
# scanner, extracted and run against one: it used to abort with a traceback and
# the whole suite stopped there.
ln -sfn /devkit-nonexistent-target "$link_probe/broken.link"
awk "/<<.PYBOM.\$/{f=1;next} /^PYBOM\$/{f=0} f" scripts/verify_repo.sh > "$link_probe/bom.py"
bom_rc=0
( cd "$link_probe" && python3 bom.py ) >/dev/null 2>&1 || bom_rc=$?
[ "$bom_rc" -eq 0 ] \
    || log_err "the BOM scan aborts on a dangling symlink (exit ${bom_rc}); a bind-mounted workspace collects them and the suite stops before reporting anything."
rm -rf "$link_probe"

[ "$FAILED" -eq 0 ] && log_ok "All required repository files and permissions present."

# =============================================================================
# [shell-syntax] Shell script syntax check
# =============================================================================
group
while IFS= read -r -d '' script; do
    bash -n "$script" 2>/dev/null || log_err "Syntax error in $script"
done < <(find . \( -name "*.sh" -o -name "*.bash" \) -not -path "*/.*" -print0)
ok "All shell scripts passed syntax check (bash -n)."

# =============================================================================
# [ci-workflows] A workflow's `run: |` body is shell that no local check ever
#     runs: an unterminated quote there only fails on the runner, minutes in.
# =============================================================================
# The GitHub expression syntax ${{ … }} is not shell, so it is substituted out.
wf_probe="$(probe_dir)"
for wf in .github/workflows/*.yml .github/actions/*/action.yml; do
    awk -v out="$wf_probe" -v base="$(basename "$(dirname "$wf")")-$(basename "$wf" .yml)" '
        function esc(s) { gsub(/\$\{\{[^}]*\}\}/, "X", s); return s }
        /^[[:space:]]*(- )?run: \|/ { match($0,/[^ ]/); ind=RSTART; n++
            f=sprintf("%s/%s.%02d.sh", out, base, n); inblk=1; next }
        inblk {
            if ($0 ~ /^[[:space:]]*$/) { print "" > f; next }
            match($0,/[^ ]/)
            if (RSTART <= ind) { inblk=0 } else { print esc(substr($0, ind+1)) > f; next }
        }' "$wf"
done
wf_blocks="$(find "$wf_probe" -name '*.sh' | wc -l)"
# Anti-vacuous: an extraction that yields nothing would pass silently.
[ "$wf_blocks" -ge 8 ] \
    || log_err "workflow 'run:' extraction collapsed (${wf_blocks} blocks) — did the indentation style change?"
group
for wf_block in "$wf_probe"/*.sh; do
    bash -n "$wf_block" 2>/dev/null \
        || log_err "shell syntax error in a workflow run block: ${wf_block##*/}"
done
rm -rf "$wf_probe"
ok "Every workflow 'run:' block is valid shell (${wf_blocks} blocks)."
# Every workflow grants the token nothing beyond reading the checkout, and every
# job that builds an image passes the contracts gate first (the reclaim step
# rides inside it, so no job may spell either out by hand).
wf_bad=()
wf_gates=0
wf_jobs=0
for wf in .github/workflows/*.yml; do
    # The whole block, not just the presence of one line: `packages: write`
    # added underneath satisfied a two-line check while widening the token.
    wf_perms="$(awk '/^permissions:/{p=1; next} p && /^[^ ]/{p=0} p && NF' "$wf" | tr -d ' ' | sort | tr '\n' ',')"
    [ "$wf_perms" = "contents:read," ] || wf_bad+=("${wf##*/}: top-level permissions are '${wf_perms:-none}', not exactly 'contents: read'")
    grep -qE 'actions/checkout@v[0-4]([^0-9]|$)' "$wf" && wf_bad+=("${wf##*/}: actions/checkout older than v5")
    grep -qE '^[[:space:]]+run: (sudo )?rm -rf /usr/share/dotnet|^[[:space:]]+run: make verify$' "$wf" && [ "${wf##*/}" != verify.yml ] \
        && wf_bad+=("${wf##*/}: hand-written gate step; use ./.github/actions/gate")
    # The keys directly under `on:`, read where they are — the awk stops at the
    # next top-level key, so `push:` inside a job cannot pass for a trigger.
    # No YAML parser: PyYAML is absent from the macOS runner's interpreter, and
    # a parse that silently returns nothing read as "no triggers at all".
    wf_on="$(awk '/^on:/{o=1; next} o && /^[^ ]/{exit} o && /^  [a-z_]+:/{gsub(/[[:space:]:]/,""); print}' "$wf" | sort | tr '\n' ' ')"
    case "${wf##*/}" in
        # The full-image tier costs 15-45 min a job and can say nothing a push
        # has not been told by the cheap tiers, so it must never run on one:
        # skipped jobs also left five rows (with unexpanded matrix names) on
        # every commit's check list.
        images-deep.yml)
            [ "$wf_on" = "schedule workflow_dispatch " ] \
                || wf_bad+=("images-deep.yml triggers on '${wf_on:-nothing}'; the full-image tier is cron and request only") ;;
        *)  case "$wf_on" in
                *pull_request*) ;;
                *) wf_bad+=("${wf##*/} does not run on a pull request (triggers: '${wf_on:-nothing}')") ;;
            esac ;;
    esac
    # Every job that BUILDS an image passes the gate first. Counted in this one
    # pass: project.yml is the fork's file and may be replaced wholesale.
    case "${wf##*/}" in
        images.yml|images-deep.yml)
            wf_jobs=$((wf_jobs + $(awk '/^jobs:/{j=1; next} j && /^  [a-z0-9-]+:$/{n++} END{print n+0}' "$wf")))
            wf_gates=$((wf_gates + $(grep -c 'uses: ./.github/actions/gate' "$wf" || true))) ;;
    esac
done
[ "$wf_gates" -ge 5 ] || wf_bad+=("only ${wf_gates} of the ${wf_jobs} image jobs use ./.github/actions/gate")
# Every path an image COPIES must trigger the image tier: config/ and scripts/
# are copied into every stage and sourced by the builders, yet only the two apt
# helpers were listed, so a change there was covered by no image job at all.
for wf_path in "config/\*\*" "scripts/\*\*" "docker/\*\*"; do
    [ "$(grep -c "'${wf_path}'" .github/workflows/images.yml)" -ge 2 ] \
        || wf_bad+=("images.yml does not trigger on ${wf_path//\\/} for both push and pull_request, though every image copies it")
done
# A fork that did what GETTING_STARTED says — adopted a name, removed the
# starters, replaced README — must still pass: verify.yml runs the suite on such
# a copy (the suite cannot run itself here without recursing).
for wf_fork in 'make adopt NAME=' 'rm -rf src/example docs' 'terminator # gui' 'DEVKIT_SLURM_' 'BASE_IMAGE=ubuntu:22.04@sha256'; do
    grep -qF "$wf_fork" .github/workflows/verify.yml \
        || wf_bad+=("verify.yml's fork probe does not exercise '${wf_fork}'; a contract on a fork-owned file would go unnoticed")
done
[ ${#wf_bad[@]} -eq 0 ] && log_ok "Workflows: read-only token, checkout@v5+, image jobs gated by ./.github/actions/gate." \
    || { for b in "${wf_bad[@]}"; do log_err "$b"; done; }

# =============================================================================
# [phony-targets] Makefile dry-run: every .PHONY target must be resolvable
# =============================================================================
# A wrapped .PHONY would make this and check [tab-completion] under-count
# together and still pass, so refuse the wrap.
grep -q '^\.PHONY:.*\\$' Makefile \
    && log_err ".PHONY uses a line continuation — the parsers here and in tab completion assume one line."
phony_targets="$(awk '/^\.PHONY:/ { sub(/^\.PHONY:[[:space:]]*/, ""); print }' Makefile)"
bad_targets=()
# A rule may name several targets on one line (`ci-on ci-off:`).
for t in $phony_targets; do
    grep -qE "^([^:[:space:]]+ )*${t}( [^:[:space:]]+)*:" Makefile || bad_targets+=("$t")
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
# [host-detect-contract] check_env.sh must emit every HOST_*/WSL_* key compose
#     consumes, or a mount degrades to its placeholder (no GPU/X11/ssh-agent).
# =============================================================================
# `|| true`: a broken detector must fail THIS check, not abort the suite.
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
# [compose-env-split] One template per acceleration profile; the ROS/dev split
#     lives in the dev file alone. So every service must merge an ENV anchor,
#     and both anchors must carry a healthcheck.
# =============================================================================
group
[ "$(grep -cE '^  healthcheck: \*(dev|ros)-healthcheck\r?$' docker-compose.dev.yml)" -eq 2 ] \
    || log_err "docker-compose.dev.yml must give both ENV anchors a healthcheck (the common templates no longer do)."
# Concrete services are the ones with a profile; each must inherit an ENV anchor.
compose_services="$(grep -cE '^    <<: \*(dev|ros-dev)-shared$' docker-compose.dev.yml)"
compose_profiles="$(grep -cE '^    profiles: \[' docker-compose.dev.yml)"
[ "$compose_services" -eq "$compose_profiles" ] && [ "$compose_profiles" -ge 6 ] \
    || log_err "${compose_services}/${compose_profiles} compose services merge an ENV anchor — one would run without its healthcheck, command or build target."
# The host wiring is written ONCE, in base-common; `extends` appends each
# service's own volumes to it. Two copies (one per ENV) drifted silently.
for host_mount in HOST_WORKSPACE_PATH HOST_X11_DIR HOST_XAUTHORITY HOST_XDG_RUNTIME_DIR \
                  HOST_GITCONFIG HOST_SSH_AUTH_SOCK HOST_CACHE_DIR WSL_LIB_DIR_MOUNT; do
    grep -qE "^ *- \\\$\\{[^}]*${host_mount}" docker-compose.common.yml \
        || log_err "docker-compose.common.yml no longer mounts ${host_mount} on base-common; every service loses it."
    grep -qE "^ *- \\\$\\{[^}]*${host_mount}" docker-compose.dev.yml \
        && log_err "docker-compose.dev.yml re-declares the ${host_mount} mount; base-common already carries it."
done
# The dev container's command is bash, unconditionally. APP_COMMAND and
# ROS_LAUNCH_COMMAND are documented as production knobs; read here, a .env
# written for bake-prod made `make start` run the app and restart-loop.
[ "$(grep -cE '^  command: bash$' docker-compose.dev.yml)" -eq 2 ] \
    || log_err "docker-compose.dev.yml must give both ENV anchors 'command: bash'."
grep -qE '^[^#]*(APP_COMMAND|ROS_LAUNCH_COMMAND)' docker-compose.common.yml docker-compose.dev.yml \
    && log_err "compose reads the production run command (APP_COMMAND/ROS_LAUNCH_COMMAND); the dev container would run the app instead of a shell."
ok "Compose ENV split: ${compose_profiles} services inherit an ENV anchor with a healthcheck and a bash command."

# =============================================================================
# [apt-tag-filter] APT tag-filter contract (dependencies/apt*.txt tag system)
#     - no ros_distro  → apt_ros.txt must be skipped entirely
#     - runtime        → '# dev' / '# gui' entries must never appear
# =============================================================================
apt_dry() { DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR="${ROOT_DIR}/dependencies" \
            bash scripts/util_apt_helper.sh install-packages "$@" 2>/dev/null; }
group
# Each selection is resolved ONCE; the loop below must not re-invoke the helper.
apt_all_nodistro="$(apt_dry all || true)"
apt_runtime_humble="$(apt_dry runtime humble || true)"
# Anti-vacuous: empty selections would make every assertion below pass trivially.
{ [ -n "$apt_all_nodistro" ] && [ -n "$apt_runtime_humble" ]; } \
    || log_err "APT dry-run selection came back empty — util_apt_helper.sh or the manifests broke."
grep -q '^ros-' <<< "$apt_all_nodistro" && log_err "install-packages without a distro must not select ROS packages (non-ROS image stages have no ROS apt repo)."
for tagged in $(awk -F'#' '/#[^#]*(dev|gui)([[:space:],]|$)/ && !/^[[:space:]]*#/ {gsub(/[[:space:]]/,"",$1); print $1}' dependencies/apt_ros.txt); do
    if grep -qF "${tagged//\$\{ROS_DISTRO\}/humble}" <<< "$apt_runtime_humble"; then
        log_err "runtime filter leaked a dev/gui package: ${tagged}"
    fi
done
# '!<distro>' drops a line for that distro alone: tf2-ros-py exists from
# Galactic, and the manifest written against Humble broke every Foxy build.
apt_tag_probe="$(probe_dir)"
printf 'a-${ROS_DISTRO}-x # runtime,ros2,!foxy\nb-${ROS_DISTRO}-y # runtime,ros2\n' > "$apt_tag_probe/apt_ros.txt"; : > "$apt_tag_probe/apt.txt"
apt_tag_foxy="$(DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR="$apt_tag_probe" bash scripts/util_apt_helper.sh install-packages runtime foxy 2>/dev/null | tr '\n' ' ')"
apt_tag_humble="$(DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR="$apt_tag_probe" bash scripts/util_apt_helper.sh install-packages runtime humble 2>/dev/null | tr '\n' ' ')"
{ [ "$apt_tag_foxy" = "b-foxy-y " ] && [ "$apt_tag_humble" = "a-humble-x b-humble-y " ]; } \
    || log_err "the '!<distro>' tag does not exclude per distro (foxy: '${apt_tag_foxy}', humble: '${apt_tag_humble}')."
# With NO distro the stage has no ROS repository, so a ros1/ros2 line — or a
# ${ROS_DISTRO} name, which expands to nothing — must be dropped rather than
# requested from Ubuntu as 'pkg--x'.
printf 'plain-pkg # runtime\nros-${ROS_DISTRO}-thing # runtime\ntagged # runtime,ros2\n' > "$apt_tag_probe/apt.txt"
apt_tag_nodistro="$(DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR="$apt_tag_probe" bash scripts/util_apt_helper.sh install-packages runtime 2>/dev/null | tr '\n' ' ' || true)"
[ "$apt_tag_nodistro" = "plain-pkg " ] \
    || log_err "a no-distro selection keeps ROS-only entries (got: '${apt_tag_nodistro}'); the stage has no ROS repository."
rm -rf "$apt_tag_probe"
grep -qE '^ros-\$\{ROS_DISTRO\}-tf2-ros-py #.*!foxy' dependencies/apt_ros.txt \
    || log_err "apt_ros.txt requests tf2-ros-py on foxy, where the package does not exist (Galactic+): tag it '!foxy'."
# A distro built on the wrong Ubuntu release must be refused where the repo is
# configured, by name: apt otherwise said "Unable to locate package" minutes
# later, and only for the first package it happened to try.
grep -qE 'noetic\|foxy\) want=focal' scripts/util_apt_helper.sh \
    && grep -qE 'jazzy\|kilted\|rolling\) want=noble' scripts/util_apt_helper.sh \
    || log_err "setup-ros-repo does not check the distro against the base image's codename; apt reports it much later as a missing package."
grep -qE '^[^#]*lsb_release' scripts/util_apt_helper.sh \
    && log_err "util_apt_helper.sh calls lsb_release again; it drags python3 into every 20.04/22.04 base for a string /etc/os-release carries."
if docker_live; then
    apt_codename_live="$( docker run --rm -v "${ROOT_DIR}/scripts/util_apt_helper.sh:/h.sh:ro" -e DEBIAN_FRONTEND=noninteractive \
        ubuntu:22.04 bash -c 'bash /h.sh setup-ros-repo jazzy 2>&1; echo "rc=$?"' 2>/dev/null | tail -n 3 | tr '\n' ' ' || true )"
    grep -q 'published for Ubuntu noble' <<< "$apt_codename_live" && ! grep -q 'rc=0' <<< "$apt_codename_live" \
        || log_err "on a jammy base, 'setup-ros-repo jazzy' does not refuse by name (got: ${apt_codename_live})."
fi
# …and CI resolves the whole selection against each distro's own index, foxy included.
grep -qE "'ubuntu:20\.04\|foxy\|final'" .github/workflows/images.yml \
    || log_err "images.yml no longer resolves the package selection against foxy's own index (snapshot final); a package missing from one distro is found four minutes into a build."
# `make lint` is the CI style gate, so "Lint clean" must mean a checker ran on
# every tree the build can reach: a root-level project (cbuild's first choice)
# was never linted, and C/C++ sources with no clang-format installed reported
# clean. Against a stubbed interpreter that records what ruff was pointed at,
# and a symlink farm for PATH: read from the host's own PATH this probe measures
# whichever branch the RUNNER happens to have (ubuntu-latest ships
# clang-format), so all four answers are pinned here instead.
lint_probe="$(probe_dir config scripts)"
mkdir -p "$lint_probe/src" "$lint_probe/bin" "$lint_probe/venv"
: > "$lint_probe/CMakeLists.txt"; : > "$lint_probe/root.py"; : > "$lint_probe/src/a.cpp"
printf '#!/bin/sh\ncase "$*" in *"ruff --version"*) echo 0.6.0; exit 0 ;; esac\nprintf "%%s\\n" "$@" >> "%s/ruff.log"\nexit 0\n' \
    "$lint_probe" > "$lint_probe/venv/python3"; chmod +x "$lint_probe/venv/python3"
probe_farm "$lint_probe/bin" >/dev/null
lint_run() {   # lint_run [VAR=value…] → "<rc> <output>"; PATH is the farm alone
    local rc=0 out
    out="$( cd "$lint_probe" && PATH="$lint_probe/bin" WORKSPACE_PATH="$lint_probe" env "$@" \
      bash -c 'source config/util_paths.sh >/dev/null 2>&1; source config/util_aliases.sh >/dev/null 2>&1
               WS_VENV_PY='"$lint_probe"'/venv/python3 mlint' 2>&1 )" || rc=$?
    printf '%s %s' "$rc" "$out"
}
lint_out="$(lint_run DEVKIT_UNUSED=1)"
{ [ "${lint_out%% *}" -ne 0 ] && grep -q 'clang-format is not installed' <<< "$lint_out"; } \
    || log_err "mlint reports success (rc ${lint_out%% *}) with C/C++ sources present and no clang-format; the CI style gate is decorative."
# The escape hatch that same message advertises has to work, or fail-closed is
# a wall for a project that accepts an unchecked C/C++ half.
lint_out="$(lint_run DEVKIT_SKIP_CLANG_FORMAT=1)"
[ "${lint_out%% *}" -eq 0 ] \
    || log_err "DEVKIT_SKIP_CLANG_FORMAT=1 does not let mlint through (rc ${lint_out%% *}); the message names an escape hatch that is not one."
# And with a formatter present its verdict is mlint's: a stub that reports a
# violation must fail the gate, a clean one must pass it.
printf '#!/bin/sh\nexit 1\n' > "$lint_probe/bin/clang-format"; chmod +x "$lint_probe/bin/clang-format"
lint_out="$(lint_run DEVKIT_UNUSED=1)"
[ "${lint_out%% *}" -ne 0 ] \
    || log_err "mlint reports success while clang-format reports a violation; the C/C++ half is decorative."
printf '#!/bin/sh\nexit 0\n' > "$lint_probe/bin/clang-format"
lint_out="$(lint_run DEVKIT_UNUSED=1)"
[ "${lint_out%% *}" -eq 0 ] \
    || log_err "mlint fails (rc ${lint_out%% *}) with a clang-format that reports clean: ${lint_out#* }"
rm -f "$lint_probe/bin/clang-format"
# The escape hatch has to cross the container boundary: `docker exec` forwards
# none of the caller's environment, so DEVKIT_SKIP_CLANG_FORMAT set on the HOST
# reached nothing and `make lint` stayed red while telling the user to set it.
lint_fwd="$(DEVKIT_SKIP_CLANG_FORMAT=1 make -n lint 2>/dev/null | sed -n "s/.*CMD='\(.*\)'.*/\1/p" | head -n 1)"
case "$lint_fwd" in
    *DEVKIT_SKIP_CLANG_FORMAT=*mlint*) ;;
    *) log_err "'make lint' does not carry DEVKIT_SKIP_CLANG_FORMAT into the container (runs: '${lint_fwd:-nothing}'); the escape hatch mlint advertises does nothing from the host." ;;
esac
grep -qF "$lint_probe" "$lint_probe/ruff.log" 2>/dev/null && grep -qxF "$lint_probe" "$lint_probe/ruff.log" 2>/dev/null \
    || log_err "mlint does not point ruff at the repository root, where a root CMake project's python lives (args: $(tr '\n' ' ' < "$lint_probe/ruff.log" 2>/dev/null))."
# …and a CMake project's python tests must still run: ctest alone dropped them
# while `make test` stayed green.
mkdir -p "$lint_probe/build"; : > "$lint_probe/src/test_thing.py"
printf '#!/bin/sh\necho "ctest $*" >> "%s/run.log"\n' "$lint_probe" > "$lint_probe/bin/ctest"; chmod +x "$lint_probe/bin/ctest"
printf '#!/bin/sh\ncase "$*" in *pytest*) echo "pytest $*" >> "%s/run.log" ;; esac\nexit 0\n' "$lint_probe" > "$lint_probe/venv/py2"; chmod +x "$lint_probe/venv/py2"
( cd "$lint_probe" && PATH="$lint_probe/bin:$probe_min_path" WORKSPACE_PATH="$lint_probe" \
  bash -c 'source config/util_paths.sh >/dev/null 2>&1; source config/util_aliases.sh >/dev/null 2>&1
           WS_VENV_PY='"$lint_probe"'/venv/py2 mtest' ) >/dev/null 2>&1 || true
{ grep -q '^ctest ' "$lint_probe/run.log" && grep -q 'pytest' "$lint_probe/run.log"; } \
    || log_err "mtest on a CMake project runs '$(tr '\n' ' ' < "$lint_probe/run.log" 2>/dev/null)' — the python tests beside it are dropped and 'make test' stays green."
rm -rf "$lint_probe"

# ROS 1 rewrites BOTH sides of the master pairing: compose always sets a
# non-empty ROS_MASTER_URI (localhost), so a ':-' default never fired and under
# NETWORK_MODE=bridge the node looked for roscore inside its own container.
for ros1_case in "http://localhost:11311 rewritten" "http://127.0.0.1:11311 rewritten" "http://robot1:11311 kept"; do
    set -- $ros1_case
    ros1_out="$( ROS_DISTRO=noetic ROS_MASTER_URI="$1" bash -c 'source config/util_paths.sh >/dev/null 2>&1
        source config/init_ros_env.sh >/dev/null 2>&1; printf %s "$ROS_MASTER_URI"' 2>/dev/null || true )"
    case "$2" in
        rewritten) [ "$ros1_out" != "$1" ] || log_err "ROS 1 keeps ROS_MASTER_URI=$1; under bridge networking roscore is looked for inside the container." ;;
        kept)      [ "$ros1_out" = "$1" ] || log_err "ROS 1 rewrites an explicit ROS_MASTER_URI=$1 to '${ros1_out}'." ;;
    esac
done
# A half-initialised venv must be recoverable: an empty root-created .venv made
# every later mksync fail with uv's raw error and no way out.
grep -qE '^[^#]*clear=\(--clear\)' config/util_aliases.sh \
    || log_err "mkenv does not pass --clear when the venv directory exists without an interpreter; mksync then fails forever."

# mtest's CMake branch must RUN from build/: --test-dir arrived in CMake 3.20 and
# 20.04 (noetic) ships 3.16, which ignores the flag and tests the CWD instead —
# a green mtest that ran none of the project's tests. Against a ctest stub that
# records the directory it was started in.
mtest_probe="$(probe_dir config scripts)"
mkdir -p "$mtest_probe/build" "$mtest_probe/bin"
: > "$mtest_probe/CMakeLists.txt"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$(pwd -P)" "$*" > "%s/ctest.log"\n' "$mtest_probe" > "$mtest_probe/bin/ctest"
chmod +x "$mtest_probe/bin/ctest"
( cd "$mtest_probe" && PATH="$mtest_probe/bin:$probe_min_path" WORKSPACE_PATH="$mtest_probe" \
  bash -c 'source config/util_aliases.sh >/dev/null 2>&1; mtest' ) >/dev/null 2>&1 || true
mtest_seen="$(cat "$mtest_probe/ctest.log" 2>/dev/null || echo '<ctest never ran>')"
mtest_want="$(cd "$mtest_probe/build" && pwd -P)"
case "$mtest_seen" in
    "${mtest_want}|"*) case "$mtest_seen" in
            *--test-dir*) log_err "mtest passes --test-dir, which CMake 3.16 (noetic) ignores (${mtest_seen})." ;;
        esac ;;
    *) log_err "mtest started ctest in '${mtest_seen%%|*}', not the build directory; on CMake 3.16 that runs the caller's cwd tests (${mtest_seen})." ;;
esac
rm -rf "$mtest_probe"
ok "APT tag-filter contract holds (no-distro selection excludes ros-*, runtime excludes dev/gui, '!<distro>' excludes per distro)."

# The user's GPU_MODE reaches the CONTAINER as written: intel and amd share the
# iGPU compose profile but are distinct vocabulary for the in-container `gpu`
# helper (iris vs radeonsi), and mapping the variable itself to 'igpu' before
# the export replaced the user's answer with the generic mesa path.
gpumode_probe="$(make_probe)"
# Appended, not --eval: that option needs GNU make 3.82 and macOS ships 3.81.
printf '\n__svc: ; @$(RESOLVE_SVC_MODE); echo "$$TARGET_SVC"\n' >> "$gpumode_probe/Makefile"
for gpumode_case in "intel igpu" "amd igpu" "cpu cpu" "nvidia nvidia"; do
    set -- $gpumode_case
    gpumode_out="$( cd "$gpumode_probe" && GPU_MODE="$1" make -pn help 2>/dev/null | sed -n 's/^GPU_MODE = //p' | head -n 1 || true )"
    [ "$gpumode_out" = "$1" ] \
        || log_err "GPU_MODE=$1 reaches the container as '${gpumode_out}'; the in-container gpu helper would pick the wrong driver."
    gpumode_svc="$( cd "$gpumode_probe" && GPU_MODE="$1" make __svc 2>/dev/null | tail -n 1 || true )"
    [ "${gpumode_svc##*-}" = "$2" ] \
        || log_err "GPU_MODE=$1 selects the compose service '${gpumode_svc}' (expected the -$2 profile)."
done
gpumode_rc=0; ( cd "$gpumode_probe" && GPU_MODE=bogus make -n build ) >/dev/null 2>&1 || gpumode_rc=$?
[ "$gpumode_rc" -ne 0 ] \
    || log_err "GPU_MODE=bogus is accepted; compose would fall back to a profile nobody asked for."
rm -rf "$gpumode_probe"

# =============================================================================
# [gpu-env-persist] GPU environment persistence: `docker exec` shells do not run the
#     entrypoint, so setup_gpu.sh must leave its env in GPU_ENV_FILE.
# =============================================================================
gpu_env_probe="$(probe_dir)"
# …and a NEW shell reads the image default (/etc/profile.d copy of the first
# mode) and then the user's file: a switch cpu → intel left the cpu-only
# variables (QT_XCB_FORCE_SOFTWARE_OPENGL, llvmpipe) standing, so the file must
# reset every owned variable before it exports the new mode's.
gpu_switch_ok=0
if ( GPU_ENV_FILE="${gpu_env_probe}/default.sh" HOME="$gpu_env_probe" bash -c 'source scripts/setup_gpu.sh cpu' >/dev/null 2>&1 ) \
   && ( GPU_ENV_FILE="${gpu_env_probe}/user.sh" HOME="$gpu_env_probe" bash -c 'source scripts/setup_gpu.sh intel' >/dev/null 2>&1 ); then
    gpu_after="$(bash -c "source '${gpu_env_probe}/default.sh'; source '${gpu_env_probe}/user.sh'; echo \"\${QT_XCB_FORCE_SOFTWARE_OPENGL:-unset} \${LIBGL_ALWAYS_SOFTWARE:-unset} \${DEVKIT_GPU_MODE_ACTIVE:-unset}\"" 2>/dev/null)"
    [ "$gpu_after" = "unset 0 intel" ] && gpu_switch_ok=1
fi
if ( GPU_ENV_FILE="${gpu_env_probe}/gpu_env.sh" HOME="$gpu_env_probe" \
     bash -c 'source scripts/setup_gpu.sh cpu' >/dev/null 2>&1 ) \
   && grep -q "LIBGL_ALWAYS_SOFTWARE" "${gpu_env_probe}/gpu_env.sh" 2>/dev/null && [ "$gpu_switch_ok" -eq 1 ]; then
    log_ok "setup_gpu.sh persists the GPU environment for non-entrypoint shells, and a mode switch clears the previous mode there too."
elif [ "$gpu_switch_ok" -eq 0 ]; then
    log_err "a persisted GPU file does not reset the previous mode: after cpu → intel a new shell saw '${gpu_after:-<no file>}' (expected 'unset 0 intel')."
else
    log_err "setup_gpu.sh did not write GPU_ENV_FILE; 'make shell' sessions would lose GPU settings."
fi
# The persisted file must PREPEND, never assign: it is generated during boot,
# before ROS is sourced, so a whole-path snapshot wipes /opt/ros/<distro>/lib in
# every shell that re-reads it — `import rclpy` then dies on a missing
# librcl_action.so.
gpu_ld_probe="$(probe_dir)"
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
# The quality loop counts too: `make test` reaches mtest through `make exec`,
# and mtest's ROS branch calls cbt/cbtr. As aliases those expanded only in an
# interactive shell, so `make test ENV=ros` died with "cbt: command not found"
# — invisible here because the starter carries no package.xml and the pure
# Python branch runs instead. Probed per ROS generation for that reason.
entry_probe() {
    bash -lc "WORKSPACE_PATH='${ROOT_DIR}' ROS_DISTRO='$1' ROS_VERSION='$2' \
        source config/util_aliases.sh 2>/dev/null
        for fn in cbuild mbuild mksync mkenv mtest mlint cbt cbtr; do
            printf '%s=%s ' \"\$fn\" \"\$(type -t \"\$fn\" 2>/dev/null || echo missing)\"
        done" 2>/dev/null
}
group
for entry_gen in "humble 2" "noetic 1"; do
    # shellcheck disable=SC2086  # deliberate split into distro + generation
    non_interactive_callables="$(entry_probe ${entry_gen})"
    for entry_fn in cbuild mbuild mksync mkenv mtest mlint cbt cbtr; do
        [[ "$non_interactive_callables" == *"${entry_fn}=function"* ]] \
            || log_err "${entry_fn} is not a function on ROS ${entry_gen%% *}; a non-interactive shell (docker build, make exec, make test) cannot call it."
    done
done
ok "Build and quality entry points are functions on both ROS generations — callable from docker build and 'make exec'."

# =============================================================================
# [config-precedence] One order for every public setting, whichever door it
#      comes through: command line > environment > .env > .env.example, with
#      LANG/TZ/DEBIAN_FRONTEND file-first. Included as make syntax, the files
#      beat the environment (`APT_SNAPSHOT_DATE=… make bake-prod` built
#      'latest'), a quoted UV_SYNC_FLAGS reached compose quoted, and an
#      explicit HOST_XAUTHORITY was replaced by the detector's placeholder.
#      Duplicate keys follow Compose too: the last assignment in a file wins.
# =============================================================================
group
prec_probe="$(probe_dir config scripts docker dependencies)"
cp Makefile "$prec_probe/"
printf 'IMAGE_TAG=fromexample\nAPT_SNAPSHOT_DATE=latest\nLANG=C.UTF-8\nUV_SYNC_FLAGS=\nDESC=plain\nDEFAULT_DUP=first\nDEFAULT_DUP=last\n' > "$prec_probe/.env.example"
printf 'IMAGE_TAG=shadowed\nIMAGE_TAG=fromenv\nUV_SYNC_FLAGS="--extra cpu"\nUV_SYNC_FLAGS="--extra gpu"\nDESC=a value # a comment\nSIF_FILE='"'"'/tmp/x y.sif'"'"'\n' > "$prec_probe/.env"
# prec_value <VAR> [env…] — the value make resolves for VAR in the probe tree.
prec_value() {
    local var="$1"; shift
    ( cd "$prec_probe" && env "$@" make -pn help 2>/dev/null | sed -n "s/^${var} = //p" | head -n 1 )
}
while IFS='|' read -r label want var envs; do
    # shellcheck disable=SC2086  # deliberate word split: the env assignments
    got="$(prec_value "$var" $envs)"
    [ "$got" = "$want" ] \
        || log_err "config precedence, ${label}: ${var}='${got}', expected '${want}'."
done <<'CASES'
.env beats .env.example|fromenv|IMAGE_TAG|DEVKIT_UNUSED=1
.env uses its last duplicate assignment|--extra gpu|UV_SYNC_FLAGS|DEVKIT_UNUSED=1
.env.example uses its last duplicate assignment|last|DEFAULT_DUP|DEVKIT_UNUSED=1
the environment beats .env|fromshell|IMAGE_TAG|IMAGE_TAG=fromshell
the environment beats .env.example|20260801T000000Z|APT_SNAPSHOT_DATE|APT_SNAPSHOT_DATE=20260801T000000Z
the file beats an ambient LANG|C.UTF-8|LANG|LANG=ko_KR.UTF-8
a quoted value loses its quotes|--extra gpu|UV_SYNC_FLAGS|DEVKIT_UNUSED=1
an unquoted ' # …' tail is a comment|a value|DESC|DEVKIT_UNUSED=1
a single-quoted value keeps its spaces|/tmp/x y.sif|SIF_FILE|DEVKIT_UNUSED=1
CASES
# A value is DATA. `make -pn` prints the definition, so these two read what a
# RECIPE resolves and what a child process inherits: '$' used to be expanded as
# a make variable ('log/$USER.log' reached compose as 'log/SER.log') and a
# trailing backslash continued the line, swallowing the key below it.
printf 'ESC_DOLLAR=log/$USER.log\nESC_TAIL=C:\\data\\\nESC_NEXT=/runs\n' >> "$prec_probe/.env"
# Appended to the copied Makefile rather than passed with --eval (see the
# GPU_MODE probe above: macOS ships GNU make 3.81, which has no --eval).
{ printf '\n__esc: ; @printf "%%s|%%s|%%s\\n" '"'"'$(ESC_DOLLAR)'"'"' '"'"'$(ESC_TAIL)'"'"' '"'"'$(ESC_NEXT)'"'"'\n'
  printf '__esc2: ; @env | sed -n "s/^ESC_DOLLAR=//p"\n'; } >> "$prec_probe/Makefile"
prec_expanded="$(cd "$prec_probe" && make __esc 2>/dev/null || true)"
[ "$prec_expanded" = 'log/$USER.log|C:\data\|/runs' ] \
    || log_err "config precedence: a value carrying '\$' or a trailing backslash is mangled — a recipe resolves '${prec_expanded}' (expected 'log/\$USER.log|C:\data\|/runs')."
prec_child="$(cd "$prec_probe" && make __esc2 2>/dev/null || true)"
[ "$prec_child" = 'log/$USER.log' ] \
    || log_err "config precedence: the value exported to a child process is '${prec_child}' (expected 'log/\$USER.log'); compose would build from the mangled string."
[ "$(cd "$prec_probe" && make -pn help IMAGE_TAG=fromcli 2>/dev/null | sed -n 's/^IMAGE_TAG = //p' | head -n 1)" = fromcli ] \
    || log_err "config precedence: the make command line does not beat .env."
# The one parser, read from a script too.
[ "$(bash -c 'source config/util_paths.sh; devkit_env_value UV_SYNC_FLAGS "$1"' _ "$prec_probe/.env")" = "--extra gpu" ] \
    || log_err "devkit_env_value reads a quoted value differently from make."
# HOST_XAUTHORITY: an explicit existing file is emitted verbatim, a missing one fails, unset detects.
: > "$prec_probe/my.xauth"
prec_xauth() { ( cd "$prec_probe" && env "$@" HOST_CACHE_DIR="$prec_probe/cache" bash scripts/check_env.sh --makefile 2>&1 ); }
grep -q "^HOST_XAUTHORITY := $prec_probe/my.xauth$" <<< "$(prec_xauth HOST_XAUTHORITY="$prec_probe/my.xauth")" \
    || log_err "an explicit HOST_XAUTHORITY is not the one the detector emits."
printf 'HOST_XAUTHORITY=%s\n' "$prec_probe/my.xauth" >> "$prec_probe/.env"
grep -q "^HOST_XAUTHORITY := $prec_probe/my.xauth$" <<< "$(prec_xauth DEVKIT_ENV_FILE="$prec_probe/.env")" \
    || log_err "a HOST_XAUTHORITY set in .env is not the one the detector emits."
prec_rc=0; prec_out="$(prec_xauth HOST_XAUTHORITY="$prec_probe/absent.xauth")" || prec_rc=$?
{ [ "$prec_rc" -ne 0 ] && grep -q 'HOST_XAUTHORITY.*not a file' <<< "$prec_out"; } \
    || log_err "a HOST_XAUTHORITY that names a missing file is downgraded to the placeholder instead of failing (rc=${prec_rc})."
rm -rf "$prec_probe"
ok "Config precedence: command line > environment > .env > .env.example (last duplicate wins; LANG/TZ file-first), quotes dropped, HOST_XAUTHORITY honoured."

# =============================================================================
# [device-groups] A GPU node exposed into the container carries the HOST's gid
#      (root:render 0660 on native Linux); the account setpriv --init-groups
#      switches to must be in a group with that gid or it sees the node and
#      cannot open it. The entrypoint's function, executed against stubs that
#      record what usermod/groupadd are handed.
# =============================================================================
group
devgrp_probe="$(probe_dir)"
mkdir -p "$devgrp_probe/bin" "$devgrp_probe/dev"
: > "$devgrp_probe/dev/renderD128"; : > "$devgrp_probe/dev/card0"; : > "$devgrp_probe/dev/dxg"; : > "$devgrp_probe/dev/video0"
# stat: renderD128 → 44 (a known group), card0 → 999 (no group yet), dxg → 0, video0 → 27 (already a member)
printf '#!/bin/sh\nfor a; do :; done\ncase "$a" in *renderD128) echo 44;; *card0) echo 999;; *video0) echo 27;; *) echo 0;; esac\n' > "$devgrp_probe/bin/stat"
printf '#!/bin/sh\ncase "$1" in -u) echo 0;; -G) echo "1000 27";; esac\n' > "$devgrp_probe/bin/id"
printf '#!/bin/sh\n[ "$2" = 44 ] && echo "render:x:44:"\n' > "$devgrp_probe/bin/getent"
printf '#!/bin/sh\necho "groupadd $*" >> "%s/calls"\n' "$devgrp_probe" > "$devgrp_probe/bin/groupadd"
printf '#!/bin/sh\necho "usermod $*" >> "%s/calls"\n' "$devgrp_probe" > "$devgrp_probe/bin/usermod"
chmod +x "$devgrp_probe/bin/"*
awk '/^grant_device_groups\(\)/{f=1} f{print} f && /^}/{exit}' docker/entrypoint.sh > "$devgrp_probe/fn.sh"
( cd "$devgrp_probe" && PATH="$devgrp_probe/bin:$probe_min_path" CONTAINER_USER=user \
  bash -c 'log_ok() { :; }; log_warn() { :; }; source ./fn.sh; grant_device_groups dev/renderD128 dev/card0 dev/dxg dev/video0 dev/absent' ) >/dev/null 2>&1 || true
devgrp_calls="$( { cat "$devgrp_probe/calls" 2>/dev/null || true; } | tr '\n' ';')"
[ "$devgrp_calls" = "usermod -aG render user;groupadd -g 999 devkit-dev-999;usermod -aG devkit-dev-999 user;" ] \
    || log_err "grant_device_groups handed '${devgrp_calls:-nothing}' to usermod/groupadd (expected: render for gid 44, a new devkit-dev-999 for gid 999, nothing for gid 0 or a group the user already has)."
grep -qE '^grant_device_groups$' docker/entrypoint.sh \
    || log_err "docker/entrypoint.sh defines grant_device_groups but never calls it before the privilege drop."
rm -rf "$devgrp_probe"
ok "Device groups: the container user joins the group of every exposed GPU node before privileges drop."

# =============================================================================
# [dds-config] config/cyclonedds.xml must change something and say what it
#      changes: AllowMulticast=default was a no-op under a comment describing
#      the opposite, and nothing told a multi-interface host how to pin the
#      LAN interface — CycloneDDS picks one arbitrarily and discovery then
#      fails silently.
# =============================================================================
group
dds_multicast="$(python3 - <<'PYDDS' 2>/dev/null || echo 'parse failed'
import xml.etree.ElementTree as ET
ns = {'c': 'https://cdds.io/config'}
root = ET.parse('config/cyclonedds.xml').getroot()
el = root.find('.//c:General/c:AllowMulticast', ns)
print(el.text.strip() if el is not None and el.text else 'missing')
PYDDS
)"
case "$dds_multicast" in
    spdp|false|true) ;;
    *) log_err "cyclonedds.xml AllowMulticast is '${dds_multicast}': 'default' changes nothing, and the file must parse." ;;
esac
grep -q '<NetworkInterfaceAddress>' config/cyclonedds.xml && grep -q 'NetworkInterface name=' config/cyclonedds.xml \
    || log_err "cyclonedds.xml must show interface pinning for CycloneDDS 0.7-0.8 and 0.9+."
grep -qiE 'bridge' config/cyclonedds.xml && grep -qiE 'host|mirrored' config/cyclonedds.xml \
    || log_err "cyclonedds.xml's Peers comment does not say which network modes share the loopback it relies on."
ok "DDS config: AllowMulticast=${dds_multicast} takes effect, interface pinning is offered, the Peers comment names its network modes."

# =============================================================================
# [detector-cache] The cache write must be atomic and a failed probe fatal: a
#     partial cache is reused forever and every mount degrades silently.
# =============================================================================
# Run, in a probe tree: a detector input the detector refuses (a relative cache
# dir) must stop make with the named error and leave NO cache file behind — not
# a partial one, not a mktemp leftover; a good run leaves exactly one.
group
cache_probe="$(make_probe)"
cache_rc=0
cache_out="$(cd "$cache_probe" && env -u DOCKER_DEV_CACHE_DIR make -n bake-prod DOCKER_DEV_CACHE_DIR=relative/cache 2>&1)" || cache_rc=$?
{ [ "$cache_rc" -ne 0 ] && grep -q 'Host environment detection failed' <<< "$cache_out"; } \
    || log_err "a failed host probe does not stop make with 'Host environment detection failed' (rc ${cache_rc})."
[ -z "$(find "$cache_probe/.docker_cache" -name 'detected-env*' 2>/dev/null)" ] \
    || log_err "a failed host probe left a cache file behind ($(cd "$cache_probe/.docker_cache" && ls detected-env* | tr '\n' ' ')); the freshness guard would reuse it forever."
(cd "$cache_probe" && env -u DOCKER_DEV_CACHE_DIR make -n bake-prod) >/dev/null 2>&1 || true
[ "$(find "$cache_probe/.docker_cache" -name 'detected-env*' 2>/dev/null | wc -l)" -eq 1 ] \
    || log_err "a successful host probe did not leave exactly one detected-env*.mk (found: $(cd "$cache_probe/.docker_cache" 2>/dev/null && ls detected-env* 2>/dev/null | tr '\n' ' '))."
# …and the cache must still DESCRIBE this host. A copy of the checkout kept
# mounting the ORIGINAL directory as /workspace, and session-scoped paths (the
# X cookie, the ssh-agent socket) survived a re-login, so compose created
# root-owned directories at the dead paths.
cache_moved="$(cd "$(probe_dir)" && pwd -P)"
cp -R "$cache_probe/.docker_cache" "$cache_moved/" 2>/dev/null || true
cp Makefile "${ROOT_DIR}/.env.example" "$cache_moved/"
for cache_link in scripts config docker dependencies; do ln -s "${ROOT_DIR}/${cache_link}" "$cache_moved/${cache_link}"; done
# The cache must look FRESH to the mtime guard, or this probe proves nothing.
touch "$cache_moved/.docker_cache/"detected-env*.mk 2>/dev/null || true
# Two -e, not '\?': that quantifier is GNU BRE, and BSD sed read it as a
# literal '?' — the value came back empty on macOS and the assertion below
# blamed the cache for the suite's own regex.
cache_ws="$(cd "$cache_moved" && env -u DOCKER_DEV_CACHE_DIR make -pn build 2>/dev/null \
    | sed -n -e 's/^HOST_WORKSPACE_PATH := //p' -e 's/^HOST_WORKSPACE_PATH = //p' | head -n 1 || true)"
[ "$cache_ws" = "$cache_moved" ] \
    || log_err "a cache copied from another checkout is reused: HOST_WORKSPACE_PATH is '${cache_ws}', not '${cache_moved}' — the container would mount the old tree."
# A cache naming a path that has since disappeared (the X cookie and the
# ssh-agent socket are new at every login) must be re-probed, not reused.
( cd "$cache_moved" && env -u DOCKER_DEV_CACHE_DIR make -pn build ) >/dev/null 2>&1 || true
cache_file="$(find "$cache_moved/.docker_cache" -name 'detected-env*.mk' 2>/dev/null | head -n 1)"
if [ -n "$cache_file" ]; then
    sed -i.bak "s|^HOST_XAUTHORITY := .*|HOST_XAUTHORITY := ${cache_moved}/gone.xauth|" "$cache_file" && rm -f "${cache_file}.bak"
    touch "$cache_file"
    cache_dead="$(cd "$cache_moved" && env -u DOCKER_DEV_CACHE_DIR make -pn build 2>/dev/null | sed -n 's/^HOST_XAUTHORITY := //p' | head -n 1 || true)"
    [ "$cache_dead" != "${cache_moved}/gone.xauth" ] \
        || log_err "a cache naming a HOST_XAUTHORITY that no longer exists is reused; compose would re-create the dead path as a root-owned directory and X auth would be silently gone."
    # …and the same answer where sed is BSD's. The gate read both session paths
    # with one GNU-only '\|' alternation, so on macOS the list came back EMPTY,
    # the loop had nothing to test, and every dead path passed as fresh. A sed
    # that refuses GNU-only BRE, exactly as /usr/bin/sed on a Mac does.
    cache_bsd="$cache_moved/bsdsed"; mkdir -p "$cache_bsd"
    cat > "$cache_bsd/sed" <<'BSDSED'
#!/bin/sh
# BSD sed has no GNU BRE extensions: '\|', '\+' and '\?' are literal
# characters there, so an expression written with them matches nothing and
# prints nothing — quietly, with exit 0. That silence is the failure mode.
for arg in "$@"; do
    case "$arg" in
        *'\|'*|*'\+'*|*'\?'*) exit 0 ;;
    esac
done
BSDSED
    printf 'exec %s "$@"\n' "$(command -v sed)" >> "$cache_bsd/sed"; chmod +x "$cache_bsd/sed"
    sed -i.bak "s|^HOST_XAUTHORITY := .*|HOST_XAUTHORITY := ${cache_moved}/gone.xauth|" "$cache_file" && rm -f "${cache_file}.bak"
    touch "$cache_file"
    cache_bsd_out="$(cd "$cache_moved" && PATH="$cache_bsd:$PATH" env -u DOCKER_DEV_CACHE_DIR make -pn build 2>/dev/null || true)"
    cache_bsd_ws="$(sed -n 's/^HOST_WORKSPACE_PATH := //p' <<< "$cache_bsd_out" | head -n 1)"
    cache_bsd_dead="$(sed -n 's/^HOST_XAUTHORITY := //p' <<< "$cache_bsd_out" | head -n 1)"
    # Anti-vacuous: the run itself must have resolved this host, or an aborted
    # make would read as "re-probed".
    { [ "$cache_bsd_ws" = "$cache_moved" ] && [ "$cache_bsd_dead" != "${cache_moved}/gone.xauth" ]; } \
        || log_err "under BSD sed the freshness gate reuses a cache naming a dead session path (workspace '${cache_bsd_ws}', xauthority '${cache_bsd_dead}'); on macOS the X cookie and the ssh-agent socket were never re-probed."
else
    log_err "the moved-checkout probe produced no detected-env*.mk to test."
fi
# A probe speaks for itself, never for the repository. The copied .env.example
# used to carry the real COMPOSE_PROJECT_NAME, so on an adopted fork a probe was
# the developer's project: `make clean` found their running container and
# `make adopt` their volumes, both refused — correctly — and `make verify` could
# not be run with the stack up, which is when a developer runs it.
cache_ident="$(make_probe)"
cache_ident_name="$(cd "$cache_ident" && env -u DOCKER_DEV_CACHE_DIR make -pn help 2>/dev/null | sed -n 's/^COMPOSE_PROJECT_NAME = //p' | head -n 1)"
case "$cache_ident_name" in
    devkit-probe-*) ;;
    *) log_err "a probe tree resolves COMPOSE_PROJECT_NAME='${cache_ident_name}' instead of one of its own; on an adopted fork the destructive-path guards see the developer's containers and refuse." ;;
esac
rm -rf "$cache_ident"
# A cache the detector itself marked incomplete (the daemon was down when it
# ran) must be re-probed too, or one bad moment pins the project to the CPU
# profile forever.
if [ -n "$cache_file" ]; then
    printf 'DEVKIT_DETECT_INCOMPLETE := docker\n' >> "$cache_file"; touch "$cache_file"
    ( cd "$cache_moved" && env -u DOCKER_DEV_CACHE_DIR make -pn build ) >/dev/null 2>&1 || true
    ! grep -q '^DEVKIT_DETECT_INCOMPLETE :=' "$cache_file" 2>/dev/null \
        || log_err "a cache carrying DEVKIT_DETECT_INCOMPLETE is reused instead of re-probed; a probe taken while docker was down would pin the GPU profile forever."
fi
rm -rf "$cache_moved"
# ONE cache per tree: `export` hands every sub-make the detector inputs in its
# environment, so each keyed a hashed file of its own — `make setup` probed the
# host twice and its ide-config child could resolve a different GPU profile
# than the parent's `make status` read.
cache_sub="$(make_probe "${ROOT_DIR}"/docker-compose*.yml)"
mkdir -p "$cache_sub/.devcontainer"; printf '{ "service": "ros-cpu", "remoteUser": "user" }\n' > "$cache_sub/.devcontainer/devcontainer.json"
( cd "$cache_sub" && make setup ) >/dev/null 2>&1 || true
cache_sub_files="$(find "$cache_sub/.docker_cache" -name 'detected-env*.mk' 2>/dev/null | wc -l)"
[ "$cache_sub_files" -le 1 ] \
    || log_err "'make setup' leaves ${cache_sub_files} detector caches (a sub-make keyed its own); the two can disagree on the GPU profile."
# …and the file setup writes must name the project setup just created: make
# read the env files before .env existed, and the bare export handed the child
# the stale name, so setup's compose file and a later `make ide-config`
# disagreed on the project namespace.
cache_sub_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' \
    "$cache_sub/.docker_cache/ide.compose.json" 2>/dev/null || true)"
cache_sub_env="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$cache_sub/.env" 2>/dev/null | tail -n 1)"
{ [ -z "$cache_sub_name" ] || [ "$cache_sub_name" = "$cache_sub_env" ]; } \
    || log_err "'make setup' wrote an IDE compose file for project '${cache_sub_name}' while .env says '${cache_sub_env}'; the two namespaces hold different containers and volumes."
rm -rf "$cache_sub"
# The mechanism, read from make's own expansion (the file COUNT depends on which
# inputs a given host exports): an inherited DEVKIT_DETECT_FILE must win, and
# the same path must be exported onward, or every sub-make probes for itself.
cache_inherit="$(cd "$cache_probe" && DEVKIT_DETECT_FILE=.docker_cache/inherited.mk make -pn help 2>/dev/null \
    | sed -n -e 's/^DETECTED_ENV_FILE := //p' -e 's/^DEVKIT_DETECT_FILE := //p' | sort -u | tr '\n' ' ')"
[ "$cache_inherit" = ".docker_cache/inherited.mk " ] \
    || log_err "an inherited DEVKIT_DETECT_FILE does not become this make's cache and its export (got: '${cache_inherit}'); each sub-make keys its own file."
# …and a probe that could not finish must not pin the IDE to its guess.
grep -q 'DEVKIT_DETECT_INCOMPLETE' <<< "$(awk '/^ide-config:$/{i=1} i{print} i && /^$/{exit}' Makefile)" \
    || log_err "ide-config writes the attach service even when host detection was incomplete; setup with docker down pinned VS Code to the wrong profile permanently."

# The .env include is written atomically and its failure is fatal: writing in
# place, a concurrent make read it empty and acted on the wrong compose project;
# an unwritable .docker_cache dropped every .env setting silently.
grep -q 'mv "$$tmp" "$(ENV_MK)"' Makefile \
    || log_err "Makefile writes $(ENV_MK) in place; a concurrent make reads it empty (the failure path is probed below)."
cache_ro="$(make_probe)"; printf 'COMPOSE_PROJECT_NAME=realproj\n' > "$cache_ro/.env"
mkdir -p "$cache_ro/.docker_cache"; chmod 555 "$cache_ro/.docker_cache"
cache_ro_rc=0; cache_ro_out="$( cd "$cache_ro" && make -n help 2>&1 )" || cache_ro_rc=$?
{ [ "$cache_ro_rc" -ne 0 ] && grep -qi 'docker_cache' <<< "$cache_ro_out"; } \
    || log_err "an unwritable .docker_cache does not stop make (rc ${cache_ro_rc}); every .env setting would be ignored in silence."
chmod 755 "$cache_ro/.docker_cache"; rm -rf "$cache_ro"
rm -rf "$cache_probe"
# `make status` is the diagnostic: it must report the wiring even when the
# preflight gate fails, because a broken docker is exactly when it is run. The
# gate still stops build/start.
cache_status="$(make_probe "${ROOT_DIR}"/docker-compose*.yml)"
mkdir -p "$cache_status/bin"
printf '#!/bin/sh\ncase "$1 $2" in "info --format") exit 1 ;; "info ") printf "Client:\\n"; exit 1 ;; esac\ncase "$1" in compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' > "$cache_status/bin/docker"
chmod +x "$cache_status/bin/docker"
cache_status_out="$( cd "$cache_status" && PATH="$cache_status/bin:$probe_min_path" make status 2>&1 || true )"
grep -q 'Detected Host Wiring' <<< "$cache_status_out" \
    || log_err "'make status' prints no wiring when the docker daemon is down; that is the run it exists for."
rm -rf "$cache_status"

# The template revision must come from THIS tree: an extracted copy inside
# another git repository reported the enclosing project's commit as the kit's.
cache_outer="$(cd "$(probe_dir)" && pwd -P)"
( cd "$cache_outer" && git init -q . && git -c user.email=p@d -c user.name=p commit -q --allow-empty -m outer ) >/dev/null 2>&1
mkdir -p "$cache_outer/kit"; cp Makefile "${ROOT_DIR}/.env.example" "${ROOT_DIR}/VERSION" "$cache_outer/kit/"
for cache_link in scripts config docker dependencies; do ln -s "${ROOT_DIR}/${cache_link}" "$cache_outer/kit/${cache_link}"; done
cache_commit="$( cd "$cache_outer/kit" && make -pn help 2>/dev/null | sed -n 's/^DEVKIT_COMMIT := //p' | head -n 1 || true)"
[ -z "$cache_commit" ] \
    || log_err "an extracted template inside another repository reports that repository's commit ('${cache_commit}') as the template revision."
rm -rf "$cache_outer"
# A placeholder that could not be created must never be emitted as a mount
# source: compose mounts it and Docker creates a root-owned directory there.
cache_ro2="$(cd "$(probe_dir config scripts)" && pwd -P)"
# HOST_CACHE_DIR is derived from the workspace, so the workspace's own cache
# directory is what has to be unwritable.
mkdir -p "$cache_ro2/.docker_cache"; chmod 555 "$cache_ro2/.docker_cache"
cache_ro2_rc=0
( PATH="$probe_min_path" HOST_WORKSPACE_PATH="$cache_ro2" XAUTHORITY="$cache_ro2/absent" \
    bash scripts/check_env.sh --makefile ) >/dev/null 2>&1 || cache_ro2_rc=$?
[ "$cache_ro2_rc" -ne 0 ] \
    || log_err "check_env.sh emits a placeholder path it could not create; Docker turns it into a root-owned directory and X auth is silently gone."
chmod 755 "$cache_ro2/.docker_cache"; rm -rf "$cache_ro2"

# The suite itself must leave nothing behind: every probe lives under one
# per-run directory removed by the EXIT trap, on a clean run and on Ctrl-C
# alike. 45 stale probe directories had accumulated in /tmp before this.
# The mechanism itself, extracted and run once: a probe directory created in a
# COMMAND SUBSTITUTION (several groups do that) must still be gone when the
# script exits. No signal is sent here — `kill -INT $$` in a harness reaches
# the whole foreground process group, including this suite, whose own trap then
# removes the tree it is still using.
cache_tmp="$(mktemp -d "${DEVKIT_PROBE_ROOT}/tmpprobe.XXXXXX")"
{ sed -n '/^DEVKIT_PROBE_ROOT=/,/^}/p' scripts/verify_repo.sh
  sed -n '/^trap probe_cleanup EXIT INT TERM$/p' scripts/verify_repo.sh
  sed -n '/^probe_dir() {/,/^}/p' scripts/verify_repo.sh
  printf 'ROOT_DIR=%s\n' "$(printf %q "$ROOT_DIR")"
  echo 'd="$(cd "$(probe_dir config)" && pwd -P)"; : > "$d/marker"'
  echo 'exit 0'
} > "$cache_tmp/mech.sh"
( TMPDIR="$cache_tmp" bash "$cache_tmp/mech.sh" ) >/dev/null 2>&1 || true
cache_left="$(find "$cache_tmp" -mindepth 1 -maxdepth 1 -name 'devkit-run.*' 2>/dev/null | wc -l)"
[ "$cache_left" -eq 0 ] \
    || log_err "a probe directory created in a command substitution survives the run (${cache_left} left); 45 had accumulated in /tmp before the trap."
rm -rf "$cache_tmp"
ok "Host detection cache: a failed probe stops make, a moved checkout and dead session paths are re-probed, .env's include is atomic and fatal, and the suite leaves no temp files."

# =============================================================================
# [advertised-shortcuts] Every shortcut the help screen or MOTD names must
#      resolve in an interactive shell.
# =============================================================================
# The NAME column only, and per source: if one extraction collapses, the
# other must not quietly cover for it.
adv_names() { tr '/' '\n' | sed 's/\[.*//; s/<.*//' | tr -d ' ' | grep -E '^[a-z_][a-z_0-9]*$'; }
adv_help="$(sed -n 's/.*%-20s.*\\n" *"\([^"]*\)".*/\1/p' config/util_aliases.sh | adv_names || true)"
adv_motd="$(sed -n 's/^ *"\([a-z_0-9 /]*\)|.*/\1/p' scripts/show_welcome.sh | adv_names || true)"
[ "$(wc -w <<< "$adv_help")" -ge 20 ] \
    || log_err "Help-text shortcut extraction collapsed ($(wc -w <<< "$adv_help") names, expected ≥20) — did the printf format change?"
[ "$(wc -w <<< "$adv_motd")" -ge 5 ] \
    || log_err "MOTD shortcut extraction collapsed ($(wc -w <<< "$adv_motd") names, expected ≥5)."
advertised="$(printf '%s\n%s\n' "$adv_help" "$adv_motd" | sort -u | sed '/^$/d')"
defined="$(WORKSPACE_PATH="$ROOT_DIR" bash --norc -ic 'source config/util_aliases.sh >/dev/null 2>&1
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
group
grep -q '__DEVKIT_ENV_BRIDGE' docker/entrypoint.sh || log_err "entrypoint.sh must bridge /etc/profile.d into /etc/bash.bashrc (interactive shells)."
# Non-interactive bash reads only $BASH_ENV — and it must NOT point at ~/.bashrc,
# whose stock "return if not interactive" guard discards everything after it.
grep -qE '^[^#]*BASH_ENV=/etc/devkit/shell-env.sh' docker/Dockerfile \
    || log_err "Dockerfile BASH_ENV must point at the guard-free hook (/etc/devkit/shell-env.sh), not ~/.bashrc."
grep -q 'DEVKIT_SHELL_ENV' docker/entrypoint.sh \
    || log_err "entrypoint.sh must generate the BASH_ENV hook for non-interactive shells."
# The image stages the rosdep cache as root; without seeding it, every non-root
# shell fails `mksync` with "rosdep has not been initialized".
grep -qE '^seed_rosdep_cache$' docker/entrypoint.sh \
    || log_err "entrypoint.sh must seed /opt/ros_cache into the container user's HOME."
# init_ros_env.sh is reached only through ~/.bashrc: its DDS settings must be
# persisted too, or scripted runs silently use a different RMW configuration.
grep -q 'devkit-ros.sh' docker/entrypoint.sh \
    || log_err "entrypoint.sh must persist ROS/DDS env (CYCLONEDDS_URI, RMW) for non-interactive shells."
# Structural parity: one file defines the environment for every shell flavour.
# Match the sourcing construct, not the filename: a comment mentioning
# init_bash.sh would satisfy a bare grep for the path.
grep -qE '\. +"\$\{WORKSPACE_PATH:-/workspace\}/config/init_bash\.sh"' docker/entrypoint.sh \
    || log_err "The shared shell hook must source config/init_bash.sh, or non-interactive shells lose ROS/venv/paths."
grep -q 'cat .*config/init_bash.sh >>' docker/Dockerfile \
    && log_err "Dockerfile must not bake a COPY of init_bash.sh into ~/.bashrc; point at the live hook instead."
# Shell-independent path: rc hooks reach bash only, so the entrypoint must also
# offer an exec-wrapper mode for bare binaries, sh and compose/k8s commands.
grep -qF '"--env"' docker/entrypoint.sh \
    || log_err "entrypoint.sh must provide '--env <cmd>' so non-bash processes get the DevKit environment."
# Pattern-exact on purpose: `make exec` probes the running image for --env support
# before using it, and a mis-quoted pattern (it was '"'"'"--env"'"'"' once) never
# matches, silently degrading every `make exec` to a plain bash shell.
grep -qF "grep -q '\"--env\"' /entrypoint.sh" Makefile \
    || log_err "'make exec' must probe /entrypoint.sh for the exact pattern the entrypoint carries ('\"--env\"'), or it always falls back to bash."
# Behavioural: sourcing it without a terminal must be SILENT (no banner
# polluting script stdout) and must still resolve the environment.
noninteractive_out="$(cd "$ROOT_DIR" && WORKSPACE_PATH="$ROOT_DIR" bash -c 'source config/init_bash.sh' 2>/dev/null || true)"
noninteractive_marker="$(cd "$ROOT_DIR" && WORKSPACE_PATH="$ROOT_DIR" bash -c 'source config/init_bash.sh >/dev/null 2>&1; printf %s "${__DEVKIT_ENV_READY:-}"' 2>/dev/null || true)"
[ -n "$noninteractive_out" ] && log_err "config/init_bash.sh writes to stdout in a non-interactive shell (would corrupt scripted output)."
# Interactive but with no terminal — `docker exec … bash -ic '<cmd>'` — must stay
# silent too: the MOTD used to be reprinted over every scripted call's output.
motd_leak="$(bash --norc -ic "WORKSPACE_PATH='${ROOT_DIR}' source config/init_bash.sh; :" </dev/null 2>/dev/null | head -3 || true)"
[ -z "$motd_leak" ] || log_err "the MOTD prints in an interactive shell with no terminal; scripted 'bash -ic' output gets a banner."
[ -z "$noninteractive_marker" ] && log_err "config/init_bash.sh does not resolve the environment in a non-interactive shell."
# Functions live PER PROCESS: a child shell inherits the environment but not the
# definitions. With the readiness marker already exported, `make exec CMD='mksync'`
# reached a shell where the guard short-circuited and nothing was defined.
child_fns="$(__DEVKIT_ENV_READY="$ROOT_DIR" WORKSPACE_PATH="$ROOT_DIR" bash -c \
    'source config/init_bash.sh >/dev/null 2>&1
     for f in mksync cbuild mbuild hwcheck check_deps; do declare -F "$f" >/dev/null || echo "$f"; done' \
    2>/dev/null || true)"
[ -z "$child_fns" ] \
    || log_err "shell functions missing in a child shell ($(tr '\n' ' ' <<< "$child_fns")): 'make exec CMD=mksync' would fail."
# …and the ALIAS-shaped shortcuts too: `make exec CMD='h'` runs `bash -c`, where
# bash expands no aliases unless asked, so every one of them answered "command
# not found" on the path the docs call the default for automation.
child_alias="$(printf 'source "%s/config/init_bash.sh"\n' "$ROOT_DIR" > "$ROOT_DIR/.devkit-bashenv.$$" \
    && WORKSPACE_PATH="$ROOT_DIR" BASH_ENV="$ROOT_DIR/.devkit-bashenv.$$" bash -c 'type -t h; type -t sync_deps' 2>/dev/null | tr '\n' ' ' || true)"
rm -f "$ROOT_DIR/.devkit-bashenv.$$"
case "$child_alias" in
    *alias*|*function*) ;;
    *) log_err "alias shortcuts do not resolve in a non-interactive shell (got: '${child_alias:-nothing}'); 'make exec CMD=h' would fail." ;;
esac
# The entrypoint itself, run as this user in a probe workspace: it must reach
# the command, keep its boot log, and its --env mode must hand the command a
# resolved environment. The root-only parts (profile.d, bashrc bridge, the
# privilege drop) are what runtime-smoke in images-deep.yml exercises.
ep_probe="$(probe_dir config scripts)"
ep_rc=0
ep_out="$(cd "$ep_probe" && env -i PATH="$probe_min_path" HOME="$ep_probe" WORKSPACE_PATH="$ep_probe" GPU_MODE=cpu \
    bash "${ROOT_DIR}/docker/entrypoint.sh" sh -c 'echo "reached:$WORKSPACE_PATH"' 2>&1)" || ep_rc=$?
{ [ "$ep_rc" -eq 0 ] && grep -qF "reached:$ep_probe" <<< "$ep_out"; } \
    || log_err "docker/entrypoint.sh does not reach its command as a non-root user (rc ${ep_rc}): ${ep_out##*$'\n'}"
grep -q '\[Entrypoint\]' "$ep_probe/log/entrypoint.log" 2>/dev/null \
    || log_err "the entrypoint keeps no boot log under log/entrypoint.log; a post-mortem has nothing once docker logs are gone."
[ -s "$ep_probe/.gpu_env.sh" ] \
    || log_err "a boot with GPU_MODE=cpu did not persist ~/.gpu_env.sh; docker exec shells would lose the GPU settings."
ep_env="$(cd "$ep_probe" && env -i PATH="$probe_min_path" HOME="$ep_probe" WORKSPACE_PATH="$ep_probe" \
    bash "${ROOT_DIR}/docker/entrypoint.sh" --env sh -c 'echo "$WS_ROOT"' 2>/dev/null || true)"
# LOG_FILE is the entrypoint's OWN boot log: compose passes the name through for
# every service, so it arrived already exported and every user shell then logged
# into root's file, printing "Permission denied" after each line.
ep_leak="$(cd "$ep_probe" && env -i PATH="$probe_min_path" HOME="$ep_probe" WORKSPACE_PATH="$ep_probe" LOG_FILE=log/entrypoint.log \
    bash "${ROOT_DIR}/docker/entrypoint.sh" sh -c 'echo "[${LOG_FILE-unset}]"' 2>/dev/null | tail -n 1)"
[ "$ep_leak" = '[unset]' ] \
    || log_err "the entrypoint hands LOG_FILE=${ep_leak} to the command; every user shell would append to root's boot log."
# …and the file half of the logger never speaks, whatever the path is worth.
ep_noise="$( LOG_FILE=/proc/devkit-nonexistent/x.log bash -c 'source scripts/util_logging.sh; log_info probe' 2>&1 >/dev/null )"
[ -z "$ep_noise" ] \
    || log_err "an unwritable LOG_FILE makes every log line print '${ep_noise}'."
[ "$ep_env" = "$ep_probe" ] \
    || log_err "'/entrypoint.sh --env <cmd>' hands the command no resolved environment (WS_ROOT='${ep_env}')."
# The first-run clone changes hands ENTIRELY. src/thirdparty is tracked, so the
# bind mount hands it over already user-owned and the ownership shortcut in
# sync_owner_if_root then skipped everything cloned beneath it.
if docker_live; then
    ep_own="$(probe_dir)"; mkdir -p "$ep_own/ws/src/thirdparty" "$ep_own/ws/dependencies" "$ep_own/ws/bin"
    for ep_copy in config scripts docker; do cp -R "${ROOT_DIR}/${ep_copy}" "$ep_own/ws/${ep_copy}"; done
    : > "$ep_own/ws/src/thirdparty/.gitkeep"
    printf 'repositories:\n  a: {type: git, url: https://example.invalid/a.git, version: %s}\n' \
        "0123456789abcdef0123456789abcdef01234567" > "$ep_own/ws/dependencies/dependencies.repos"
    # vcs is called as `vcs import <dir>`: the clone lands under $2.
    printf '#!/bin/sh\nmkdir -p "$2/cloned/.git"\n' > "$ep_own/ws/bin/vcs"; chmod +x "$ep_own/ws/bin/vcs"
    # …and the tree goes back to THIS user before the probe ends: the container
    # writes as root and hands files to uid 1000, so on a host whose uid is
    # anything else (the CI runner is 1001) the cleanup could not unlink them
    # and every run left a root-owned probe directory behind.
    ep_owner="$(docker run --rm -v "$ep_own/ws:/workspace" -w /workspace -e CONTAINER_USER=user -e WORKSPACE_PATH=/workspace \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e PATH=/workspace/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin --entrypoint bash ubuntu:22.04 \
        -c 'useradd -m -u 1000 user 2>/dev/null; bash docker/entrypoint.sh sh -c "echo OWNER=\$(stat -c %U /workspace/src/thirdparty/cloned)"
            chown -R "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true' 2>/dev/null \
        | sed -n 's/^OWNER=//p' | tail -n 1 || true)"
    [ "$ep_owner" = user ] \
        || log_err "after the first-run sync the cloned tree is owned by '${ep_owner:-nothing}' (expected user); neither the container user nor the host could write it."
    rm -rf "$ep_own"
fi
# The GPU settings reach a `docker exec` shell through /etc/profile.d, not
# through the caller's HOME: the probe above runs as this user, so it can only
# see its own file. Assert the real delivery path in a container.
if docker_live; then
    ep_gpu="$(docker run --rm -v "${ROOT_DIR}:/w:ro" --entrypoint bash ubuntu:22.04 -c '
        cp -R /w/config /w/scripts /w/docker /tmp/kit 2>/dev/null || { mkdir -p /tmp/kit; cp -R /w/config /w/scripts /w/docker /tmp/kit/; }
        cd /tmp/kit 2>/dev/null || cd /tmp
        useradd -m -u 1000 user 2>/dev/null
        WORKSPACE_PATH=/tmp/kit GPU_MODE=cpu CONTAINER_USER=user bash docker/entrypoint.sh \
            sh -c "test -f /etc/profile.d/devkit-gpu.sh && sh -lc \"echo DELIVERED=\\\$LIBGL_ALWAYS_SOFTWARE\""' 2>/dev/null \
        | sed -n 's/^DELIVERED=//p' | tail -n 1 || true)"
    [ "$ep_gpu" = 1 ] \
        || log_err "a login shell in the container does not receive the GPU settings through /etc/profile.d (got: '${ep_gpu:-nothing}'); 'docker exec' sessions would render in software without knowing."
fi
rm -rf "$ep_probe"
ok "Runtime env reaches login, interactive and non-interactive shells; the entrypoint boots, logs, hands the sync over and wraps a command as a user."

# =============================================================================
# [ros-distro-set] The supported ROS distros are spelled in two files that
#      cannot share code: check_env.sh maps distro → Ubuntu release, and
#      util_apt_helper.sh is bind-mounted ALONE into a build layer. They must
#      still agree, or a distro one accepts builds on a base the other rejects.
# =============================================================================
group
# Set equality is a textual property, so compare the two lists by parsing —
# behaviour is proved by the two probes below. Running the host detector once
# per distro would cost 0.7 s of docker/nvidia probing to learn nothing extra.
apt_distros="$(sed -n 's/^ *humble|iron|\(.*\)) ;;$/humble iron \1/p' scripts/util_apt_helper.sh \
               | tr '|' ' ' | tr -s ' ')"
env_distros="$(sed -n 's/^ *\([a-z|]*\)) *distro_base=.*/\1/p' scripts/check_env.sh | tr '|' ' ' | tr -s ' ')"
{ [ "$(wc -w <<< "$apt_distros")" -ge 6 ] && [ "$(wc -w <<< "$env_distros")" -ge 6 ]; } \
    || log_err "the ROS distro lists could not be parsed (apt='${apt_distros}' base='${env_distros}')."
# Every distro one side accepts, the other must too — no pre-20.04 names that
# only ever failed later at apt (melodic/kinetic were carried for years).
for ros_distro in $apt_distros; do
    grep -qw -- "$ros_distro" <<< "$env_distros" \
        || log_err "check_env.sh has no base image for '${ros_distro}', which util_apt_helper.sh accepts."
done

# Two inputs that used to pass and break much later: a relative WORKSPACE_PATH
# (compose renders working_dir: ws and only the container start complains) and
# an unknown distro with a pinned BASE_IMAGE, where the interpreter silently
# defaulted to 3.10 and the venv imported neither rclpy nor rospy.
distro_reject() {   # distro_reject <label> <env…>
    local label="$1"; shift
    local rc=0
    ( env "$@" DEVKIT_ENV_FILE=/dev/null DEVKIT_ENV_DEFAULTS=/dev/null \
        bash scripts/check_env.sh --makefile ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
        || log_err "check_env.sh accepts ${label}; the failure surfaces only when the container starts."
}
distro_reject "a relative WORKSPACE_PATH" WORKSPACE_PATH=relative/ws
# The pin warning compares RELEASES: 'ubuntu:jammy' IS 22.04 and warned falsely,
# while a same-number tag of another image passed on the digits alone.
for distro_pin in "ubuntu:22.04 0" "ubuntu:jammy 0" "ubuntu:22.04@sha256:aa 0" "ubuntu:jammy-20260101 0" "ubuntu:24.04 1" "ubuntu:20.04 1"; do
    set -- $distro_pin
    distro_warns="$( env ROS_DISTRO=humble BASE_IMAGE="$1" DEVKIT_ENV_FILE=/dev/null DEVKIT_ENV_DEFAULTS=/dev/null \
        bash scripts/check_env.sh --makefile 2>&1 >/dev/null | grep -c 'expects ubuntu' || true )"
    [ "$distro_warns" = "$2" ] \
        || log_err "BASE_IMAGE=$1 with humble warns ${distro_warns} time(s), expected $2."
done
distro_reject "an unknown distro with a pinned BASE_IMAGE and no UV_PYTHON" ROS_DISTRO=galactic BASE_IMAGE=ubuntu:22.04
( env ROS_DISTRO=galactic BASE_IMAGE=ubuntu:22.04 UV_PYTHON=3.10 DEVKIT_ENV_FILE=/dev/null DEVKIT_ENV_DEFAULTS=/dev/null \
    bash scripts/check_env.sh --makefile ) >/dev/null 2>&1 \
    || log_err "an unknown distro with BOTH BASE_IMAGE and UV_PYTHON given is refused; that is the documented escape hatch."

# The pairing must be DERIVED end to end: changing ROS_DISTRO alone has to move
# the Ubuntu release with it. Probed through the REAL .env.example, so a
# BASE_IMAGE pinned in the committed layer — which would silently override the
# derivation for every local override — fails here rather than at apt.
distro_probe="$(probe_dir)"
printf 'ROS_DISTRO=foxy\n' > "$distro_probe/.env"
# Upstream reads the shipped .env.example, where no BASE_IMAGE may be pinned; a
# fork pins one deliberately (DEPLOY.md), so there the derivation is probed on
# its own defaults file.
distro_defaults="${ROOT_DIR}/.env.example"
upstream_checks || { printf 'ROS_DISTRO=humble\n' > "$distro_probe/defaults"; distro_defaults="$distro_probe/defaults"; }
distro_base="$( unset ROS_DISTRO BASE_IMAGE
    DEVKIT_ENV_FILE="$distro_probe/.env" DEVKIT_ENV_DEFAULTS="$distro_defaults" \
    bash scripts/check_env.sh --makefile 2>/dev/null | sed -n 's/^BASE_IMAGE := //p' || true )"
rm -rf "$distro_probe"
[ "$distro_base" = "ubuntu:20.04" ] \
    || log_err "ROS_DISTRO alone does not decide the base image (foxy gave '${distro_base}', expected ubuntu:20.04) — is BASE_IMAGE pinned in .env.example?"

# …and the interpreter must move WITH it. apt puts rclpy/rospy in the system
# Python, so a venv on any other version imports neither — a failure that shows
# up only when the first ROS import runs, long after a green build.
for distro_pair in "noetic 3.8" "humble 3.10" "jazzy 3.12"; do
    set -- $distro_pair
    distro_probe="$(probe_dir)"
    printf 'ROS_DISTRO=%s\n' "$1" > "$distro_probe/.env"
    distro_py="$( unset ROS_DISTRO BASE_IMAGE UV_PYTHON
        DEVKIT_ENV_FILE="$distro_probe/.env" DEVKIT_ENV_DEFAULTS="${ROOT_DIR}/.env.example" \
        bash scripts/check_env.sh --makefile 2>/dev/null | sed -n 's/^UV_PYTHON := //p' || true )"
    rm -rf "$distro_probe"
    [ "$distro_py" = "$2" ] \
        || log_err "ROS_DISTRO=$1 resolves UV_PYTHON to '${distro_py}', not $2; the venv could not import the apt-installed rclpy/rospy."
done
# …and a distro in neither list must be REFUSED, not handed a default base: a
# catch-all here builds foxy on 22.04 and only fails much later, at apt.
rc=0; distro_probe="$(probe_dir)"
printf 'ROS_DISTRO=devkit-bogus-distro\n' > "$distro_probe/.env"
( unset ROS_DISTRO BASE_IMAGE; DEVKIT_ENV_FILE="$distro_probe/.env" \
    bash scripts/check_env.sh --makefile >/dev/null 2>&1 ) || rc=$?
rm -rf "$distro_probe"
[ "$rc" -ne 0 ] \
    || log_err "check_env.sh accepts an unknown ROS_DISTRO and picks a base image for it; the image would build on the wrong Ubuntu."
grep -rqE 'melodic|kinetic' Makefile scripts config docker --exclude=verify_repo.sh \
    && log_err "a pre-20.04 ROS 1 name (melodic/kinetic) is back in the code; only noetic is ROS 1 here."
# Both places a reader looks: the badge and the support-matrix row.
! upstream_checks || { grep -qiE 'badge/ROS-.*noetic.*legacy' README.md && grep -qiE '^\|.*noetic.*레거시' README.md; } \
    || log_err "README does not mark ROS 1 noetic as the legacy tier in both the badge and the support matrix."
ok "Every supported ROS distro has a base image, an unknown one is refused, and ROS 1 is noetic only, marked legacy ($(wc -w <<< "$apt_distros") distros)."

# =============================================================================
# [host-identity] The container account must survive a base image that already
#      uses the requested gid, group name or user name. macOS hosts (501:20)
#      and a CONTAINER_USER matching a base-image account both land here.
# =============================================================================
group
# The REAL Dockerfile block, run against stand-ins for shadow-utils. The bug was
# in the decision logic — getent matches a GID, groupadd ALSO matches a NAME, so
# a free gid with a taken name aborted the build with a raw groupadd error.
# images.yml runs this same block against the real tools in a real build.
identity_probe="$(probe_dir)"
# Join the continuations as docker build does; stripping the backslashes would
# leave a line starting with '||' and the probe would die of a syntax error.
sed -n '/^RUN test "\$USER_UID" -ge 500/,/^    else useradd/p' docker/Dockerfile \
    | sed -e '1s/^RUN //' -e :a -e '/\\$/N; s/\\\n//; ta' > "$identity_probe/block.sh"
grep -q 'useradd' "$identity_probe/block.sh" \
    || log_err "verify_repo.sh can no longer find the user/group block in docker/Dockerfile."

# Flat "id:name" files stand in for /etc/passwd and /etc/group.
cat > "$identity_probe/stub" <<'STUB'
#!/bin/sh
case "${0##*/}" in
    getent) grep -qE "^$2:|:$2\$" "$STUB_DB/$1" 2>/dev/null || exit 2
            grep -E "^$2:|:$2\$" "$STUB_DB/$1" | head -1 | awk -F: '{print $2":x:"$1}' ;;
    groupadd) grep -qE ":$3\$" "$STUB_DB/group" && exit 9   # real groupadd: name taken
              echo "$2:$3" >> "$STUB_DB/group" ;;
    useradd)  echo "$2:$8" >> "$STUB_DB/passwd" ;;
    usermod)  if [ "$1" = "--login" ]; then
                  sed "s/:$6\$/:$2/" "$STUB_DB/passwd" > "$STUB_DB/passwd.tmp" \
                      && mv "$STUB_DB/passwd.tmp" "$STUB_DB/passwd"
              fi ;;
    id) if [ "$1" = "-u" ]; then grep -E ":$2\$" "$STUB_DB/passwd" | cut -d: -f1
        else grep -qE ":$1\$" "$STUB_DB/passwd"; fi ;;
esac
STUB
chmod +x "$identity_probe/stub"
for tool in getent groupadd useradd usermod id; do ln -sf stub "$identity_probe/$tool"; done

# Each case: <label> <preseeded passwd> <preseeded group> <user> <uid> <gid> <expected rc>
run_identity_case() {
    printf '%s\n' "$2" > "$identity_probe/passwd"; printf '%s\n' "$3" > "$identity_probe/group"
    local rc=0
    ( PATH="$identity_probe:$PATH" STUB_DB="$identity_probe" \
      CONTAINER_USER="$4" USER_UID="$5" USER_GID="$6" sh "$identity_probe/block.sh" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$7" ] || log_err "docker/Dockerfile: ${1} exits ${rc}, expected ${7}."
}
# A group NAME taken at another gid is cosmetic — bind-mount ownership is
# numeric — so the build must fall back to another name, not abort.
run_identity_case "a group name taken at another gid" "" "1500:user" user 1001 1001 0
# A CONTAINER_USER taken at another uid cannot be honoured; renumbering a
# base-image account would orphan its files, so it must fail and say why.
run_identity_case "a user name taken at another uid" "1000:ubuntu" "1000:ubuntu" ubuntu 1001 1001 2
run_identity_case "both requested uid and name already taken" $'1000:ubuntu\n1001:user' "1000:ubuntu" user 1000 1000 2
# The everyday paths must still work: a fresh account, and macOS 501:20 where
# gid 20 already exists as dialout.
run_identity_case "a fresh account" "" "" user 1001 1001 0
run_identity_case "a macOS host (501:20)" "" "20:dialout" user 501 20 0
rm -rf "$identity_probe"
ok "The container account survives a taken gid, group name or user name (4 host shapes)."

# =============================================================================
# [ide-service] `make start` and the devcontainer must open the SAME service.
#      They agree only because both resolve through RESOLVE_SVC_MODE and
#      `make ide-config` writes the answer into devcontainer.json.
# =============================================================================
group
# Both entry points must keep resolving through the one macro; a hand-rolled
# copy in either is how the editor and the CLI drift onto different services.
for ide_target in start ide-config; do
    awk -v t="^${ide_target}:" '$0 ~ t {inside=1; next} /^[a-z]/ && inside {exit} inside && /RESOLVE_SVC_MODE/ {found=1} END {exit found ? 0 : 1}' Makefile \
        || log_err "Makefile: '${ide_target}' no longer resolves the service through RESOLVE_SVC_MODE; the editor and the CLI can now open different containers."
done

# The REAL rewrite from the recipe, run against the REAL devcontainer.json: a
# drifted key format or sed expression leaves the editor on a stale service and
# says nothing, because mv still succeeds.
# '|| true': an empty result is the finding here, and a bare substitution under
# 'set -e' would abort the suite instead of reporting it.
ide_sed="$(awk '/sed -E .*"service"/,/> "\$\$DC.tmp"/' Makefile \
    | awk '{ sub(/\\$/, ""); printf "%s", $0 } END { printf "\n" }' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ && *$//' -e 's/\$\$/$/g' || true)"
[ -n "$ide_sed" ] \
    || log_err "Makefile: the ide-config recipe no longer rewrites a \"service\" key; VS Code would keep attaching to the committed default."
ide_probe="$(probe_dir)"
cp .devcontainer/devcontainer.json "$ide_probe/dc.json"
ide_sed="${ide_sed//\$(CONTAINER_USER)/devkit-probe-user}"
( DC="$ide_probe/dc.json" TARGET_SVC="basic-nvidia"; eval "$ide_sed" ) >/dev/null 2>&1 || true
grep -q '"service"[[:space:]]*:[[:space:]]*"basic-nvidia"' "$ide_probe/dc.json.tmp" 2>/dev/null \
    || log_err "make ide-config no longer rewrites \"service\" in .devcontainer/devcontainer.json; VS Code would keep attaching to the committed default."
# …and the account too. compose creates CONTAINER_USER from .env, but
# remoteUser reads the EDITOR's environment — rename the user and VS Code
# attaches as someone the container does not have.
grep -q '"remoteUser"[[:space:]]*:[[:space:]]*"devkit-probe-user"' "$ide_probe/dc.json.tmp" 2>/dev/null \
    || log_err "make ide-config does not rewrite \"remoteUser\"; a CONTAINER_USER set in .env never reaches the editor."
rm -rf "$ide_probe"

# Every service the resolver can name must exist, and the committed default
# must be one of them — devcontainer.json is read before make ever runs.
ide_modes="$(grep -oE 'SVC_MODE=[a-z]+' Makefile | cut -d= -f2 | sort -u | tr '\n' ' ')"
[ "$(wc -w <<< "$ide_modes")" -ge 3 ] \
    || log_err "the GPU profiles could not be parsed out of RESOLVE_SVC_MODE (got '${ide_modes}')."
for ide_prefix in basic ros; do
    for ide_mode in $ide_modes; do
        grep -qE "^  ${ide_prefix}-${ide_mode}:" docker-compose.dev.yml \
            || log_err "RESOLVE_SVC_MODE can select '${ide_prefix}-${ide_mode}', which docker-compose.dev.yml does not define."
    done
done
# A host without compose (a SLURM submit node) has nothing to attach to:
# ide-config skips there, so `make setup` still finishes its other work.
ide_skip="$(make_probe)"; mkdir -p "$ide_skip/bin"
printf '#!/bin/sh\nexit 1\n' > "$ide_skip/bin/docker"; chmod +x "$ide_skip/bin/docker"
ide_skip_rc=0
ide_skip_out="$(cd "$ide_skip" && PATH="$ide_skip/bin:$probe_min_path" make ide-config 2>&1)" || ide_skip_rc=$?
{ [ "$ide_skip_rc" -eq 0 ] && grep -qi 'skipped' <<< "$ide_skip_out"; } \
    || log_err "make ide-config fails (rc ${ide_skip_rc}) where docker compose is unavailable, so 'make setup' dies on a submit node after doing its useful work."
rm -rf "$ide_skip"
ide_committed="$(sed -n 's/.*"service"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .devcontainer/devcontainer.json)"
grep -qE "^  ${ide_committed}:" docker-compose.dev.yml 2>/dev/null \
    || log_err ".devcontainer/devcontainer.json points at '${ide_committed}', which is not a service in docker-compose.dev.yml."
ok "The editor and 'make start' resolve one service; ide-config rewrites it and every profile exists ($(wc -w <<< "$ide_modes") profiles)."

# =============================================================================
# [run-record] A batch job nobody watched must still be answerable later: which
#      image, on what the scheduler granted, against which data, and how it
#      ended. An unterminated record cannot tell "still running" from "died".
# =============================================================================
group
record_probe="$(probe_dir)"
mkdir -p "$record_probe/data"; echo "dataset-v7" > "$record_probe/data/VERSION"
: > "$record_probe/fake.sif"
(
    source config/util_paths.sh && devkit_require util_logging.sh && devkit_require util_sif_common.sh
    export SLURM_RUN_ROOT="$record_probe/runs" SLURM_DATA_ROOT="$record_probe/data"
    export SLURM_JOB_ID=4242 SLURM_JOB_PARTITION=gpu SLURM_JOB_NODELIST='node[01-02]' \
           SLURM_NTASKS=4 SLURM_CPUS_PER_TASK=8 SLURM_GPUS=4
    sif_record_run "$record_probe/fake.sif" && sif_record_exit 3
) >/dev/null 2>&1 || true
record_file="$(find "$record_probe/runs" -name 'devkit-4242-*.txt' -print -quit 2>/dev/null || true)"
if [ -z "$record_file" ]; then
    log_err "sif_record_run wrote no record under SLURM_RUN_ROOT."
else
    # The image identity, what was granted, the data, and how it ended — the four
    # questions a finished job cannot answer from its stdout alone.
    for record_key in image= job= started= partition= nodelist= ntasks= cpus_per_task= \
                      gpus= data_root= data_version=dataset-v7 finished= exit_status=3; do
        grep -q "^${record_key}" "$record_file" \
            || log_err "the run record omits '${record_key%%=*}'; a finished job cannot be traced back to it."
    done
    # The image PATH is not an identity, and the hash must say where it came
    # from: a sidecar copied blind describes the artifact that USED to be there.
    grep -qE '^sha256_(verified|at_bake)=[0-9a-f]{64}$' "$record_file" \
        || log_err "the run record carries no labelled image hash; the path alone does not identify the artifact."
    # With no sidecar the run had to hash what was actually on disk.
    grep -q '^sha256_verified=' "$record_file" \
        || log_err "the run record reports a bake-time hash for an artifact that has no sidecar."
fi

# A sidecar is trusted only while the artifact still matches the size recorded
# at bake; a replaced SIF must be hashed rather than described by the old value.
record_stale="$(probe_dir)"
printf 'original' > "$record_stale/a.sif"
printf 'deadbeef  a.sif\n' > "$record_stale/a.sif.sha256"
printf 'artifact_bytes=%s\n' "$(wc -c < "$record_stale/a.sif" | tr -d ' ')" > "$record_stale/a.sif.provenance"
record_hash_line() {
    ( source config/util_paths.sh && devkit_require util_logging.sh && devkit_require util_sif_common.sh
      SLURM_RUN_ROOT="$record_stale/runs" sif_record_run "$record_stale/a.sif" ) >/dev/null 2>&1 || true
    sed -n 's/^\(sha256_[a-z_]*\)=.*/\1/p' "$record_stale/runs"/*.txt 2>/dev/null | head -1
    rm -rf "$record_stale/runs"
}
[ "$(record_hash_line)" = "sha256_at_bake" ] \
    || log_err "an untouched artifact does not reuse its bake-time hash; every launch would re-read the whole SIF."
printf 'REPLACED-and-longer' > "$record_stale/a.sif"
[ "$(record_hash_line)" = "sha256_verified" ] \
    || log_err "a REPLACED artifact still reports the bake-time hash; the record would name a SIF that is no longer there."
rm -rf "$record_stale"
if [ -n "$record_file" ]; then
    [ "$(stat -c '%a' "$record_file" 2>/dev/null || stat -f '%Lp' "$record_file")" = "600" ] \
        || log_err "the run record is not written 0600; run roots are shared on HPC."
fi
# Every path that OPENS a record must close it: a record with no exit status
# cannot be told apart from a job that is still running.
# Run the LOCAL SIF path for real, against a stub runtime: it opened a record
# above and used to exec the job away, so the record never gained an ending.
record_local="$(probe_dir config scripts)"
mkdir -p "$record_local/bin"
: > "$record_local/a.sif"
printf '#!/bin/sh\ncase "$*" in *"test -x /entrypoint.sh"*) exit 0 ;; *grep*) exit 1 ;; *WORKSPACE_PATH*) printf /workspace; exit 0 ;; esac\nexit 5\n' \
    > "$record_local/bin/apptainer"
chmod +x "$record_local/bin/apptainer"
record_local_rc=0
( PATH="$record_local/bin:$probe_min_path" WORKSPACE_PATH="$record_local" \
  SLURM_RUN_ROOT="$record_local/runs" SIF_FILE="$record_local/a.sif" \
  bash scripts/apptainer_run.sh --mode prod --env dev 'true' ) >/dev/null 2>&1 || record_local_rc=$?
record_local_file="$(find "$record_local/runs" -name 'devkit-local-*.txt' -print -quit 2>/dev/null || true)"
if [ -z "$record_local_file" ]; then
    log_err "a local SIF run writes no record under SLURM_RUN_ROOT."
else
    grep -q '^exit_status=5' "$record_local_file" \
        || log_err "a local SIF run leaves its record open (no exit status); it cannot be told apart from a job still running."
fi
[ "$record_local_rc" = "5" ] \
    || log_err "apptainer_run.sh returns ${record_local_rc}, not the job's 5; a wrapper that swallows the status breaks every caller's error handling."
rm -rf "$record_local"

# …and it must close on the JOB's status, not on the signal that interrupted
# `wait`. A single wait returned 143 and this shell exited while the job ran on.
record_sig="$(probe_dir)"
# Long enough to still be running when the signal lands, no longer.
printf 'trap "" TERM\nsleep 0.5\nexit 9\n' > "$record_sig/child.sh"
{
    printf 'source config/util_paths.sh && devkit_require util_logging.sh && devkit_require util_sif_common.sh\n'
    printf 'DEVKIT_RUN_RECORD=%s/rec; : > "$DEVKIT_RUN_RECORD"\n' "$record_sig"
    printf 'sif_run_and_record bash %s/child.sh || true\n' "$record_sig"
} > "$record_sig/parent.sh"
( bash "$record_sig/parent.sh" ) >/dev/null 2>&1 &
record_sig_pid=$!
sleep 0.15; kill -TERM "$record_sig_pid" 2>/dev/null || true
wait "$record_sig_pid" 2>/dev/null || true
record_sig_rc="$(sed -n 's/^exit_status=//p' "$record_sig/rec" 2>/dev/null || true)"
rm -rf "$record_sig"
[ "$record_sig_rc" = "9" ] \
    || log_err "a signalled run records exit_status='${record_sig_rc:-<none>}' instead of the job's 9; the record closes while the job is still running."
rm -rf "$record_probe"
ok "Run records carry image hash, granted resources, data version and exit status (0600)."

# =============================================================================
# [gpu-dispatch] Which run gets --nv. A GPU cannot be probed here, but the
#      DECISION can: inside an allocation the submitting node's hardware says
#      nothing about the compute node's, so only an explicit request counts.
# =============================================================================
group
gpu_probe="$(probe_dir)"
mkdir -p "$gpu_probe/with" "$gpu_probe/without"
printf '#!/bin/sh\nexit 0\n' > "$gpu_probe/with/nvidia-smi"; chmod +x "$gpu_probe/with/nvidia-smi"
# gpu_flags_for <bin-dir> <env assignments> — the flags sif_gpu_flags builds.
gpu_flags_for() {
    ( export PATH="$1:$probe_min_path"; shift; eval "export $*" 2>/dev/null
      source config/util_paths.sh && devkit_require util_logging.sh && devkit_require util_sif_common.sh
      sif_gpu_flags; printf '%s' "${GPU_FLAGS[*]-}" ) 2>/dev/null || true
}
# <label>|<bin-dir>|<env>|<expected>
while IFS='|' read -r gpu_label gpu_bin gpu_env gpu_want; do
    [ -n "$gpu_label" ] || continue
    gpu_got="$(gpu_flags_for "$gpu_probe/$gpu_bin" "$gpu_env")"
    [ "$gpu_got" = "$gpu_want" ] \
        || log_err "sif_gpu_flags: ${gpu_label} builds '${gpu_got}', expected '${gpu_want}'."
done <<'CASES'
GPU_MODE=cpu never asks for a GPU|with|GPU_MODE=cpu|
an explicit GPU_MODE=nvidia asks|without|GPU_MODE=nvidia|--nv
CUDA_VISIBLE_DEVICES is an explicit request|without|GPU_MODE=auto CUDA_VISIBLE_DEVICES=0|--nv
a GPU on THIS host counts outside an allocation|with|GPU_MODE=auto|--nv
no GPU on this host, no request|without|GPU_MODE=auto|
inside an allocation the local GPU means nothing|with|GPU_MODE=auto SLURM_JOB_ID=4242|
CASES
# …and WHICH devices reach the container. SLURM assigns them per task, so a
# value forwarded before srun hands every task the job-wide list and two tasks
# then fight over device 0.
gpu_task="$(probe_dir config scripts)"
mkdir -p "$gpu_task/bin"
: > "$gpu_task/a.sif"
# This task was given device 1; the job as a whole holds 0,1.
printf '#!/bin/sh\nshift\nCUDA_VISIBLE_DEVICES=1 exec "$@"\n' > "$gpu_task/bin/srun"
printf '#!/bin/sh\ncase "$*" in *"test -x /entrypoint.sh"*) exit 0 ;; *grep*) exit 1 ;; esac\nprintf "%%s" "${APPTAINERENV_CUDA_VISIBLE_DEVICES-<unset>}" > "%s/seen"\nexit 0\n' \
    "$gpu_task" > "$gpu_task/bin/apptainer"
chmod +x "$gpu_task/bin/srun" "$gpu_task/bin/apptainer"
( PATH="$gpu_task/bin:$probe_min_path" WORKSPACE_PATH="$gpu_task" \
  SLURM_JOB_ID=99 CUDA_VISIBLE_DEVICES=0,1 \
  bash scripts/slurm_run.sh "$gpu_task/a.sif" 'true' ) >/dev/null 2>&1 || true
gpu_seen="$(cat "$gpu_task/seen" 2>/dev/null || echo '<nothing>')"
[ "$gpu_seen" = "1" ] \
    || log_err "a srun task whose devices are '1' gives its container '${gpu_seen}'; every task would target the job-wide list."
# An EMPTY task list means this task was granted nothing, and must CLEAR the
# job-wide value — leaving it hands a CPU task GPUs another task is using.
printf '#!/bin/sh\nshift\nCUDA_VISIBLE_DEVICES= exec "$@"\n' > "$gpu_task/bin/srun"
rm -f "$gpu_task/seen"
( PATH="$gpu_task/bin:$probe_min_path" WORKSPACE_PATH="$gpu_task" \
  SLURM_JOB_ID=99 CUDA_VISIBLE_DEVICES=0,1 \
  bash scripts/slurm_run.sh "$gpu_task/a.sif" 'true' ) >/dev/null 2>&1 || true
gpu_empty="$(cat "$gpu_task/seen" 2>/dev/null || echo '<nothing>')"
# EMPTY, not absent: under --cleanenv an unset list lets CUDA enumerate every
# device the container can see, which is the opposite of "granted none".
[ "$gpu_empty" = "" ] \
    || log_err "a srun task granted NO devices gives its container '${gpu_empty}' (want an empty list); it would reach GPUs another task holds."
# Thread counts must follow the ALLOCATION. OpenMP and MKL size themselves from
# the cores visible on the NODE, so an 8-cpu grant on a 128-core node became 128
# threads over 8 cores — a silent collapse that also hurts the neighbours.
gpu_threads() {   # gpu_threads <env assignments>
    ( eval "export $1" 2>/dev/null
      source config/util_paths.sh && devkit_require util_logging.sh && devkit_require util_sif_common.sh
      sif_forward_env
      printf '%s' "${APPTAINERENV_OMP_NUM_THREADS-<unset>}" ) 2>/dev/null || true
}
[ "$(gpu_threads 'SLURM_CPUS_PER_TASK=8')" = "8" ] \
    || log_err "an 8-cpu allocation does not set OMP_NUM_THREADS; the container would size its thread pools from the whole node."
[ "$(gpu_threads 'SLURM_CPUS_PER_TASK=8 OMP_NUM_THREADS=2')" = "2" ] \
    || log_err "an explicit OMP_NUM_THREADS is overwritten by the allocation size; the knob would be unusable."
rm -rf "$gpu_probe" "$gpu_task"
ok "--nv follows an explicit request, never a login node; each srun task forwards only its own devices and its own core count."

# =============================================================================
# [slurm-submit] What reaches sbatch. No cluster here, but a stub sbatch shows
#      the argv exactly: the knobs must arrive, and a MISSING sbatch must stop
#      the job rather than run it — a "fallback to local execution" on a login
#      node is what gets an HPC account suspended.
# =============================================================================
group
submit_probe="$(probe_dir config scripts)"
mkdir -p "$submit_probe/bin"
: > "$submit_probe/artifact.sif"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$submit_probe" > "$submit_probe/bin/sbatch"
chmod +x "$submit_probe/bin/sbatch"

submit_run() {   # submit_run <extra PATH dir or empty>
    ( export PATH="${1:+$1:}$probe_min_path" WORKSPACE_PATH="$submit_probe" \
             SIF_FILE="$submit_probe/artifact.sif" \
             DEVKIT_SLURM_PARTITION=gpu DEVKIT_SLURM_GRES=gpu:2 \
             DEVKIT_SLURM_ARRAY=1-4 DEVKIT_SLURM_ACCOUNT=lab \
             DEVKIT_SLURM_NODES=2 DEVKIT_SLURM_NTASKS=8
      bash scripts/apptainer_run.sh --mode slurm --env dev 'python3 -c "pass"' ) 2>&1 || true
}

submit_out="$(submit_run "$submit_probe/bin")"
if [ ! -f "$submit_probe/argv" ]; then
    log_err "SIF_MODE=slurm never reached sbatch (output: ${submit_out})."
else
    # --chdir pins the cwd so the relative #SBATCH log paths land in the
    # workspace; --export=ALL survives sites that default to NONE and would
    # otherwise strip the forwarded ROS/DDS environment.
    for submit_flag in "--chdir=" "--export=ALL" "--partition=gpu" "--gres=gpu:2" \
                       "--array=1-4" "--account=lab" "--nodes=2" "--ntasks=8" "artifact.sif"; do
        grep -qF -- "$submit_flag" "$submit_probe/argv" \
            || log_err "sbatch never receives '${submit_flag}'; the knob is advertised but does not reach the scheduler."
    done
    # The command must arrive as ONE argument, or quoting is lost to word-splitting.
    grep -qxF 'python3 -c "pass"' "$submit_probe/argv" \
        || log_err "the job command reaches sbatch split across arguments; inner quoting is lost."
fi
# RUN_ARGS (what `make run-sif RUN_ARGS=…` exports) must beat the .env pair.
# The precedence was split across two files once, and a ROS_LAUNCH_COMMAND kept
# in .env silently replaced every RUN_ARGS a user typed.
rm -f "$submit_probe/argv"
( export PATH="$submit_probe/bin:$probe_min_path" WORKSPACE_PATH="$submit_probe" \
         SIF_FILE="$submit_probe/artifact.sif" \
         RUN_ARGS='from-run-args' ROS_LAUNCH_COMMAND='from-dotenv' APP_COMMAND='from-dotenv-too'
  bash scripts/apptainer_run.sh --mode slurm --env dev ) >/dev/null 2>&1 || true
grep -qxF 'from-run-args' "$submit_probe/argv" 2>/dev/null \
    || log_err "RUN_ARGS loses to the .env launch command (sbatch got: $(grep -E 'from-' "$submit_probe/argv" 2>/dev/null | tr '\n' ' '))."

# GPU_MODE reaches the runtime as the flag it names: amd asks for --rocm (which
# SLURM.md advertises), and the modes with no apptainer flag ask for nothing —
# igpu/intel used to fall through to --nv and request hardware nobody asked for.
for submit_gpu in "nvidia --nv" "amd --rocm" "igpu -" "intel -" "cpu -"; do
    set -- $submit_gpu
    submit_gpu_out="$( GPU_MODE="$1" bash -c 'source scripts/util_sif_common.sh >/dev/null 2>&1; sif_gpu_flags; printf %s "${GPU_FLAGS[*]:--}"' 2>/dev/null || true )"
    [ "$submit_gpu_out" = "$2" ] \
        || log_err "GPU_MODE=$1 gives apptainer '${submit_gpu_out}', expected '$2'."
done
# …and every knob a script consumes is documented, this one included.
{ [ ! -f docs/SLURM.md ] || grep -qF 'DEVKIT_VERIFY_SIF_HASH' docs/SLURM.md; } \
    || log_err "DEVKIT_VERIFY_SIF_HASH has a consumer in util_sif_common.sh but no documentation."

# The "not found" message must name the artifact the mode WRITES: -share is a
# dev-bake variant (mkenv --share) and prod never produces one, yet the probe
# fell through to it and told the user to look for a file that cannot exist.
submit_name="$(probe_dir)"
submit_name_out="$( WORKSPACE_PATH="$submit_name" COMPOSE_PROJECT_NAME=probe \
    bash scripts/apptainer_run.sh --mode prod --env dev 'true' 2>&1 || true )"
grep -qE 'probe-dev-prod-[a-z0-9]+\.sif' <<< "$submit_name_out" && ! grep -q 'share' <<< "$submit_name_out" \
    || log_err "a missing prod artifact is reported as a name prod never writes: ${submit_name_out%%$'\n'*}"
rm -rf "$submit_name"

# The dangerous one: no sbatch must NOT mean "run it here".
rm -f "$submit_probe/argv"
submit_norc=0
# apptainer present and RECORDING, sbatch absent: without the runtime any
# failure satisfied a bare "exits non-zero", so a local fallback would have
# passed. The proof is that the runtime was never invoked.
mkdir -p "$submit_probe/norun"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/ran"\n' "$submit_probe/norun" > "$submit_probe/norun/apptainer"
chmod +x "$submit_probe/norun/apptainer"
rm -f "$submit_probe/norun/ran"
( export PATH="$submit_probe/norun:$probe_min_path" WORKSPACE_PATH="$submit_probe" \
         SIF_FILE="$submit_probe/artifact.sif"
  bash scripts/apptainer_run.sh --mode slurm --env dev 'python3 -c "pass"' ) >/dev/null 2>&1 || submit_norc=$?
[ "$submit_norc" -ne 0 ] \
    || log_err "SIF_MODE=slurm without sbatch exits 0; a job you believed was queued ran on the login node."
[ ! -f "$submit_probe/norun/ran" ] \
    || log_err "SIF_MODE=slurm without sbatch ran the container locally (apptainer argv: $(tr '\n' ' ' < "$submit_probe/norun/ran"))."
grep -qE '^[^#]*Falling back to local execution' scripts/apptainer_run.sh \
    && log_err "apptainer_run.sh still falls back to local execution when sbatch is missing."

# `--` must hand the command through as ARGV: a command whose name starts with
# a dash can never run through `bash -c` (bash reads it as its own flag), and
# the %q-joined form landed as [-c] [echo\ hi].
submit_dash="$(probe_dir)"; mkdir -p "$submit_dash/bin"; : > "$submit_dash/art.sif"
printf '#!/bin/sh\nprintf "[%%s]" "$@" > "%s/argv"\n' "$submit_dash" > "$submit_dash/bin/apptainer"
chmod +x "$submit_dash/bin/apptainer"
( PATH="$submit_dash/bin:$probe_min_path" WORKSPACE_PATH="$submit_dash" SIF_FILE="$submit_dash/art.sif" \
  bash scripts/apptainer_run.sh --mode prod --env dev -- -c 'echo hi' ) >/dev/null 2>&1 || true
submit_dash_argv="$(cat "$submit_dash/argv" 2>/dev/null || echo '<apptainer never ran>')"
case "$submit_dash_argv" in
    *'[-c][echo hi]') ;;
    *) log_err "'-- -c <cmd>' does not reach the runtime as argv (got: ${submit_dash_argv##*.sif})." ;;
esac
# …and a prod artifact with no command says what is missing instead of starting
# a shell it does not have (--cleanenv strips APP_COMMAND; its entrypoint then
# exits 2 and the run record said "interactive").
rm -f "$submit_dash/argv"
submit_bare_rc=0
submit_bare_out="$( PATH="$submit_dash/bin:$probe_min_path" WORKSPACE_PATH="$submit_dash" SIF_FILE="$submit_dash/art.sif" \
    bash scripts/apptainer_run.sh --mode prod --env dev 2>&1 )" || submit_bare_rc=$?
{ [ "$submit_bare_rc" -eq 2 ] && grep -q 'No command to run' <<< "$submit_bare_out" && [ ! -f "$submit_dash/argv" ]; } \
    || log_err "'run-sif SIF_MODE=prod' with no command exits ${submit_bare_rc} and starts the artifact anyway."
rm -rf "$submit_dash"

# Inside an allocation the job must go through srun, or a --nodes=2 --ntasks=8
# allocation silently runs ONE process on ONE node and the other 7 shares idle.
# (srun spawns the processes; MPI transport is the application's business —
# DevKit wires no --mpi/PMI, which is why the README calls MPI unsupported.)
printf '#!/bin/sh\necho srun > "%s/launcher"\nshift\nexec "$@"\n' "$submit_probe" > "$submit_probe/bin/srun"
printf '#!/bin/sh\ncase "$*" in *"test -x /entrypoint.sh"*) exit 0 ;; *grep*) exit 1 ;; esac\nexit 0\n' \
    > "$submit_probe/bin/apptainer"
chmod +x "$submit_probe/bin/srun" "$submit_probe/bin/apptainer"
submit_launcher_for() {   # submit_launcher_for [job-id]
    rm -f "$submit_probe/launcher"
    ( export PATH="$submit_probe/bin:$probe_min_path" WORKSPACE_PATH="$submit_probe"
      [ -z "${1:-}" ] || export SLURM_JOB_ID="$1"
      bash scripts/slurm_run.sh "$submit_probe/artifact.sif" 'true' ) >/dev/null 2>&1 || true
    cat "$submit_probe/launcher" 2>/dev/null || echo none
}
[ "$(submit_launcher_for 4242)" = srun ] \
    || log_err "inside a SLURM allocation slurm_run.sh does not launch through srun; a --nodes=2 --ntasks=8 job would run one process on one node."
[ "$(submit_launcher_for)" = none ] \
    || log_err "outside an allocation slurm_run.sh still calls srun, which fails on a plain login shell."

# The boundary the README draws must stay drawn: no --mpi/PMI is wired anywhere.
# The property, not a phrasing: the README must say MPI is unsupported. srun
# spreads the tasks across nodes — that part is verified — but nothing wires a
# transport between them.
! upstream_checks || grep -qiE 'MPI.*(미지원|unsupported)' README.md \
    || log_err "README does not state that MPI is unsupported; srun spawns the tasks but no transport is wired between them."
rm -rf "$submit_probe"
ok "Every SLURM knob reaches sbatch as one argv, and a missing sbatch stops the job instead of running it locally."

# =============================================================================
# [slurm-defaults] The job defaults are spelled twice and cannot share code:
#      SLURM parses #SBATCH before any shell can expand a variable, so a bare
#      `sbatch` sees only the header, while `make run-sif` sends DEVKIT_SLURM_*
#      as flags that override it. They must still agree, or the same job asks
#      for different resources depending on how it was launched.
# =============================================================================
group
# <sbatch flag>:<DEVKIT_SLURM_ suffix>
for slurmdef_pair in job-name:JOB_NAME nodes:NODES ntasks:NTASKS \
                     cpus-per-task:CPUS_PER_TASK mem:MEM time:TIME \
                     output:OUTPUT error:ERROR signal:SIGNAL; do
    slurmdef_flag="${slurmdef_pair%%:*}"; slurmdef_knob="${slurmdef_pair##*:}"
    slurmdef_hdr="$(sed -n "s/^#SBATCH --${slurmdef_flag}=//p" scripts/slurm_run.sh | head -1)"
    slurmdef_env="$(sed -n "s/^# DEVKIT_SLURM_${slurmdef_knob}=//p" .env.example | head -1)"
    [ -n "$slurmdef_hdr" ] \
        || { log_err "scripts/slurm_run.sh has no '#SBATCH --${slurmdef_flag}'; a bare sbatch would fall back to the site default."; continue; }
    [ -n "$slurmdef_env" ] \
        || { log_err ".env.example does not advertise DEVKIT_SLURM_${slurmdef_knob}; the header default cannot be overridden without editing a tracked script."; continue; }
    [ "$slurmdef_hdr" = "$slurmdef_env" ] \
        || log_err "SLURM default '${slurmdef_flag}' drifted: #SBATCH says '${slurmdef_hdr}', .env.example says '${slurmdef_env}'."
    # …and each knob must actually become that flag, or .env is decoration.
    grep -qE "^[^#]*--${slurmdef_flag}=\\\$\\{DEVKIT_SLURM_${slurmdef_knob}\\}" scripts/apptainer_run.sh \
        || log_err "DEVKIT_SLURM_${slurmdef_knob} never becomes --${slurmdef_flag}; setting it in .env would do nothing."
done
# The batch shell only gets ADVANCE warning with the B: prefix; without it the
# trap in slurm_run.sh has KillWait (30 s by default) before SIGKILL.
case "$(sed -n 's/^#SBATCH --signal=//p' scripts/slurm_run.sh | head -1)" in
    B:*) ;;
    *)   log_err "#SBATCH --signal has no 'B:' prefix; the signal goes to the job steps and the batch shell's trap never runs early." ;;
esac
# SLURM opens --output BEFORE the batch script runs and does not create the
# directory, so the SUBMITTER has to. A mkdir inside slurm_run.sh is too late.
slurmdef_out="$(sed -n 's/^#SBATCH --output=//p' scripts/slurm_run.sh | head -1)"
awk -v dir="${slurmdef_out%%/*}" '
    /MODE" = "slurm"/         { inside = 1 }
    inside && /^fi$/          { inside = 0 }
    inside && /mkdir -p/ && index($0, dir) { found = 1 }
    inside && /exec sbatch/ && !found { exit 1 }
    END { exit found ? 0 : 1 }' scripts/apptainer_run.sh \
    || log_err "the slurm branch submits without creating '${slurmdef_out%%/*}/'; SLURM cannot open ${slurmdef_out} and the job fails before the script runs."
# The compute node reads the helpers from the SUBMIT-side path, so a workspace
# it cannot see must say exactly that — the failure used to be a bare
# "No such file or directory" naming neither the cause nor the fix.
slurmdef_far_rc=0
slurmdef_far="$( DEVKIT_REPO_ROOT=/devkit-nonexistent-node-local \
    bash scripts/slurm_run.sh /dev/null 'true' 2>&1 )" || slurmdef_far_rc=$?
grep -qi 'compute node' <<< "$slurmdef_far" \
    || log_err "a workspace the compute node cannot read fails without naming the cause; the raw message points at neither the filesystem nor DEVKIT_REPO_ROOT."
grep -q 'DEVKIT_REPO_ROOT' <<< "$slurmdef_far" \
    || log_err "the unreadable-workspace error does not mention DEVKIT_REPO_ROOT, which is the way out when the compute nodes see another path."
[ "$slurmdef_far_rc" -ne 0 ] \
    || log_err "a job whose workspace is unreachable exits 0; SLURM would record it as successful."
# …and the prerequisite must be written down, not only discovered at 3am.
[ ! -f docs/SLURM.md ] || grep -qE '(컴퓨트 노드|compute node).*(마운트|mount)' docs/SLURM.md \
    || log_err "docs/SLURM.md does not state that the workspace must sit on a filesystem the compute nodes mount."
ok "SLURM job defaults agree between #SBATCH and .env.example, every knob becomes its flag, and the submitter creates the log directory."

# =============================================================================
# [host-prereqs] The host tools a workflow reaches for must be BOTH checked
#      before the build and written down. A tool missing from preflight fails
#      minutes later inside docker; one missing from the docs is a support
#      question. The two lists are held to each other here.
# =============================================================================
group
# The table preflight iterates is the source; the guide must name every entry.
hostdep_table="$(awk "/^HOST_REQUIRED='/,/'\$/" scripts/check_preflight.sh \
    | sed -e "s/^HOST_REQUIRED='//" -e "s/'\$//" | grep -v '^$' || true)"
hostdep_tools="$(cut -d'|' -f1 <<< "$hostdep_table")"
[ "$(wc -l <<< "$hostdep_tools")" -ge 4 ] \
    || log_err "check_preflight.sh no longer carries a HOST_REQUIRED table; the host prerequisites are unchecked."
for hostdep in $hostdep_tools; do
    [ -f docs/DEPENDENCIES.md ] || continue   # a fork may keep only its own docs
    grep -qF "**${hostdep}**" docs/DEPENDENCIES.md \
        || log_err "preflight requires '${hostdep}' but docs/DEPENDENCIES.md does not list it; a fresh host hits it as a surprise."
done
# The reverse, so the table cannot quietly shrink or demote an entry: the guide
# is the independent anchor. Rows whose outcome column says the build is
# blocked must be blocking in preflight too.
hostdep_documented="$(awk -F'|' '/preflight 차단/ {
        n = split($2, cell, /\*\*/)
        for (i = 2; i <= n; i += 2) if (cell[i] ~ /^[a-z0-9-]+$/) print cell[i]
    }' docs/DEPENDENCIES.md 2>/dev/null || true)"
{ [ -n "$hostdep_documented" ] || [ ! -f docs/DEPENDENCIES.md ]; } \
    || log_err "docs/DEPENDENCIES.md lists no blocking host prerequisite; the table or its wording changed and the check went blind."
for hostdep in $hostdep_documented; do
    grep -qE "^${hostdep}\|yes\|" <<< "$hostdep_table" \
        || log_err "docs/DEPENDENCIES.md calls '${hostdep}' blocking, but check_preflight.sh does not enforce it as such."
done
# …and each blocking entry must actually block. A symlink farm holding only
# what the script itself needs, minus the tool under test: a table nobody
# iterates checks nothing.
hostdep_probe="$(probe_dir)"
probe_farm "$hostdep_probe/bin" $hostdep_tools docker >/dev/null
while IFS='|' read -r hostdep_tool hostdep_block _; do
    [ "$hostdep_block" = yes ] || continue
    [ -e "$hostdep_probe/bin/$hostdep_tool" ] || continue   # absent here anyway
    mv "$hostdep_probe/bin/$hostdep_tool" "$hostdep_probe/${hostdep_tool}.hidden"
    # One run, both answers: this script probes docker three ways and costs
    # ~290 ms, so paying for it twice per tool was the suite's largest waste.
    hostdep_rc=0
    hostdep_out="$( PATH="$hostdep_probe/bin" bash scripts/check_preflight.sh 2>&1 )" || hostdep_rc=$?
    mv "$hostdep_probe/${hostdep_tool}.hidden" "$hostdep_probe/bin/$hostdep_tool"
    grep -qF "$hostdep_tool" <<< "$hostdep_out" \
        || log_err "check_preflight.sh says nothing when '${hostdep_tool}' is missing; the build fails minutes later instead."
    [ "$hostdep_rc" -ne 0 ] \
        || log_err "check_preflight.sh exits 0 without '${hostdep_tool}', which it calls blocking."
done <<< "$hostdep_table"
# The one prerequisite that is not a tool: a read-only checkout produced ~20
# contract failures that each blamed the code instead of the mount.
hostdep_ro="$(cd "$(probe_dir config scripts)" && pwd -P)"
chmod 555 "$hostdep_ro"
hostdep_ro_out="$( cd "$hostdep_ro" && PATH="$probe_min_path" bash "${ROOT_DIR}/scripts/check_preflight.sh" 2>&1 || true )"
chmod 755 "$hostdep_ro"
grep -q 'not writable' <<< "$hostdep_ro_out" \
    || log_err "check_preflight.sh accepts a read-only workspace, where every detection cache and placeholder write fails."
rm -rf "$hostdep_ro"
# The GitHub Actions switch. Its truth lives on GitHub, so `make ci` reads it
# through gh and ci-on/ci-off write it — every workflow file, both directions,
# a refusal with the install hint when gh is missing, and the same one-line
# state in `make status`. Against a stub gh that records its argv; "no gh" is
# the farm above with gh taken out.
ci_probe="$(probe_dir .github scripts config docker dependencies)"
cp Makefile "${ROOT_DIR}/.env.example" "$ci_probe/"; mkdir -p "$ci_probe/bin"
# A gh that answers the way GitHub does: workflows are addressed by id or name,
# and enable/disable returns 403 when the state already holds. The old stub
# always succeeded, which is why nobody noticed that one 403 aborted the loop
# and left the rest of the workflows untouched.
cat > "$ci_probe/bin/gh" <<'CIGH'
#!/bin/sh
STATE="$(dirname "$0")/../state"
[ -f "$STATE" ] || printf 'verify\tactive\t1\nimages\tdisabled_manually\t2\nproject\tactive\t3\n' > "$STATE"
case "$1 $2" in
  "workflow list") cat "$STATE" ;;
  "workflow enable"|"workflow disable")
      echo "$2 $3" >> "$(dirname "$0")/../gh.log"
      want=$([ "$2" = enable ] && echo active || echo disabled_manually)
      row=$(awk -F'\t' -v k="${3%.yml}" '$1==k || $3==k {print; exit}' "$STATE")
      [ -n "$row" ] || { echo "could not find any workflow named \"$3\"" >&2; exit 1; }
      case "$(printf '%s' "$row" | cut -f2)" in
        "$want"*) echo "HTTP 403: Unable to $2 a workflow that is not $want." >&2; exit 1 ;;
      esac
      awk -F'\t' -v k="${3%.yml}" -v w="$want" 'BEGIN{OFS="\t"} {if($1==k || $3==k)$2=w; print}' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
      ;;
esac
exit 0
CIGH
chmod +x "$ci_probe/bin/gh"
ci_run() {   # ci_run <target> → "<rc> <switch calls made>"
    local rc=0
    : > "$ci_probe/gh.log"
    ( cd "$ci_probe" && PATH="$ci_probe/bin:$probe_min_path" make "$1" ) >/dev/null 2>&1 || rc=$?
    printf '%s %s' "$rc" "$(sort "$ci_probe/gh.log" 2>/dev/null | tr '\n' ' ')"
}
# From a MIXED state only the workflows that differ are switched — one already
# disabled must not be asked again, and must not abort the ones behind it.
ci_seen="$(ci_run ci-off)"
[ "$ci_seen" = "0 disable 1 disable 3 " ] \
    || log_err "'make ci-off' from a mixed state should disable only the two active workflows and exit 0 (got: '${ci_seen}')."
# …and running it again is a no-op that still succeeds: this is the failure a
# fork reported — 'HTTP 403: Unable to disable a workflow that is not active'.
ci_seen="$(ci_run ci-off)"
[ "$ci_seen" = "0 " ] \
    || log_err "'make ci-off' on an already-off repository must make no call and exit 0 (got: '${ci_seen}')."
ci_seen="$(ci_run ci-on)"
[ "$ci_seen" = "0 enable 1 enable 2 enable 3 " ] \
    || log_err "'make ci-on' must enable every disabled workflow and exit 0 (got: '${ci_seen}')."
ci_seen="$(ci_run ci-on)"
[ "$ci_seen" = "0 " ] \
    || log_err "'make ci-on' on an already-on repository must make no call and exit 0 (got: '${ci_seen}')."
printf 'verify\tactive\t1\nimages\tdisabled_manually\t2\nproject\tactive\t3\n' > "$ci_probe/state"
ci_state="$(cd "$ci_probe" && PATH="$ci_probe/bin:$probe_min_path" make ci 2>/dev/null || true)"
grep -q 'mixed (2/3 active)' <<< "$ci_state" && grep -q 'images.*disabled_manually' <<< "$ci_state" \
    || log_err "'make ci' does not report the summary and the per-workflow table gh returned (got: ${ci_state%%$'\n'*})."
rm -f "$hostdep_probe/bin/gh"
ci_nogh_rc=0
ci_nogh_out="$(cd "$ci_probe" && PATH="$hostdep_probe/bin" make ci-off 2>&1)" || ci_nogh_rc=$?
{ [ "$ci_nogh_rc" -ne 0 ] && grep -q 'cli.github.com' <<< "$ci_nogh_out"; } \
    || log_err "'make ci-off' without gh exits ${ci_nogh_rc} without pointing at the GitHub CLI install."
grep -q 'cli.github.com' <<< "$(cd "$ci_probe" && PATH="$hostdep_probe/bin" make ci 2>&1 || true)" \
    || log_err "'make ci' without gh does not say the state is unknown for want of the GitHub CLI."
awk '/^status:/{inside=1; next} inside && /^[^\t]/{inside=0} inside && /CI_STATE/{found=1} END{exit found ? 0 : 1}' Makefile \
    || log_err "'make status' no longer shows the GitHub Actions state (CI_STATE)."
rm -rf "$ci_probe"
rm -rf "$hostdep_probe"
# The NVIDIA runtime notice, ONE place: an explicit GPU_MODE=nvidia without the
# runtime must block, a detected GPU under auto must only warn (auto falls back
# to iGPU/CPU). A stub docker with no nvidia runtime answers every probe.
hostdep_gpu="$(probe_dir)"
# The stub answers what the code asks: `docker info --format …` (the runtime
# NAMES) and, like the real client, prints its Client block even when the
# daemon is gone. A stub that ignored --format returned nothing, and an
# emptiness test then read "daemon down" where a live daemon had answered.
printf '#!/bin/sh\ncase "$1" in info) echo "io.containerd.runc.v2 runc " ;; compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"; chmod +x "$hostdep_gpu/docker"
hostdep_gpu_run() {   # hostdep_gpu_run <env…> → "<rc> <output>"
    local rc=0 out
    out="$( PATH="$hostdep_gpu:$probe_min_path" env "$@" bash scripts/check_preflight.sh 2>&1 )" || rc=$?
    printf '%s %s' "$rc" "$out"
}
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=nvidia HAS_NVIDIA=true)"
{ [ "${hostdep_gpu_out%% *}" -ne 0 ] && grep -q 'nvidia-ctk' <<< "$hostdep_gpu_out"; } \
    || log_err "check_preflight.sh lets GPU_MODE=nvidia through without an NVIDIA runtime (rc ${hostdep_gpu_out%% *}); docker fails later with 'could not select device driver'."
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=auto HAS_NVIDIA=true)"
{ [ "${hostdep_gpu_out%% *}" -eq 0 ] && grep -q 'nvidia-ctk' <<< "$hostdep_gpu_out"; } \
    || log_err "check_preflight.sh does not warn (rc ${hostdep_gpu_out%% *}) when the detector saw a GPU but docker has no NVIDIA runtime; the CPU fallback would be silent."
# The positive path: a runtime list that DOES carry nvidia must be accepted.
printf '#!/bin/sh\ncase "$1" in info) echo "io.containerd.runc.v2 nvidia runc " ;; compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=nvidia HAS_NVIDIA=true)"
{ [ "${hostdep_gpu_out%% *}" -eq 0 ] && ! grep -q 'nvidia-ctk' <<< "$hostdep_gpu_out"; } \
    || log_err "check_preflight.sh rejects GPU_MODE=nvidia on a host whose docker DOES list the nvidia runtime (rc ${hostdep_gpu_out%% *})."
printf '#!/bin/sh\ncase "$1" in info) echo "io.containerd.runc.v2 runc " ;; compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=auto HAS_NVIDIA=false)"
{ [ "${hostdep_gpu_out%% *}" -eq 0 ] && ! grep -q 'nvidia-ctk' <<< "$hostdep_gpu_out"; } \
    || log_err "check_preflight.sh mentions the NVIDIA runtime on a host with no NVIDIA GPU."
# A host merely NAMED nvidia has no runtime: the check reads the Runtimes list,
# not the word anywhere in `docker info`.
printf '#!/bin/sh\ncase "$1" in info) echo "io.containerd.runc.v2 runc " ;; compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=nvidia HAS_NVIDIA=true)"
[ "${hostdep_gpu_out%% *}" -ne 0 ] \
    || log_err "check_preflight.sh accepts GPU_MODE=nvidia because the word 'nvidia' appears in docker info (the host's name); 'docker compose up' would fail with unknown runtime."
# …and an unreachable daemon is reported as such, not as a missing toolkit.
# Daemon down, exactly as the real client behaves: rc 1 with the Client block
# still on stdout, which is why an emptiness test on `docker info` was no
# liveness proxy at all.
# Measured against the real client: with the daemon down a BARE `docker info`
# still prints its 354-byte Client block (rc 1), while the templated form
# prints nothing at all. Both shapes here, so the code cannot pass by reading
# the wrong one.
printf '#!/bin/sh\ncase "$1 $2" in "info --format") exit 1 ;; "info ") printf "Client:\\n Version: 29.0\\n"; exit 1 ;; esac\ncase "$1" in compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"
hostdep_gpu_out="$(hostdep_gpu_run GPU_MODE=nvidia HAS_NVIDIA=true)"
{ grep -q 'daemon is not reachable' <<< "$hostdep_gpu_out" && ! grep -q 'nvidia-ctk' <<< "$hostdep_gpu_out"; } \
    || log_err "with the docker daemon down, preflight blames the NVIDIA runtime instead of the daemon."
# …and the same notice on a host with NO `timeout` (macOS ships neither it nor
# gtimeout): wrapped in a bare `timeout`, the runtime probe failed with
# "command not found" and every Mac read that as "nothing to complain about".
# A farm holding what the script needs, minus the wall clock.
printf '#!/bin/sh\ncase "$1" in info) echo "io.containerd.runc.v2 runc " ;; compose) echo 2.30.0 ;; buildx) echo v0.20.0 ;; esac\nexit 0\n' \
    > "$hostdep_gpu/docker"
probe_farm "$hostdep_gpu/nt" $hostdep_tools >/dev/null
ln -sf "$hostdep_gpu/docker" "$hostdep_gpu/nt/docker"
rm -f "$hostdep_gpu/nt/timeout" "$hostdep_gpu/nt/gtimeout"
hostdep_nt_rc=0
hostdep_nt_out="$( PATH="$hostdep_gpu/nt" env GPU_MODE=nvidia HAS_NVIDIA=true bash scripts/check_preflight.sh 2>&1 )" || hostdep_nt_rc=$?
{ [ "$hostdep_nt_rc" -ne 0 ] && grep -q 'nvidia-ctk' <<< "$hostdep_nt_out"; } \
    || log_err "on a host with no 'timeout' the NVIDIA runtime check goes silent (rc ${hostdep_nt_rc}); GPU_MODE=nvidia then fails inside docker."
# The class, not just this call site: a bare `timeout` in either script the
# Makefile's read phase runs is the same defect on the next host without it.
hostdep_bare="$(grep -nE '^[^#]*[^_[:alnum:]]timeout +[0-9]' scripts/check_env.sh scripts/check_preflight.sh || true)"
[ -z "$hostdep_bare" ] \
    || log_err "a host-side script calls 'timeout' directly instead of devkit_timeout: $(cut -d: -f1,2 <<< "$hostdep_bare" | tr '\n' ' ')"
rm -rf "$hostdep_gpu"
# The detector reads the same two facts the same way. A driverless nvidia-smi is
# not a GPU, and a daemon that cannot answer must not be cached as "no runtime":
# every later run would silently pick the iGPU/CPU profile.
hostdep_det="$(probe_dir config scripts)"
printf '#!/bin/sh\n[ "$1" = "-L" ] && { echo "NVIDIA-SMI has failed" >&2; exit 9; }\nexit 0\n' > "$hostdep_det/nvidia-smi"
printf '#!/bin/sh\n[ "$1" = info ] && exit 1\nexit 0\n' > "$hostdep_det/docker"
# uname says Linux: the GPU and runtime probes live in check_env.sh's non-macOS
# branch, so on a Mac runner these assertions measured an empty branch and
# reported the code broken. Every other query goes to the real uname.
printf '#!/bin/sh\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec %s "$@"\n' "$(command -v uname)" > "$hostdep_det/uname"
chmod +x "$hostdep_det/nvidia-smi" "$hostdep_det/docker" "$hostdep_det/uname"
# Both call shapes: apptainer_bake.sh runs it with NO arguments and eval's the
# result, so an unbound $1 there breaks every direct bake.
( PATH="$hostdep_det:$probe_min_path" HOST_CACHE_DIR="$hostdep_det/cache" bash scripts/check_env.sh ) >/dev/null 2>&1 \
    || log_err "check_env.sh fails when called with no arguments; a direct 'scripts/apptainer_bake.sh' cannot resolve the host at all."
hostdep_det_out="$( PATH="$hostdep_det:$probe_min_path" HOST_CACHE_DIR="$hostdep_det/cache" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
grep -qx 'HAS_NVIDIA := false' <<< "$hostdep_det_out" \
    || log_err "an nvidia-smi that cannot talk to the driver still sets HAS_NVIDIA := true; 'auto' would pick the nvidia profile and the container would not start."
printf '#!/bin/sh\n[ "$1" = "-L" ] && { echo "GPU 0: NVIDIA"; exit 0; }\nexit 0\n' > "$hostdep_det/nvidia-smi"
# A GPU present and the daemon down: `make check`/`status`/`setup` are exactly
# what a user runs then, so detection must ANSWER — and mark the answer
# incomplete, because caching "no NVIDIA runtime" would pin the project to the
# iGPU/CPU profile in silence. The Makefile treats such a cache as stale.
hostdep_det_rc=0
hostdep_det_out="$( PATH="$hostdep_det:$probe_min_path" HOST_CACHE_DIR="$hostdep_det/cache" bash scripts/check_env.sh --makefile 2>/dev/null )" || hostdep_det_rc=$?
{ [ "$hostdep_det_rc" -eq 0 ] && grep -q '^DEVKIT_DETECT_INCOMPLETE := ' <<< "$hostdep_det_out"; } \
    || log_err "with a GPU present and the docker daemon unreachable, detection exits ${hostdep_det_rc} or emits no DEVKIT_DETECT_INCOMPLETE marker; either the diagnostics die or a wrong GPU profile gets cached."
printf '#!/bin/sh\n[ "$1" = info ] && { echo "Name: nvidia-box"; exit 0; }\nexit 0\n' > "$hostdep_det/docker"
hostdep_det_out="$( PATH="$hostdep_det:$probe_min_path" HOST_CACHE_DIR="$hostdep_det/cache" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
grep -qx 'HAS_TOOLKIT := false' <<< "$hostdep_det_out" \
    || log_err "the detector reads 'nvidia' anywhere in docker info as the container runtime; a host merely named nvidia-box resolved to the nvidia profile."
rm -rf "$hostdep_det"
# vcstool lives in the IMAGE; claiming it as a host prerequisite sends people
# installing it in the wrong place.
grep -q 'python3-vcstool' dependencies/apt_ros.txt \
    || log_err "python3-vcstool is no longer installed in the image, but docs/DEPENDENCIES.md says sync_deps runs there."
grep -qE '^[^#]*vcstool' scripts/check_preflight.sh \
    && log_err "check_preflight.sh requires vcstool on the host; it runs inside the container."
# These three change what the container shares with the host, and they ship ON.
# The comment above each must NAME it — a neighbour's paragraph is not an
# explanation, which is how they sat undocumented next to PRIVILEGED's four
# lines.
for hostdep_knob in NETWORK_MODE IPC_MODE ULIMIT_NOFILE; do
    awk -v k="^${hostdep_knob}=" -v n="${hostdep_knob}" '
        /^#/ { block = block $0 "\n"; next }
        $0 ~ k { exit index(block, n) ? 0 : 1 }
        { block = "" }' .env.example \
        || log_err "${hostdep_knob} ships enabled but the comment above it in .env.example never names it."
done
ok "Every blocking host prerequisite is both enforced by preflight and documented ($(wc -w <<< "$hostdep_tools") tools)."

# =============================================================================
# [macos-fallback] macOS has no CUDA and no DRI passthrough — Docker Desktop
#      runs a Linux VM. Every macOS host must resolve to cpu even when the
#      machine has a GPU and nvidia-smi happens to be on PATH, or compose picks
#      a profile whose devices do not exist and the container fails to start.
# =============================================================================
group
macos_probe="$(probe_dir)"
# A host that looks like macOS AND advertises an NVIDIA GPU: detection must
# believe the platform, not the tool that happens to be installed.
printf '#!/bin/sh\n[ "$1" = -s ] && { echo Darwin; exit 0; }\nexec /usr/bin/uname "$@"\n' \
    > "$macos_probe/uname"; chmod +x "$macos_probe/uname"
printf '#!/bin/sh\nexit 0\n' > "$macos_probe/nvidia-smi"; chmod +x "$macos_probe/nvidia-smi"
macos_env="$( PATH="$macos_probe:$PATH" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
for macos_expect in 'IS_MACOS := true' 'HAS_NVIDIA := false' 'HAS_TOOLKIT := false' 'HAS_DRI := false'; do
    grep -qF -- "$macos_expect" <<< "$macos_env" \
        || log_err "on a macOS host check_env.sh does not emit '${macos_expect}'; compose would select a profile whose devices do not exist."
done
rm -rf "$macos_probe"
# …and those three flags must actually land on the cpu profile. The REAL
# resolver from the Makefile, so a change to the branch order is caught here
# rather than by a Mac user whose container will not start.
macos_resolver="$(sed -n '/^define RESOLVE_SVC_MODE/,/^endef/p' Makefile \
    | sed -e '1d' -e '$d' \
          -e 's/\$(HAS_NVIDIA)/false/g; s/\$(HAS_TOOLKIT)/false/g; s/\$(HAS_DRI)/false/g' \
          -e 's/\$(SERVICE_PREFIX)/ros/g' -e 's/\$\$/$/g' -e 's/ \\$//' || true)"
macos_svc="$( unset GPU_MODE; eval "$macos_resolver" >/dev/null 2>&1; printf '%s' "${TARGET_SVC:-}" )"
[ "$macos_svc" = "ros-cpu" ] \
    || log_err "a macOS host resolves to '${macos_svc:-<nothing>}', not ros-cpu; the selected profile requests devices macOS cannot pass through."
# …and the support matrix must say so, rather than letting a reader assume
# Metal/MPS works because the GPU section does not mention macOS.
! upstream_checks || grep -qiE 'macOS GPU.*(미지원|unsupported)' README.md \
    || log_err "README does not state that macOS GPU acceleration is unsupported (CPU fallback only)."
ok "A macOS host resolves to cpu even with nvidia-smi on PATH, and the README says Metal/MPS is unsupported."

# =============================================================================
# [bake-inputs] What a bake actually passes to docker build. ROS_DISTRO decides
#      BASE_IMAGE and UV_PYTHON inside check_env.sh, and a host `export` never
#      crosses into a build — both were silently lost on the bake path.
# =============================================================================
group
# Probe cache generation in an isolated tree; never delete the user's cache.
bake_cli="$(probe_dir)"
cp Makefile "${ROOT_DIR}/.env.example" "$bake_cli/"
for bake_link in scripts config docker dependencies; do
    [ -e "${ROOT_DIR}/${bake_link}" ] && ln -s "${ROOT_DIR}/${bake_link}" "$bake_cli/${bake_link}"
done
bake_cache="$bake_cli/.docker_cache/detected-env.mk"
for bake_target in bake-prod bake-dev help; do
    rm -f "$bake_cache"
    (cd "$bake_cli" && env -u ROS_DISTRO -u BASE_IMAGE -u UV_PYTHON \
        -u WORKSPACE_PATH -u DOCKER_DEV_CACHE_DIR \
        make -n "$bake_target") >/dev/null 2>&1 || true
    if [ "$bake_target" = help ]; then
        [ ! -f "$bake_cache" ] || log_err "make help must skip detection."
    else
        [ -f "$bake_cache" ] || log_err "make $bake_target must resolve its build inputs."
    fi
done

# The pin policy must travel as a BUILD ARG. Captured from a stub docker, so a
# host-only export — which is what the first attempt was — fails here.
bake_probe="$(probe_dir)"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 1\n' "$bake_probe" > "$bake_probe/docker"
printf '#!/bin/sh\nexit 0\n' > "$bake_probe/apptainer"
chmod +x "$bake_probe/docker" "$bake_probe/apptainer"
bake_arg_for() {   # bake_arg_for <mode> <key>
    rm -f "$bake_probe/argv"
    ( PATH="$bake_probe:$probe_min_path" bash scripts/apptainer_bake.sh --mode "$1" --env dev ) >/dev/null 2>&1 || true
    sed -n "s/^$2=//p" "$bake_probe/argv" 2>/dev/null | head -1
}
[ "$(bake_arg_for prod DEVKIT_REQUIRE_PINNED)" = "1" ] \
    || log_err "a prod bake does not pass DEVKIT_REQUIRE_PINNED=1 as a build arg; the sync inside the image reads the default and a release can float."
[ "$(bake_arg_for dev DEVKIT_REQUIRE_PINNED)" = "0" ] \
    || log_err "a dev bake forces pinned repos; a branch is a legitimate choice mid-development."
rm -rf "$bake_probe"
# EVERY stage that runs the sync must declare it — DERIVED, not named: the first
# attempt declared it on 'ros' alone, which the production builders do not
# inherit, so the release path never saw the policy and the check still passed.
# mksync calls setup_sync_deps.sh too, so both spellings count.
bake_missing="$(awk '
    /^FROM /                       { stage = $NF; next }
    /^ARG DEVKIT_REQUIRE_PINNED/   { declared[stage] = 1; next }
    /setup_sync_deps|mksync/       { if ($0 !~ /^#/) syncs[stage] = 1 }
    END { for (s in syncs) if (!declared[s]) printf "%s ", s }' docker/Dockerfile || true)"
[ -z "$bake_missing" ] \
    || log_err "docker/Dockerfile: stage(s) ${bake_missing}run the dependency sync without declaring ARG DEVKIT_REQUIRE_PINNED; BuildKit drops the build arg and a release can float."

# A .env written before ROS_DISTRO changed keeps the OLD pairing and wins. The
# pin is honoured (DEPLOY.md asks for digests) but must not be silent.
bake_warn="$(probe_dir)"
printf 'ROS_DISTRO=noetic\nBASE_IMAGE=ubuntu:22.04\nUV_PYTHON=3.10\n' > "$bake_warn/.env"
bake_msg="$( unset ROS_DISTRO BASE_IMAGE UV_PYTHON
    DEVKIT_ENV_FILE="$bake_warn/.env" DEVKIT_ENV_DEFAULTS="${ROOT_DIR}/.env.example" \
    bash scripts/check_env.sh --makefile 2>&1 >/dev/null || true )"
rm -rf "$bake_warn"
grep -q 'ubuntu:20.04' <<< "$bake_msg" \
    || log_err "a .env pinning BASE_IMAGE against its ROS_DISTRO produces no warning; the mismatch surfaces only when apt fails."
grep -q 'rclpy' <<< "$bake_msg" \
    || log_err "a .env pinning UV_PYTHON against its ROS_DISTRO produces no warning; the venv silently cannot import ROS."
# A COMMAND-LINE override must reach the detector too. make passes neither
# command-line nor environment variables into $(shell …), so this arrived as
# nothing and the pairing silently stayed on whatever .env said.
# In a probe tree: this repo's own .env may pin BASE_IMAGE deliberately (see
# the warning above), and the question here is whether the OVERRIDE arrives.
for bake_pair in "noetic ubuntu:20.04 3.8" "jazzy ubuntu:24.04 3.12"; do
    set -- $bake_pair
    # env -u: the Makefile exports everything to its recipes, so this script
    # already carries the repo's own BASE_IMAGE/UV_PYTHON and the inner make
    # would read them as environment overrides — exactly what is under test.
    # Upstream only: DEPLOY.md tells a release branch to pin BASE_IMAGE by
    # digest in .env.example, which by design overrides the derivation.
    upstream_checks || continue
    bake_db="$( cd "$bake_cli" && env -u ROS_DISTRO -u BASE_IMAGE -u UV_PYTHON \
        -u WORKSPACE_PATH -u DOCKER_DEV_CACHE_DIR \
        make -np bake-prod ROS_DISTRO="$1" 2>/dev/null || true )"
    bake_base="$(sed -n 's/^BASE_IMAGE := //p' <<< "$bake_db" | tail -1)"
    bake_py="$(sed -n 's/^UV_PYTHON := //p' <<< "$bake_db" | tail -1)"
    { [ "$bake_base" = "$2" ] && [ "$bake_py" = "$3" ]; } \
        || log_err "'make bake-prod ROS_DISTRO=$1' resolves ${bake_base:-<none>}/${bake_py:-<none>}, not $2/$3; the override never reaches check_env.sh."
done
for bake_distro in noetic jazzy; do
    bake_env_db="$(cd "$bake_cli" && env -u BASE_IMAGE -u UV_PYTHON ROS_DISTRO="$bake_distro" \
        make -np bake-prod 2>/dev/null || true)"
    grep -qx "ROS_DISTRO := $bake_distro" <<< "$bake_env_db" \
        || log_err "Environment ROS_DISTRO=$bake_distro was lost or reused a stale cache."
done
rm -rf "$bake_cli"
ok "A bake derives its base image and interpreter from ROS_DISTRO (.env or command line), carries the pin policy into the build, and warns on a stale .env."

# =============================================================================
# [path-settings] The paths a user sets must survive host detection. The
#      detector emitted its own defaults for WORKSPACE_PATH and the cache dir,
#      and the include that follows overwrote the .env answer with them — so the
#      cache compose mounted stopped being the one `clean-cache` deletes.
# =============================================================================
group
pathset_probe="$(make_probe)"
printf 'COMPOSE_PROJECT_NAME=myproject\nWORKSPACE_PATH=/devkit-probe-ws\nDOCKER_DEV_CACHE_DIR=%s/relocated\n' \
    "$pathset_probe" > "$pathset_probe/.env"
# A detector-running target, so the include order is the one under test.
pathset_db="$( cd "$pathset_probe" && env -u WORKSPACE_PATH -u DOCKER_DEV_CACHE_DIR \
    make -np bake-prod 2>/dev/null || true )"
pathset_value() { sed -n "s/^$1 := //p" <<< "$pathset_db" | tail -1; }
[ "$(pathset_value WORKSPACE_PATH)" = "/devkit-probe-ws" ] \
    || log_err "a WORKSPACE_PATH set in .env resolves to '$(pathset_value WORKSPACE_PATH)'; the detector's default overwrote it."
[ "$(pathset_value HOST_CACHE_DIR)" = "${pathset_probe}/relocated" ] \
    || log_err "DOCKER_DEV_CACHE_DIR in .env does not reach HOST_CACHE_DIR (got '$(pathset_value HOST_CACHE_DIR)'); compose would mount one cache and 'make clean-cache' delete another."
# …and a command-line override must win over both, with its own cache key.
pathset_cli="$( cd "$pathset_probe" && env -u WORKSPACE_PATH \
    make -np bake-prod WORKSPACE_PATH=/devkit-cli-ws 2>/dev/null || true )"
[ "$(sed -n 's/^WORKSPACE_PATH :\{0,1\}= //p' <<< "$pathset_cli" | tail -1)" = "/devkit-cli-ws" ] \
    || log_err "'make WORKSPACE_PATH=…' does not reach the detector; the override is lost behind .env."
# A command-line override must also reach the values the DETECTOR derives.
# make's own precedence hides this: WORKSPACE_PATH would look right in the
# database while HOST_CACHE_DIR was still computed from the old workspace.
pathset_derived="$( cd "$pathset_probe" && env -u DOCKER_DEV_CACHE_DIR \
    make -np bake-prod "DOCKER_DEV_CACHE_DIR=$pathset_probe/cli-cache" 2>/dev/null || true )"
[ "$(sed -n 's/^HOST_CACHE_DIR := //p' <<< "$pathset_derived" | tail -1)" = "${pathset_probe}/cli-cache" ] \
    || log_err "'make DOCKER_DEV_CACHE_DIR=…' never reaches the detector, so HOST_CACHE_DIR keeps the old location while compose mounts the new one."
rm -rf "$pathset_probe"
ok "Workspace and cache paths set in .env or on the command line survive host detection."

# =============================================================================
# [confirm-guard] The gate on irreversible targets. Only an EXACT true value may
#      skip the question: `-z` on the two concatenated let FORCE=0 and CI=false
#      through, and a prefix glob then let FORCE=10 and "truegarbage" through.
# =============================================================================
group
# The REAL macro, on a harmless target — never by running a destructive one.
confirm_probe="$(probe_dir)"
{
    sed -n '/^define CONFIRM/,/^endef/p' Makefile
    printf 'YELLOW:=\nNC:=\nINFO:=\nERROR:=\nprobe:\n\t$(call CONFIRM,probe)\n\t@echo PROCEEDED\n'
} > "$confirm_probe/Makefile"
confirm_says() {   # confirm_says <VAR=value>…
    ( cd "$confirm_probe" && env -u FORCE -u CI "$@" make -s probe </dev/null 2>&1 || true )
}
# <label>|<env>|proceed|refuse
while IFS='|' read -r confirm_label confirm_env confirm_want; do
    [ -n "$confirm_label" ] || continue
    confirm_out="$(confirm_says $confirm_env)"
    case "$confirm_want" in
        proceed) grep -q PROCEEDED <<< "$confirm_out" \
            || log_err "CONFIRM: ${confirm_label} should skip the question but did not." ;;
        refuse)  grep -q PROCEEDED <<< "$confirm_out" \
            && log_err "CONFIRM: ${confirm_label} skipped the question; only an exact true value may." ;;
    esac
done <<'CASES'
FORCE=1|FORCE=1|proceed
CI=true|CI=true|proceed
FORCE=yes|FORCE=yes|proceed
FORCE=0|FORCE=0|refuse
CI=false|CI=false|refuse
FORCE=10|FORCE=10|refuse
FORCE=truegarbage|FORCE=truegarbage|refuse
FORCE=nottrue|FORCE=nottrue|refuse
neither set|DEVKIT_UNUSED=1|refuse
CASES
rm -rf "$confirm_probe"
ok "Only an exact true FORCE/CI skips the delete confirmation (9 spellings, off a TTY)."

# =============================================================================
# [delete-boundary] Destructive commands are aimed by configuration, so the
#      guard must run on the RESOLVED path. '<ws>/cache/../../<ws>' carries the
#      word 'cache' and reached `rm -rf` on the workspace; a SYNC_TARGET_DIR
#      spelled '<ws>/src/thirdparty/../../../outside' passed a "starts with the
#      workspace" test and `git clean -ffdx` ran in another tree.
# =============================================================================
group
# Canonical from the start: the guard deletes the RESOLVED path, and on macOS
# $TMPDIR is /var/… -> /private/var/…, so an unresolved probe path would
# never match the mock rm log and every allowed delete would read as refused.
rmguard_probe="$(cd "$(probe_dir)" && pwd -P)"
mkdir -p "$rmguard_probe/ws/cache" "$rmguard_probe/realcache" "$rmguard_probe/bin"
cp Makefile "$rmguard_probe/ws/"
for rmguard_link in scripts config docker dependencies; do
    ln -s "${ROOT_DIR}/${rmguard_link}" "$rmguard_probe/ws/${rmguard_link}"
done
printf '#!/bin/sh\necho "$*" >> "%s/rm.log"\n' "$rmguard_probe" > "$rmguard_probe/bin/rm"
chmod +x "$rmguard_probe/bin/rm"
# rmguard_case <label> <expect deleted|refused> <make args…>
rmguard_case() {
    local label="$1" want="$2"; shift 2
    : > "$rmguard_probe/rm.log"
    local out; out="$( cd "${rmguard_ws:-$rmguard_probe/ws}" && PATH="$rmguard_probe/bin:$PATH" make clean-cache "$@" 2>&1 || true )"
    # The recipe removes other things too, so only a call naming the guarded
    # path counts as "the guard let it through". ${*##…} strips per word and
    # would leave FORCE=1 glued to the front. And "refused" must be the GUARD's
    # verdict, in its own words: an earlier abort (a running container seen
    # through a leaked COMPOSE_PROJECT_NAME) also leaves the log empty.
    local got=aborted target="" arg
    for arg in "$@"; do case "$arg" in DOCKER_DEV_CACHE_DIR=*) target="${arg#*=}" ;; esac; done
    if grep -qF -- "$target" "$rmguard_probe/rm.log" 2>/dev/null; then got=deleted
    elif grep -qE 'refusing to delete|does not look like a cache|must be an absolute path' <<< "$out"; then got=refused
    fi
    [ "$got" = "$want" ] \
        || log_err "clean-cache on ${label}: ${got}, expected ${want}$( [ "$got" = aborted ] && printf ' (recipe stopped before the guard: %s)' "$(head -n 1 <<< "$out")" )."
}
rmguard_case "a path that resolves back to the workspace" refused \
    FORCE=1 "DOCKER_DEV_CACHE_DIR=$rmguard_probe/ws/cache/../../ws"
rmguard_case "FORCE=0 with a non-cache path" refused \
    FORCE=0 "DOCKER_DEV_CACHE_DIR=$rmguard_probe/elsewhere"
rmguard_case "a real cache directory" deleted \
    "DOCKER_DEV_CACHE_DIR=$rmguard_probe/realcache"
rmguard_case "a non-cache path the user forced" deleted \
    FORCE=1 "DOCKER_DEV_CACHE_DIR=$rmguard_probe/elsewhere"
# A parent of the workspace whose name carries 'cache' passed both guards and
# `rm -rf` would have taken the workspace with it. And the resolved paths went
# through `eval` of an unquoted assignment, so a space split a cache path in two.
mkdir -p "$rmguard_probe/cachedir/ws" "$rmguard_probe/real cache"
cp Makefile "$rmguard_probe/cachedir/ws/"
for rmguard_link in scripts config docker dependencies; do
    ln -s "${ROOT_DIR}/${rmguard_link}" "$rmguard_probe/cachedir/ws/${rmguard_link}"
done
rmguard_ws="$rmguard_probe/cachedir/ws" rmguard_case "a parent directory of the workspace" refused \
    FORCE=1 "DOCKER_DEV_CACHE_DIR=$rmguard_probe/cachedir"
rmguard_ws="$rmguard_probe/cachedir/ws" rmguard_case "the root directory" refused FORCE=1 "DOCKER_DEV_CACHE_DIR=/"
rmguard_case "a cache path containing a space" deleted "DOCKER_DEV_CACHE_DIR=$rmguard_probe/real cache"
# `clean` removes the live container's mount points: build/ and install/ are
# bind-mounted, so deleting them from the host split the workspace in two — the
# container wrote into an unreachable path and the next start remounted the old
# volume, so a build that reported success ran the pre-clean binary.
grep -q 'RUNNING=' <<< "$(awk '/^clean:$/{i=1} i{print} i && /^clean-cache:/{exit}' Makefile)" \
    || log_err "'make clean' has no running-container guard, though it removes the mount points of a live container (clean-cache guards exactly this)."
# `start` keeps ONE container per ENV: a sibling GPU variant left running made
# exec/shell/test/lint attach to whichever docker listed first, so an explicit
# GPU_MODE=cpu request ran on the GPU.
grep -q 'one container per ENV' <<< "$(awk '/^start: check$/{i=1} i{print} i && /^$/{exit}' Makefile)" \
    || log_err "'make start' does not remove the other GPU variants of this ENV; two containers of one ENV make exec pick arbitrarily."
# clean-all is not ENV-scoped for volumes; its confirmation must say so.
grep -q "EVERY ENV of" Makefile \
    || log_err "clean-all's confirmation does not say it removes every ENV's volumes and images."
# adopt must not silently orphan the previous name's containers and volumes.
grep -q 'still owns' Makefile \
    || log_err "'make adopt' renames the project without checking for containers/volumes under the old name; they become unreachable, venv included."
# `clean-all` is documented as a full reset: the baked artifacts sit in the
# workspace root and a 100 MB *.oci.tar survived every one of them.
rmguard_all="$(make_probe "${ROOT_DIR}"/docker-compose*.yml)"
mkdir -p "$rmguard_all/bin"; printf '#!/bin/sh\nexit 0\n' > "$rmguard_all/bin/docker"; chmod +x "$rmguard_all/bin/docker"
: > "$rmguard_all/probe-dev-prod-amd64.oci.tar"; : > "$rmguard_all/probe-dev-prod-amd64.sif.sha256"
( cd "$rmguard_all" && PATH="$rmguard_all/bin:$probe_min_path" make clean-all FORCE=1 ) >/dev/null 2>&1 || true
rmguard_left="$(cd "$rmguard_all" && ls *.oci.tar *.sha256 2>/dev/null | tr '\n' ' ' || true)"
[ -z "$rmguard_left" ] \
    || log_err "'make clean-all' leaves the baked artifacts behind (${rmguard_left}); DEVELOPMENT.md calls it a full reset."
rm -rf "$rmguard_all"
# make resolves every recipe path relative to the CWD, so it must be told when
# that is not the Makefile's own directory: `make -f ../Makefile` from src/ died
# on the first `bash scripts/…` with a raw "No such file".
rmguard_sub="$( cd "$ROOT_DIR/src" 2>/dev/null && make -f ../Makefile help 2>&1 | head -n 1 || true )"
grep -q 'Run make from' <<< "$rmguard_sub" \
    || log_err "make -f from another directory is not refused (got: ${rmguard_sub:-nothing}); the first script path fails instead."
[ "$( cd "$ROOT_DIR" && make -C . help >/dev/null 2>&1; echo $? )" = 0 ] \
    || log_err "'make -C .' is refused by the working-directory guard; that is the supported form."
# …and a target that reads no detected value must not pay for the host probe
# (nvidia-smi + docker info): `make gpus` and `make shell` did.
for rmguard_exempt in gpus shell exec test lint h help stats top update-gpg; do
    grep -qE "^DETECTOR_EXEMPT :=.*(^| )${rmguard_exempt}( |$)" Makefile \
        || log_err "'${rmguard_exempt}' uses no detected variable but is not in DETECTOR_EXEMPT; it runs the host probe for nothing."
done

# One truthiness rule for every switch: FIX/NO_CACHE/SHARE took only 1|true
# while KEEP_VENV and the container's devkit_is_true also accept yes/on, so
# `make lint FIX=yes` quietly linted without fixing.
for rmguard_true in "lint FIX=yes:mlint --fix" "build NO_CACHE=on:--no-cache" "bake-dev SHARE=YES:--share"; do
    rmguard_goal="${rmguard_true%%:*}"; rmguard_want="${rmguard_true#*:}"
    # shellcheck disable=SC2086  # deliberate split into target + assignment
    grep -qF -- "$rmguard_want" <<< "$( cd "$ROOT_DIR" && make -n $rmguard_goal 2>/dev/null || true )" \
        || log_err "'make ${rmguard_goal}' does not act on it; the truthy spellings differ per knob."
done
# The suite itself must not carry make's exports into these probes: the scrub
# at the top, run against a leaked environment, and the live environment now.
rmguard_scrub="$(MAKELEVEL=1 COMPOSE_PROJECT_NAME=leaked HOST_WORKSPACE_PATH=/leaked IMAGE_TAG=leaked LANG="${LANG:-C.UTF-8}" \
    bash -c "$(sed -n '/^if \[ -n "\${MAKELEVEL:-}" \]; then$/,/^fi$/p' scripts/verify_repo.sh); echo \"\${COMPOSE_PROJECT_NAME:-clean} \${HOST_WORKSPACE_PATH:-clean} \${IMAGE_TAG:-clean} \${LANG:-lost}\"" 2>/dev/null)"
[ "$rmguard_scrub" = "clean clean clean ${LANG:-C.UTF-8}" ] \
    || log_err "the make-export scrub leaves '${rmguard_scrub}' (expected 'clean clean clean <LANG>'): 'make verify' and 'bash scripts/verify_repo.sh' would disagree."
[ -z "${COMPOSE_PROJECT_NAME:-}${HOST_WORKSPACE_PATH:-}${MAKELEVEL:-}" ] \
    || log_err "this run inherits make's exports (COMPOSE_PROJECT_NAME/HOST_WORKSPACE_PATH/MAKELEVEL); the probes above are not hermetic."

# …and the sync fence must refuse BEFORE anything writes into the directory it
# is protecting: it used to run after `vcs import` had already populated it.
mkdir -p "$rmguard_probe/sync/ws/config" "$rmguard_probe/sync/ws/dependencies" \
         "$rmguard_probe/sync/outside/repo/.git" "$rmguard_probe/sync/bin"
for rmguard_lib in util_paths.sh util_logging.sh; do
    ln -s "${ROOT_DIR}/config/${rmguard_lib}" "$rmguard_probe/sync/ws/config/${rmguard_lib}"
done
printf 'repositories:\n  a:\n    type: git\n    url: https://example.invalid/a.git\n    version: %s\n' \
    "0123456789abcdef0123456789abcdef01234567" > "$rmguard_probe/sync/ws/dependencies/dependencies.repos"
for rmguard_cmd in git vcs; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/sync/calls.log"\n' "$rmguard_cmd" "$rmguard_probe" \
        > "$rmguard_probe/sync/bin/$rmguard_cmd"
    chmod +x "$rmguard_probe/sync/bin/$rmguard_cmd"
done
rmguard_sync() {   # rmguard_sync <label> <expect refused|ran> [env…]
    local label="$1" want="$2"; shift 2
    : > "$rmguard_probe/sync/calls.log"
    local out; out="$( PATH="$rmguard_probe/sync/bin:$PATH" WORKSPACE_PATH="$rmguard_probe/sync/ws" \
        env "$@" bash scripts/setup_sync_deps.sh --force 2>&1 || true )"
    local got=ran
    { grep -qi 'would .git clean' <<< "$out" && [ ! -s "$rmguard_probe/sync/calls.log" ]; } && got=refused
    [ "$got" = "$want" ] \
        || log_err "sync --force on ${label}: ${got}, expected ${want} (a refusal must precede every command)."
}
rmguard_sync "a target that resolves outside the workspace" refused \
    SYNC_TARGET_DIR="src/thirdparty/../../../outside"
rmguard_sync "the same target, explicitly allowed" ran \
    SYNC_TARGET_DIR="src/thirdparty/../../../outside" DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1
rmguard_sync "a target inside the workspace" ran SYNC_TARGET_DIR="src/thirdparty"
# --force resets the repositories the .repos file MANAGES, and nothing else: it
# used to `find` every .git under the target, so an external target (the
# documented opt-in) reached any repository beneath it — and a vanished target
# resolved to a parent, aiming `git reset --hard` + `clean -ffdx` at trees
# nobody named. Two repositories, one listed, one not.
rmguard_scope="$(cd "$(probe_dir)" && pwd -P)"
mkdir -p "$rmguard_scope/ws/config" "$rmguard_scope/ws/dependencies" "$rmguard_scope/ws/src/thirdparty" "$rmguard_scope/ws/bin"
for rmguard_lib in util_paths.sh util_logging.sh; do
    ln -s "${ROOT_DIR}/config/${rmguard_lib}" "$rmguard_scope/ws/config/${rmguard_lib}"
done
printf 'repositories:\n  managed:\n    type: git\n    url: https://example.invalid/a.git\n    version: %s\n' \
    "0123456789abcdef0123456789abcdef01234567" > "$rmguard_scope/ws/dependencies/dependencies.repos"
printf '#!/bin/sh\nexit 0\n' > "$rmguard_scope/ws/bin/vcs"; chmod +x "$rmguard_scope/ws/bin/vcs"
for rmguard_repo in managed stranger; do
    mkdir -p "$rmguard_scope/ws/src/thirdparty/$rmguard_repo"
    ( cd "$rmguard_scope/ws/src/thirdparty/$rmguard_repo" && git init -q . \
      && printf 'clean\n' > f.txt && git add -A \
      && git -c user.email=p@d -c user.name=p commit -qm init \
      && printf 'DIRTY\n' > f.txt && : > untracked.txt ) >/dev/null 2>&1
done
( cd "$rmguard_scope/ws" && PATH="$rmguard_scope/ws/bin:$probe_min_path" WORKSPACE_PATH="$rmguard_scope/ws" \
  bash "${ROOT_DIR}/scripts/setup_sync_deps.sh" --force ) >/dev/null 2>&1 || true
[ "$(cat "$rmguard_scope/ws/src/thirdparty/managed/f.txt" 2>/dev/null)" = clean ] \
    || log_err "sync --force did not reset the repository .repos manages."
{ [ "$(cat "$rmguard_scope/ws/src/thirdparty/stranger/f.txt" 2>/dev/null)" = DIRTY ] \
  && [ -f "$rmguard_scope/ws/src/thirdparty/stranger/untracked.txt" ]; } \
    || log_err "sync --force reset a repository the .repos file never names; a git clean reached a tree nobody asked about."
# The same two answers with no python3 on PATH: the names came from PyYAML
# alone, so a host without it (macOS ships python3 with no yaml) turned --force
# into a warning and reset nothing.
printf 'DIRTY\n' > "$rmguard_scope/ws/src/thirdparty/managed/f.txt"
printf '#!/bin/sh\nexit 127\n' > "$rmguard_scope/ws/bin/python3"; chmod +x "$rmguard_scope/ws/bin/python3"
( cd "$rmguard_scope/ws" && PATH="$rmguard_scope/ws/bin:$probe_min_path" WORKSPACE_PATH="$rmguard_scope/ws" \
  bash "${ROOT_DIR}/scripts/setup_sync_deps.sh" --force ) >/dev/null 2>&1 || true
[ "$(cat "$rmguard_scope/ws/src/thirdparty/managed/f.txt" 2>/dev/null)" = clean ] \
    || log_err "without PyYAML, sync --force resets nothing and only warns; the documented force mode is a no-op on that host."
{ [ "$(cat "$rmguard_scope/ws/src/thirdparty/stranger/f.txt" 2>/dev/null)" = DIRTY ] \
  && [ -f "$rmguard_scope/ws/src/thirdparty/stranger/untracked.txt" ]; } \
    || log_err "the awk fallback for .repos names reaches a repository the file never names."
rm -rf "$rmguard_scope"
# The workspace ITSELF passed the "inside the workspace" test ('<ws>/' matches
# '<ws>/*'), and the .git walk then reset this repository. Spelled four ways,
# and the external opt-in must not unlock it either.
mkdir -p "$rmguard_probe/sync/ws/.git" "$rmguard_probe/sync/ws/src"
ln -s "$rmguard_probe/sync/ws" "$rmguard_probe/sync/ws/src/rootlink"
rmguard_sync "the workspace itself (.)" refused SYNC_TARGET_DIR="."
rmguard_sync "the workspace itself (src/..)" refused SYNC_TARGET_DIR="src/.."
rmguard_sync "a symlink back to the workspace" refused SYNC_TARGET_DIR="src/rootlink"
rmguard_sync "an ancestor of the workspace, externally allowed" refused \
    SYNC_TARGET_DIR="$rmguard_probe/sync" DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1
rmguard_sync "the workspace itself, externally allowed" refused \
    SYNC_TARGET_DIR="." DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1
rm -rf "$rmguard_probe"
ok "Destructive guards resolve the path first: a workspace round-trip, a false FORCE and an external sync target are all refused."

# =============================================================================
# [gpg-anchor] The pinned fingerprint must exist and stay in sync with the
#      updater that maintains it (`make update-gpg`).
# =============================================================================
# Every dearmor needs --yes: it prompts on a /dev/tty `docker build` lacks,
# which silently broke every ROS 1 image build.
tty_bound="$(grep -nE '^[^#]*gpg([^|#]*)--dearmor' scripts/*.sh config/*.sh 2>/dev/null \
    | grep -v 'verify_repo.sh' | grep -v -- '--yes' || true)"
if [ -n "$tty_bound" ]; then
    log_err "a 'gpg --dearmor' call lacks --yes and will abort under 'docker build' (no /dev/tty):"
    sed 's/^/    /' <<< "$tty_bound" >&2
fi
# Both archives, not just the live one: snapshots.ros.org signs with its OWN
# key, so a ROS_SNAPSHOT_DATE build verified against the live pin fails with
# NO_PUBKEY — and every pin needs the one updater that maintains it.
group
for gpg_pin in ROS_GPG_FINGERPRINT ROS_SNAPSHOT_GPG_FINGERPRINT; do
    gpg_fp="$(awk -F'"' -v k="^${gpg_pin}=" '$0 ~ k {print $2; exit}' scripts/util_apt_helper.sh)"
    [[ "$gpg_fp" =~ ^[0-9A-F]{40}$ ]] \
        || { log_err "${gpg_pin} is '${gpg_fp:-<missing>}', not a 40-character fingerprint."; continue; }
    grep -v '^[[:space:]]*#' scripts/util_apt_helper.sh | grep -qF "\$${gpg_pin}" \
        || log_err "${gpg_pin} is declared but never used; the repository it guards is verified against another key."
    grep -q "\^${gpg_pin}=" scripts/setup_ros_gpg.sh \
        || log_err "'make update-gpg' does not maintain ${gpg_pin}; a rotation would have no path in."
done
# The two must DIFFER: copying the live key into the snapshot pin reintroduces
# exactly the NO_PUBKEY failure this separation exists to fix.
[ "$(awk -F'"' '/^ROS_GPG_FINGERPRINT=/{print $2; exit}' scripts/util_apt_helper.sh)" \
  != "$(awk -F'"' '/^ROS_SNAPSHOT_GPG_FINGERPRINT=/{print $2; exit}' scripts/util_apt_helper.sh)" ] \
    || log_err "the snapshot pin equals the live pin; snapshots.ros.org is signed by a different key and would fail with NO_PUBKEY."
# End to end on a throwaway key (0.05 s): sign, verify, then tamper. Reading a
# key id out of gpg's chatter reported a tampered document as a match, so the
# property under test is that gpg's VERDICT is what decides.
gpg_probe="$(probe_dir)"
gpg_home="$gpg_probe/home"; mkdir -p "$gpg_home" "$gpg_probe/keys"; chmod 700 "$gpg_home"
gpg_verify_fn="$(sed -n '/^verify_signed_by() {$/,/^}$/p' scripts/setup_ros_gpg.sh)"
gpg_made=0
gpg --homedir "$gpg_home" --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'DevKit Probe <probe@invalid>' default default never >/dev/null 2>&1 && gpg_made=1
gpg_fp="$(gpg --homedir "$gpg_home" --batch --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}' || true)"
if [ -z "$gpg_verify_fn" ]; then
    log_err "setup_ros_gpg.sh no longer defines verify_signed_by; the snapshot pin is unchecked."
elif [ "$gpg_made" != 1 ] || [ -z "$gpg_fp" ]; then
    log_info "gpg could not create a probe key here; the snapshot signature check was not exercised."
else
    printf 'Origin: devkit-probe\n' > "$gpg_probe/doc"
    gpg --homedir "$gpg_home" --batch --pinentry-mode loopback --passphrase '' \
        --clearsign -o "$gpg_probe/signed" "$gpg_probe/doc" >/dev/null 2>&1
    gpg --homedir "$gpg_home" --batch --export -o "$gpg_probe/keys/$gpg_fp" "$gpg_fp" >/dev/null 2>&1
    sed 's/^Origin: devkit-probe/Origin: tampered-in-flight/' "$gpg_probe/signed" > "$gpg_probe/tampered"
    # A document that merely NAMES the pin, which the old parser accepted.
    printf 'gpg: using RSA key %s\n[GNUPG:] VALIDSIG %s 0 0 0 4 0 1 8 01 %s\n' \
        "$gpg_fp" "$gpg_fp" "$gpg_fp" > "$gpg_probe/forged"
    gpg_check() {   # gpg_check <document>
        local rc=0
        ( eval "$gpg_verify_fn"
          SNAPSHOT_KEY_URL="file://$gpg_probe/keys/"
          verify_signed_by "file://$gpg_probe/$1" "$gpg_fp" ) >/dev/null 2>&1 || rc=$?
        printf '%s' "$rc"
    }
    [ "$(gpg_check signed)" = "0" ] \
        || log_err "verify_signed_by rejects a genuinely signed document; every snapshot build would report a stale pin."
    [ "$(gpg_check tampered)" != "0" ] \
        || log_err "verify_signed_by accepts a TAMPERED document; gpg's exit status is being discarded."
    [ "$(gpg_check forged)" != "0" ] \
        || log_err "verify_signed_by accepts a document that only claims the pinned key."
fi
rm -rf "$gpg_probe"
grep -q "STRICT_GPG_CHECK" scripts/util_apt_helper.sh \
    || log_err "STRICT_GPG_CHECK is gone from util_apt_helper.sh; the pin has no documented escape hatch left."
# Every ROS image build fetches this key, and the key host rate-limits: a weekly
# cron run died here with HTTP 429 and a bare `curl: (22)` mid-build. Against a
# stubbed curl that fails the same way, in the container the code runs in (the
# helper reads the base image's codename and writes to /usr/share/keyrings, so
# the host is the wrong place to ask): the fetch must retry, and the run must
# end in a sentence that names the key host instead of an exit code.
if docker_live; then
    gpg_fetch="$(probe_dir)"
    printf '#!/bin/sh\necho "$@" >> /stub/curl.log\nexit 22\n' > "$gpg_fetch/curl"
    chmod +x "$gpg_fetch/curl"
    gpg_fetch_out="$( docker run --rm -v "${ROOT_DIR}/scripts/util_apt_helper.sh:/h.sh:ro" -v "$gpg_fetch:/stub" \
        -e PATH=/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin \
        ubuntu:22.04 bash -c 'bash /h.sh setup-ros-repo humble 2>&1; echo "rc=$?"' 2>/dev/null || true )"
    { ! grep -q 'rc=0' <<< "$gpg_fetch_out" && grep -qi 'could not fetch the ros archive key' <<< "$gpg_fetch_out"; } \
        || log_err "a failed ROS key fetch reports no cause: $(tr '\n' ' ' <<< "$gpg_fetch_out" | tail -c 160)"
    grep -q -- '--retry' "$gpg_fetch/curl.log" 2>/dev/null \
        || log_err "the ROS key fetch does not retry ($(tr '\n' ' ' < "$gpg_fetch/curl.log" 2>/dev/null)); one HTTP 429 from the key host fails the whole build."
    rm -rf "$gpg_fetch"
fi
ok "Both ROS pins are wired to their archive and to 'make update-gpg', the snapshot check refuses a document that only CLAIMS the key, and a rate-limited key fetch retries and says so."

# =============================================================================
# [knob-consumers] A documented knob needs a live consumer: log_debug with no
#       in-tree caller still implements DEBUG_MODE.
# =============================================================================
group
if grep -q '^DEBUG_MODE=' .env.example; then
    grep -q '^log_debug()' scripts/util_logging.sh \
        || log_err "DEBUG_MODE is documented in .env.example but log_debug() no longer exists."
    # 2>&1: debug is a diagnostic and goes to stderr, where it cannot corrupt
    # the stdout of a script that emits data (check_env.sh --makefile).
    ( set -euo pipefail; source scripts/util_logging.sh; DEBUG_MODE=true; log_debug probe ) 2>&1 | grep -q probe \
        || log_err "DEBUG_MODE=true does not produce log_debug output."
    ( set -euo pipefail; source scripts/util_logging.sh; DEBUG_MODE=true; log_debug probe ) 2>/dev/null | grep -q probe \
        && log_err "log_debug writes to stdout; a data-emitting script would ship debug lines as data."
fi
# The same rule for the GPU knob: OPENCV_CUDA is documented and `gpu
# opencv_args` is what consumes it.
[ "$(OPENCV_CUDA=off bash scripts/setup_gpu.sh opencv_args 2>/dev/null)" = "-DWITH_CUDA=OFF" ] \
    || log_err "OPENCV_CUDA=off no longer forces -DWITH_CUDA=OFF via 'gpu opencv_args'."
ok "Documented knobs still have a working consumer (DEBUG_MODE → log_debug, OPENCV_CUDA → gpu opencv_args)."

# =============================================================================
# [env-reaches-detector] make's `export` does not reach $(shell …), so the
#       detector reads .env itself and its cache must expire when .env changes.
#       Get either wrong and ROS_DISTRO=noetic builds a humble image.
# =============================================================================
probe_env="$(mktemp "${DEVKIT_PROBE_ROOT}/env.XXXXXX")"
printf 'ROS_DISTRO=noetic\n' > "$probe_env"
# Capture first: `grep -q` exits early and the SIGPIPE fails pipefail.
# Unset first: `make verify` exports ROS_DISTRO into the recipe, so the probe
# would test make's export instead of the .env reader.
probe_out="$( unset ROS_DISTRO BASE_IMAGE
    DEVKIT_ENV_FILE="$probe_env" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
if grep -qx 'ROS_DISTRO := noetic' <<< "$probe_out"; then
    log_ok "check_env.sh honours ROS_DISTRO from .env (make's export never reaches \$(shell))."
else
    log_err "check_env.sh ignores .env: ROS_DISTRO/BASE_IMAGE fall back to the humble default and get cached."
fi
rm -f "$probe_env"
# …and .env.example is the layer BELOW it: the committed answer to "which ROS
# is this project". Both layers must be read HERE, by the detector: the cache it
# writes is included after them, so a setting this script cannot see is inert.
defaults_probe="$(probe_dir)"
printf 'ROS_DISTRO=noetic\n' > "$defaults_probe/.env.example"
: > "$defaults_probe/.env"
defaults_out="$( unset ROS_DISTRO BASE_IMAGE
    DEVKIT_ENV_FILE="$defaults_probe/.env" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
grep -qx 'ROS_DISTRO := noetic' <<< "$defaults_out" \
    || log_err "check_env.sh ignores .env.example; a committed project setting cannot reach the build."
# The local file still wins over it.
printf 'ROS_DISTRO=humble\n' > "$defaults_probe/.env"
defaults_out="$( unset ROS_DISTRO BASE_IMAGE
    DEVKIT_ENV_FILE="$defaults_probe/.env" bash scripts/check_env.sh --makefile 2>/dev/null || true )"
grep -qx 'ROS_DISTRO := humble' <<< "$defaults_out" \
    || log_err ".env no longer overrides .env.example; the local layer must win."
rm -rf "$defaults_probe"
# The cache is keyed on both layers, or an edit to either is ignored until a
# manual clean-cache.
for settings_file in .env .env.example; do
    grep -qF "[ ! ${settings_file} -nt \"\$(DETECTED_ENV_FILE)\" ]" Makefile \
        || log_err "the detection cache is not invalidated when ${settings_file} changes."
done
grep -q '\.env -nt "\$(DETECTED_ENV_FILE)"' Makefile \
    || log_err "the detection cache must be regenerated when .env is newer; it is included after .env and would override it."

# =============================================================================
# [provided-api] util_logging.sh is provided API: a verb with no in-tree caller
#       still ships as a feature. Probed by CALLING it, so a rename, a syntax
#       slip or a "dead code" sweep fails here.
# =============================================================================
group
for fn in log_info log_ok log_warn log_error log_debug log_detail log_step_done \
          devkit_enable_error_trap devkit_auto_color print_banner print_section print_env_info; do
    grep -q "^${fn}()" scripts/util_logging.sh \
        || log_err "util_logging.sh no longer defines ${fn}() — it is provided API for project code."
done
# One bash per assertion group, not per symbol: the whole suite budget is ~1 s.
api_out="$(bash -c 'source scripts/util_logging.sh
    log_detail probe_detail; log_step_done probe_step; print_banner "Custom Label"' 2>/dev/null || true)"
for want in probe_detail probe_step 'DevKit | Custom Label'; do
    grep -qF -- "$want" <<< "$api_out" \
        || log_err "util_logging.sh API probe lost '${want}' (log_detail / log_step_done / print_banner <label>)."
done
# Each documented banner type must render its OWN wordmark. Dropping a case is
# silent otherwise: it falls through to the generic "DevKit | GUIDE" box, which
# is still 3 valid lines — so assert block-art (█) AND per-type uniqueness.
banner_probe="$(bash -c 'source scripts/util_logging.sh
    for t in WELCOME DIAG SETUP GUIDE; do printf "%s:" "$t"; print_banner "$t" | sed -n 2p; done' 2>/dev/null || true)"
{ [ "$(grep -c "█" <<< "$banner_probe")" -eq 4 ] \
  && [ "$(cut -d: -f2- <<< "$banner_probe" | sort -u | wc -l)" -eq 4 ]; } \
    || log_err "print_banner lost a wordmark — WELCOME/DIAG/SETUP/GUIDE must each render distinct block art, not the generic box."
# LOG_FILE must capture what a post-mortem needs — the hint under a finding and
# the step markers, not just the tagged verbs — and it must never contain the
# escapes the console got. Both were true only for _log_base before.
file_probe="$(probe_dir)"
bash -c "source scripts/util_logging.sh
    export LOG_FILE='$file_probe/run.log'; LOG_PREFIX='[T]'
    log_error finding; log_detail explanation; log_step_done step" >/dev/null 2>&1
for want in finding explanation step; do
    grep -qF "$want" "$file_probe/run.log" 2>/dev/null \
        || log_err "LOG_FILE lost the '${want}' line; a captured log must hold hints and steps too."
done
# The CONSOLE stamp too: it skipped the bash-3.2 guard the file stamp has, and
# macOS printed a bare '[]'. The date path is probed everywhere; the printf-%T
# path only where this bash has it (4.2+) — forcing it on 3.2 tests nothing.
stamp_modes="0"
{ [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; } && stamp_modes="1 0"
for stamp_mode in $stamp_modes; do
    bash -c "source scripts/util_logging.sh; __DEVKIT_PRINTF_TIME=$stamp_mode LOG_SHOW_TIME=true log_ok probe" 2>/dev/null \
        | grep -qE '\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' \
        || log_err "LOG_SHOW_TIME=true prints no HH:MM:SS console stamp when __DEVKIT_PRINTF_TIME=${stamp_mode} (the bash-3.2 path is broken)."
done
# Every file line carries a date and time whatever LOG_SHOW_TIME says: the file
# accumulates across container restarts, so an undated entry places nothing.
[ "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$file_probe/run.log" 2>/dev/null)" -eq 3 ] \
    || log_err "LOG_FILE lines are not all timestamped (expected 3 dated lines)."
# …and it must be switchable off: compose defines LOG_FILE for every service, so
# an empty value cannot mean "off" for a caller that has its own default.
# WORKSPACE_PATH points at the probe, so an unhonoured sentinel WOULD leave a
# file there — without it the check passes for the wrong reason.
bash -c "source scripts/util_logging.sh
    export WORKSPACE_PATH='$file_probe' LOG_FILE=off; log_ok probe" >/dev/null 2>&1
[ ! -e "$file_probe/off" ] \
    || log_err "LOG_FILE=off is treated as a path; file logging cannot be switched off."
rm -rf "$file_probe"
# The file half must append the PLAIN argument. Not asserted by reading the
# file: this suite never runs on a terminal, so the console string carries no
# colour to leak there — only the structure can be checked.
grep -qE '\$3" >> "\$__DEVKIT_LOG_PATH"' scripts/util_logging.sh \
    || log_err "_log_write no longer appends its plain argument to LOG_FILE; a captured log would carry ANSI."

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
        || log_err "${prefix_file} logs without a LOG_PREFIX; its lines cannot be attributed."
done
# Values are bracketed Title Case, so a line reads as "[Component] [OK] …".
# --exclude this file: the pattern below is a check, not a prefix.
bad_prefix="$(grep -rhoE --exclude=verify_repo.sh 'LOG_PREFIX="[^"]*"' scripts/*.sh docker/*.sh \
              | grep -vE 'LOG_PREFIX="\[[A-Z][A-Za-z0-9]*( [A-Z$][A-Za-z0-9{}:_-]*)*\]"' || true)"
[ -z "$bad_prefix" ] \
    || log_err "LOG_PREFIX must be bracketed Title Case: ${bad_prefix}"

# One indentation rule across every screen: content at two columns, a heading at
# zero, a nested hint at four. log_ok printed at zero while log_step_done — in
# the same file — printed at two, so `make check` interleaved both.
indent_probe="$(bash -c 'source scripts/util_logging.sh
    LOG_PREFIX="[T]"; log_ok content; log_step_done step; log_detail hint
    print_section Heading' 2>/dev/null | grep -vE '^$' | sed -E 's/[^ ].*//' | awk '{print length}' | tr '\n' ' ')"
[ "$indent_probe" = "2 2 4 0 " ] \
    || log_err "output indentation drifted (content/step/hint/heading columns: ${indent_probe}expected 2 2 4 0)."

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
    || log_err "config/util_paths.sh exports $(wc -w <<< "$path_api")/13 path-API names (got: ${path_api})."
# By EXECUTION, because the reader is what every pre-compose caller depends on.
env_probe="$(probe_dir)"
printf 'K="v1"\r\nK=v2\n' > "$env_probe/.env"
[ "$(bash -c "source config/util_paths.sh >/dev/null 2>&1; devkit_env_value K '$env_probe/.env'" 2>/dev/null)" = "v2" ] \
    || log_err "devkit_env_value must return the LAST assignment with quotes and CR stripped."
rm -rf "$env_probe"
ok "Provided API intact (util_logging verbs and banners, util_paths path set and .env reader)."

# The shared-library table in docs/DEVELOPMENT.md is the map a contributor uses
# to find the owner of a rule before writing a second copy of it. A library that
# is not listed there is one nobody will find.
undocumented_libs=""
for lib in config/util_paths.sh scripts/util_*.sh; do
    [ -f docs/DEVELOPMENT.md ] || continue   # a fork may keep only its own docs
    grep -qF "\`${lib}\`" docs/DEVELOPMENT.md || undocumented_libs="${undocumented_libs} ${lib}"
done
[ -z "$undocumented_libs" ] \
    && log_ok "Shared libraries are all listed in the docs/DEVELOPMENT.md SSOT table." \
    || log_err "shared libraries missing from the docs/DEVELOPMENT.md SSOT table:${undocumented_libs}"

# =============================================================================
# [clean-semantics] `make clean` must not destroy install/.venv — it costs a
#       full mksync to rebuild, and mclean already preserves it.
# =============================================================================
# `make clean` for real, in a probe workspace carrying every layout a build
# leaves: build/, devel/ (ROS 1), log/, install/ output, the venv, and the
# three convenience links (dangling, as they are on the host).
group
clean_probe="$(make_probe)"
clean_tree() {
    mkdir -p "$1/build/x" "$1/devel/x" "$1/log" "$1/install/.venv/bin" "$1/install/share/p"
    : > "$1/build/x/o"; : > "$1/devel/x/f"; : > "$1/log/l"; : > "$1/install/.venv/bin/python3"; : > "$1/install/share/p/f"
    ln -sfn /workspace/build/compile_commands.json "$1/compile_commands.json"
    ln -sfn install/.venv "$1/.venv"; ln -sfn config/colcon.meta "$1/colcon.meta"
}
clean_tree "$clean_probe"
(cd "$clean_probe" && make clean) >/dev/null 2>&1 \
    || log_err "'make clean' fails on an ordinary workspace."
clean_left="$(cd "$clean_probe" && ls -d build devel log install/share compile_commands.json .venv colcon.meta 2>/dev/null | tr '\n' ' ' || true)"
[ -z "$clean_left" ] \
    || log_err "'make clean' left: ${clean_left}— build/, devel/, log/, the install output and the three links must go."
[ -f "$clean_probe/install/.venv/bin/python3" ] \
    || log_err "'make clean' removed install/.venv; recreating it costs a full mksync (KEEP_VENV=0 opts in)."
(cd "$clean_probe" && make clean KEEP_VENV=0 FORCE=1) >/dev/null 2>&1 || true
[ ! -e "$clean_probe/install" ] \
    || log_err "'make clean KEEP_VENV=0' leaves install/ behind; the entrypoint recreates it as root and a later rm cannot remove it."
# Output Docker made root-owned cannot be removed from the host: `clean` must
# say how (the docker run hint) and go on, not die on a raw rm error.
clean_tree "$clean_probe"; mkdir -p "$clean_probe/build/locked"; : > "$clean_probe/build/locked/f"; chmod 555 "$clean_probe/build/locked"
clean_rc=0; clean_out="$(cd "$clean_probe" && make clean 2>&1)" || clean_rc=$?
chmod 755 "$clean_probe/build/locked" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    { [ "$clean_rc" -eq 0 ] && grep -q 'docker run --rm' <<< "$clean_out"; } \
        || log_err "'make clean' on an unremovable build/ exits ${clean_rc} without the docker-run remediation hint."
fi
rm -rf "$clean_probe"
ok "'make clean' empties build/devel/log, the install output and the links, keeps the venv unless asked, and hints on root-owned output."
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
# [knob-implementations] No advertised dead switches: every documented knob has
#      an implementation.
# =============================================================================
# One corpus, one pass (20 recursive greps cost ~75 ms). Implementation files
# only: the completion list advertises knobs and would vouch for itself.
knob_corpus="$(cat Makefile $(find scripts config -type f \( -name '*.sh' -o -name '*.bash' \) \
    ! -name 'verify_repo.sh' ! -name 'devkit_make_completion.bash') 2>/dev/null || true)"
dead_knobs=()
for knob in DEVKIT_SLURM_PARTITION DEVKIT_SLURM_GRES DEVKIT_SLURM_CPUS_PER_TASK DEVKIT_SLURM_NODES \
            DEVKIT_SLURM_NTASKS DEVKIT_SLURM_MEM DEVKIT_SLURM_TIME DEVKIT_SLURM_JOB_NAME \
            DEVKIT_SLURM_OUTPUT DEVKIT_SLURM_ERROR DEVKIT_SLURM_COMMENT DEVKIT_SLURM_EXTRA_ARGS \
            CONTAINER_DATA_ROOT CONTAINER_RUN_ROOT SLURM_DATA_ROOT SLURM_RUN_ROOT \
            APT_SNAPSHOT_DATE APT_SNAPSHOT_FALLBACK ROS_SNAPSHOT_DATE STRICT_GPG_CHECK \
            DOCKER_DEV_CACHE_DIR BAKE_FORMAT UV_EXTRA DEVKIT_SLURM_ARRAY DEVKIT_SLURM_ACCOUNT \
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
# [render-probes] The probes must stay timeout-guarded and key=value: an
#      unreachable DISPLAY hangs hwcheck forever, a shape change blanks it.
# =============================================================================
group
for fn in probe_gl probe_egl probe_vulkan probe_gl_libs; do
    grep -q "^${fn}()" scripts/util_gpu_detect.sh || log_err "util_gpu_detect.sh is missing ${fn}()"
done
grep -q 'timeout "\$GPU_PROBE_TIMEOUT"' scripts/util_gpu_detect.sh \
    || log_err "Rendering probes must run under 'timeout' (a stale DISPLAY would hang hwcheck)."
# The probes must survive a tool that prints usable data and then exits non-zero.
# Run with no display: exercises the guard/early-return paths in ~1 ms instead
# of paying a real 500 ms glxinfo round-trip on a machine that has one.
if ! ( set -euo pipefail; unset DISPLAY WAYLAND_DISPLAY; source scripts/util_gpu_detect.sh
       probe_gl >/dev/null 2>&1 || true; probe_egl >/dev/null 2>&1 || true
       probe_vulkan >/dev/null 2>&1 || true; probe_gl_libs >/dev/null 2>&1 || true ); then
    log_err "Rendering probes abort under 'set -euo pipefail' (callers use it)."
fi
# Diagnostics must survive tools that exist but fail (timedatectl without a
# systemd bus, stub nvidia-smi, DISPLAY pointing nowhere): under `set -o
# pipefail` one unguarded assignment truncates the whole report.
unguarded="$(grep -nE '^[[:space:]]*[A-Z_]+=\$\((timedatectl|nvidia-smi|glxinfo|vulkaninfo|hostname|ip|df)' scripts/check_hardware.sh \
    | grep -v '|| true' || true)"
if [ -n "$unguarded" ]; then
    log_err "check_hardware.sh has an unguarded capture from a fallible tool (aborts the scan under pipefail):"
    sed 's/^/    /' <<< "$unguarded" >&2
fi
# Diagnostics must not claim a subsystem that is absent: compose passes
# ROS_DISTRO to every service, so the non-ROS image reported "ROS: humble".
# Probed on this host, which has no /opt/ros at all.
if [ ! -d "/opt/ros/${ROS_DISTRO:-humble}" ]; then
    ros_claim="$(ROS_DISTRO=humble COMPOSE_PROJECT_NAME=probe bash -c \
        'source scripts/util_logging.sh; print_env_info' 2>/dev/null | sed -E $'s/\033\\[[0-9;]*m//g')"
    case "$ros_claim" in
        *"ROS: humble"*) log_err "print_env_info claims ROS is present from ROS_DISTRO alone; the non-ROS image reports a distro it does not have." ;;
    esac
fi
grep -q 'd "/opt/ros/${ROS_DISTRO' scripts/check_hardware.sh \
    || log_err "check_hardware.sh reports ROS from ROS_DISTRO alone (compose sets it on every service)."
ok "Rendering-stack probes (GL/EGL/Vulkan/loader) are timeout-guarded and errexit-safe."

# =============================================================================
# [colour-discipline] Colour discipline: output must be plain when redirected or NO_COLOR is
#      set, otherwise CI logs and `> file` captures fill up with SGR escapes.
# =============================================================================
group
if ! grep -q 'devkit_auto_color' scripts/util_logging.sh; then
    log_err "util_logging.sh must provide devkit_auto_color (NO_COLOR / non-TTY handling)."
fi
for f in scripts/check_hardware.sh scripts/setup_gpu.sh scripts/check_wsl.sh \
         scripts/check_preflight.sh scripts/setup_sync_deps.sh scripts/check_deps.sh; do
    grep -q 'devkit_auto_color' "$f" || log_err "$f does not call devkit_auto_color."
done
# End-to-end on a real script: NO_COLOR must win even on a terminal.
NO_COLOR=1 bash scripts/check_wsl.sh 2>/dev/null | grep -q $'\033' \
    && log_err "NO_COLOR=1 still yields ANSI from scripts/check_wsl.sh (devkit_auto_color not reached)."
# bash's `echo` does not interpret \033 — the escape reaches the screen as
# literal text. `gpus` printed '\033[33m(/usr/lib/wsl/lib MISSING)' that way.
# `sed 's/#.*//'` first: this rule's own explanation names `echo` and \033.
raw_echo="$(grep -rn --exclude=verify_repo.sh -F '\033' Makefile scripts config docker \
             | sed 's/#.*//' | grep -E 'echo ([^-]|-[^e])' || true)"
[ -z "$raw_echo" ] \
    || log_err "'echo' without -e cannot emit an escape (use printf): $(cut -d: -f1,2 <<< "$raw_echo" | tr '\n' ' ')"
# End-to-end, because the guard only covers recipes that USE the colour
# variables: a recipe hardcoding \033 ignores it and pollutes `make help > log`.
make_help_out="$(make help 2>/dev/null || true)"
grep -q $'\033' <<< "$make_help_out" \
    && log_err "'make help' emits ANSI escapes into a pipe — a recipe hardcodes an escape instead of using \$(CYAN)/\$(NC)."
# End-to-end on the shared mechanism (cheap): piping must yield plain text.
if bash -c 'source scripts/util_logging.sh; devkit_auto_color; echo -e "\033[32mx\033[0m"' 2>/dev/null | grep -q $'\033'; then
    log_err "devkit_auto_color does not strip ANSI when stdout is not a terminal."
fi
# stderr too: warnings and errors are exactly what a user greps from a log.
if bash -c 'source scripts/util_logging.sh; devkit_auto_color; log_warn probe' 2>&1 >/dev/null | grep -q $'\033'; then
    log_err "devkit_auto_color leaves ANSI on stderr — log_warn/log_error pollute redirected logs."
fi
# The log verbs must be plain off-TTY on their OWN, without devkit_auto_color:
# the in-container shell functions (config/util_aliases.sh) cannot call it, so
# this is what keeps `mksync | tee build.log` free of escapes. stdout and stderr
# are asserted separately — each verb resolves colour against the stream it uses.
if bash -c 'source scripts/util_logging.sh; log_ok probe; log_detail probe; log_step_done probe' 2>/dev/null | grep -q $'\033'; then
    log_err "log_ok/log_detail/log_step_done emit ANSI into a pipe without devkit_auto_color."
fi
if bash -c 'source scripts/util_logging.sh; log_error probe' 2>&1 >/dev/null | grep -q $'\033'; then
    log_err "log_error emits ANSI into a redirected stderr without devkit_auto_color."
fi
# A destructive in-container command must refuse an unknown argument instead of
# falling through to its default: `mclean --help` used to delete the build tree.
mclean_probe="$(probe_dir)"
mkdir -p "$mclean_probe/config" "$mclean_probe/build/keep"
cp config/util_aliases.sh config/util_paths.sh "$mclean_probe/config/" 2>/dev/null || true
: > "$mclean_probe/build/keep/file"
rc=0
bash --norc -c "WORKSPACE_PATH='$mclean_probe' source '$mclean_probe/config/util_aliases.sh' >/dev/null 2>&1
    mclean --devkit-bogus" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 2 ] && [ -f "$mclean_probe/build/keep/file" ]; } \
    || log_err "mclean accepts an unknown flag (exit ${rc}) and deleted the build tree anyway."
rm -rf "$mclean_probe"
# …and the in-container commands must go through those verbs, not hand-rolled
# escapes, or the guarantee above stops covering the output a user actually pipes.
# __require_cmd, not a build entry point: it exercises log_error + log_detail
# together and touches no filesystem, so this stays safe in a real project tree.
alias_msg="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1; __require_cmd devkit-no-such-tool" 2>&1 || true)"
{ grep -q '\[ERROR\]' <<< "$alias_msg" && grep -q '→' <<< "$alias_msg" \
  && ! grep -q $'\033' <<< "$alias_msg"; } \
    || log_err "config/util_aliases.sh prints raw escapes (or nothing) on failure — use log_error/log_warn/log_detail."
# The help screen runs in the user's shell, so it cannot call devkit_auto_color
# and must drop colour itself (`h | tee log`). The function, not the alias: an
# alias defined in the same command string does not expand at parse time.
help_piped="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1; __print_container_help" 2>/dev/null || true)"
{ [ -n "$help_piped" ] && ! grep -q $'\033' <<< "$help_piped"; } \
    || log_err "in-container 'h' emits ANSI escapes into a pipe (or printed nothing) — it must drop colour off-TTY."
ok "Colour output is TTY/NO_COLOR aware (scripts, Makefile and in-container help)."

# =============================================================================
# [reproducibility] The pinning mechanism must be wired. What a given build
#      still has to pin itself is listed in docs/DEVELOPMENT.md.
# =============================================================================
group
# The APT snapshot switch, by execution — every branch below returns before it
# writes under /etc: a malformed date is refused (2), an unreachable
# snapshot.ubuntu.com fails CLOSED (1) unless APT_SNAPSHOT_FALLBACK opts into
# the rolling mirrors, and 'latest' is a no-op.
snap_probe="$(probe_dir)"
printf '#!/bin/sh\nexit 6\n' > "$snap_probe/curl"; chmod +x "$snap_probe/curl"
snap_rc() { local rc=0; ( PATH="$snap_probe:$probe_min_path" env "$@" bash scripts/util_apt_helper.sh configure-snapshot "${SNAP_DATE}" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
[ "$(SNAP_DATE=2026-01-01 snap_rc)" = 2 ] \
    || log_err "configure-snapshot accepts a date that is not YYYYMMDDTHHMMSSZ; apt would be pointed at a mirror path that does not exist."
[ "$(SNAP_DATE=20260101T000000Z snap_rc)" = 1 ] \
    || log_err "configure-snapshot proceeds while snapshot.ubuntu.com is unreachable; the build would silently fall back to rolling mirrors."
[ "$(SNAP_DATE=20260101T000000Z snap_rc APT_SNAPSHOT_FALLBACK=1 DEVKIT_APT_STATE_DIR="$snap_probe/state")" = 0 ] \
    || log_err "APT_SNAPSHOT_FALLBACK=1 no longer lets a build past an unreachable snapshot server."
[ "$(SNAP_DATE=latest snap_rc)" = 0 ] \
    || log_err "configure-snapshot latest is not a no-op."
# The opt-out is not the default anywhere the build arg is declared or passed…
grep -qxF 'ARG APT_SNAPSHOT_FALLBACK=false' docker/Dockerfile \
    || log_err "the Dockerfile defaults APT_SNAPSHOT_FALLBACK on; a pinned build whose snapshot server is down would silently use rolling mirrors."
grep -qE '^\s+APT_SNAPSHOT_FALLBACK: \$\{APT_SNAPSHOT_FALLBACK:-false\}' docker-compose.common.yml \
    || log_err "compose does not pass APT_SNAPSHOT_FALLBACK (default false) as a build arg; the .env knob would be dead for 'make build'."
# …and a fallback that WAS taken is written into the artifact: the helper leaves
# a marker and the release manifest reports apt_snapshot_applied=false.
[ "$(cat "$snap_probe/state/apt-snapshot-fallback" 2>/dev/null)" = 20260101T000000Z ] \
    || log_err "a snapshot fallback leaves no marker behind; the manifest could not tell a pinned build from a fallen-back one."
snap_manifest() { local name="$1"; shift; ( cd "$snap_probe" && env "$@" APT_SNAPSHOT_DATE=20260101T000000Z WS_ROOT="$snap_probe" \
    bash "${ROOT_DIR}/scripts/util_release_metadata.sh" "$snap_probe/$name.json" >/dev/null 2>&1; cat "$snap_probe/$name.json" 2>/dev/null ) ; }
grep -q '"apt_snapshot_applied":false' <<< "$(snap_manifest fallen DEVKIT_APT_STATE_DIR="$snap_probe/state")" \
    || log_err "the release manifest does not report apt_snapshot_applied=false after a fallback."
grep -q '"apt_snapshot_applied":true' <<< "$(snap_manifest pinned DEVKIT_APT_STATE_DIR="$snap_probe/nostate")" \
    || log_err "the release manifest does not report apt_snapshot_applied=true for a pinned build that held."
rm -rf "$snap_probe"
# The timestamp reaches the image build as a build arg (the manifest's build_date).
grep -qxF 'SOURCE_DATE_EPOCH=1700000000' <<< "$(bake_argv prod dev SOURCE_DATE_EPOCH=1700000000)" \
    || log_err "a bake does not forward SOURCE_DATE_EPOCH to docker build; the release manifest's build_date would float."
# The .repos pin, by EXECUTION on a real branch ref: warn by default (a branch
# is a legitimate choice mid-development) but REFUSE under DEVKIT_REQUIRE_PINNED,
# which prod bakes set — a release must not be built from a branch that moved.
# A probe tree, not the real dependencies/: WS_ROOT honours WORKSPACE_PATH when
# it holds config/util_paths.sh, so the committed .repos file is never touched.
pin_probe="$(probe_dir)"
mkdir -p "$pin_probe/dependencies"; ln -s "${ROOT_DIR}/config" "$pin_probe/config"
printf 'repositories:\n  loose:\n    type: git\n    url: https://example.invalid/x.git\n    version: main\n' \
    > "$pin_probe/dependencies/dependencies.repos"
pin_out="$(DEVKIT_DRY_RUN=1 WORKSPACE_PATH="$pin_probe" bash scripts/setup_sync_deps.sh 2>&1 || true)"
grep -qi 'unpinned' <<< "$pin_out" \
    || log_err "sync_deps does not lint .repos for unpinned branch refs; a release could float."
# Match the REFUSAL, not just a non-zero exit: this script also exits non-zero
# when vcstool is absent, which would satisfy an exit-code-only assertion.
pin_strict="$(DEVKIT_DRY_RUN=1 DEVKIT_REQUIRE_PINNED=1 WORKSPACE_PATH="$pin_probe" \
    bash scripts/setup_sync_deps.sh 2>&1 || true)"
grep -qi 'DEVKIT_REQUIRE_PINNED' <<< "$pin_strict" \
    || log_err "DEVKIT_REQUIRE_PINNED=1 accepts a branch ref; prod bakes would ship a floating dependency."
grep -qi 'DEVKIT_REQUIRE_PINNED' <<< "$pin_out" \
    && log_err "sync_deps refuses an unpinned ref without DEVKIT_REQUIRE_PINNED; a branch is a legitimate choice mid-development."

# Shape must not decide whether a pin is enforced. Flow style and a deeper
# indent are ordinary YAML; a lint that cannot read them used to let
# `version: main` through the release gate while only printing a warning.
pin_hash="0123456789abcdef0123456789abcdef01234567"
pin_case() {   # pin_case <label> <expect-blocked yes|no> <repos body>
    printf '%s\n' "$3" > "$pin_probe/dependencies/dependencies.repos"
    local out
    out="$(DEVKIT_DRY_RUN=1 DEVKIT_REQUIRE_PINNED=1 WORKSPACE_PATH="$pin_probe" \
        bash scripts/setup_sync_deps.sh 2>&1 || true)"
    local blocked=no
    grep -qE 'DEVKIT_REQUIRE_PINNED=1' <<< "$out" && blocked=yes
    [ "$blocked" = "$2" ] \
        || log_err "release gate on ${1}: blocked=${blocked}, expected ${2}."
}
pin_case "flow-style unpinned"   yes "repositories:
  a: {type: git, url: https://example.invalid/a.git, version: main}"
pin_case "deeper-indent unpinned" yes "repositories:
    a:
      type: git
      url: https://example.invalid/a.git
      version: main"
# A version field is a STRING. YAML's implicit typing turns an all-digit hash
# into a number — safe_load reads 40 zeros as int 0 — and the release then
# reads as unpinned. BaseLoader is what keeps every scalar a string.
pin_case "pinned, numeric-looking hash" no "repositories:
  a:
    type: git
    url: https://example.invalid/a.git
    version: 0000000000000000000000000000000000000000"
pin_case "pinned with an extra field" no "repositories:
  a:
    type: git
    url: https://example.invalid/a.git
    version: ${pin_hash}
    remote: origin"
# …and with no YAML parser the lint must FAIL CLOSED: unread is not pinned.
mkdir -p "$pin_probe/bin"
printf '#!/bin/sh\ncase "$*" in *"import yaml"*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" \
    > "$pin_probe/bin/python3"
chmod +x "$pin_probe/bin/python3"
pin_closed="$(PATH="$pin_probe/bin:$PATH" DEVKIT_DRY_RUN=1 DEVKIT_REQUIRE_PINNED=1 \
    WORKSPACE_PATH="$pin_probe" bash scripts/setup_sync_deps.sh 2>&1 || true)"
grep -qE 'DEVKIT_REQUIRE_PINNED=1' <<< "$pin_closed" \
    && log_err "without a YAML parser the lint blocks a pinned .repos it can read; only unreadable input may fail closed."
printf 'repositories:\n  a: {type: git, url: https://example.invalid/a.git, version: main}\n' \
    > "$pin_probe/dependencies/dependencies.repos"
pin_closed="$(PATH="$pin_probe/bin:$PATH" DEVKIT_DRY_RUN=1 DEVKIT_REQUIRE_PINNED=1 \
    WORKSPACE_PATH="$pin_probe" bash scripts/setup_sync_deps.sh 2>&1 || true)"
grep -qE 'DEVKIT_REQUIRE_PINNED=1' <<< "$pin_closed" \
    || log_err "without a YAML parser an unreadable .repos passes the release gate; unread is not proof of a pin."
rm -rf "$pin_probe"
# Production artifact self-containment. Asserted by EXECUTION, not by grepping
# for a variable name: the shipped image copies install/ and never src/ or
# build/, so `--symlink-install` would leave dangling links and a CMake build
# that never installs would ship nothing at all.
prod_probe="$(probe_dir)"
mkdir -p "$prod_probe/bin" "$prod_probe/config" "$prod_probe/src"
cp config/util_aliases.sh config/util_paths.sh "$prod_probe/config/" 2>/dev/null || true
printf '#!/bin/sh\necho "$*"\n' > "$prod_probe/bin/colcon"
printf '#!/bin/sh\necho "$*"\n' > "$prod_probe/bin/catkin_make"
chmod +x "$prod_probe/bin/colcon" "$prod_probe/bin/catkin_make"
mkdir -p "$prod_probe/install/share/p"; : > "$prod_probe/install/share/p/f"
# $2 selects the ROS generation: 2 = colcon (default), 1 = catkin_make
build_flags() {
    env -i PATH="$prod_probe/bin:$probe_min_path" HOME=/tmp WORKSPACE_PATH="$prod_probe" \
        ROS_DISTRO=humble ROS_VERSION="${2:-2}" ${1:+DEVKIT_BUILD_TYPE=$1} \
        bash -lc "source $prod_probe/config/util_aliases.sh 2>/dev/null; cbuild" 2>/dev/null
}
case "$(build_flags prod)" in
    *--symlink-install*) log_err "prod cbuild still passes --symlink-install (shipped install/ would contain dangling links into src/)." ;;
esac
case "$(build_flags '')" in
    *--symlink-install*) ;;
    *) log_err "dev cbuild lost --symlink-install (edit-without-rebuild workflow broken)." ;;
esac
# ROS 1: catkin_make writes to devel/, so prod must invoke the install target.
# Match the catkin_make SUBCOMMAND (first word), not any occurrence of the
# word: -DCMAKE_INSTALL_PREFIX=<path>/install would satisfy a loose *install*.
case "$(build_flags prod 1)" in
    install\ *|install) ;;
    *) log_err "ROS 1 prod cbuild does not run 'catkin_make install'; the runtime image copies install/ only." ;;
esac
# The shipped runtime must not carry tools it only needed at build time. Each
# of these was measured in a real prod image: `file` + libmagic-mgc 7.4 MB for
# an ELF test four bytes can do, pip/setuptools/wheel 18 MB of a package manager
# the runtime never calls (and the entire content of its pip manifest).
grep -qE '^[^#]*(^|[[:space:]])file([[:space:]\\]|$)' <<< "$(awk '/AS prod-base$/{p=1} p && /^FROM / && !/AS prod-base$/{p=0} p' docker/Dockerfile)" \
    && log_err "prod-base installs 'file' (plus libmagic-mgc, 7.4 MB) for check_deps' ELF probe; four magic bytes settle it."
grep -qE '^[^#]*file "\$binary"' scripts/check_deps.sh \
    && log_err "check_deps.sh calls file(1) again, which the shipped runtime would have to install."
elf_probe="$(probe_dir)"; printf '\177ELF\002\001\001' > "$elf_probe/real.so"; printf 'text\n' > "$elf_probe/plain.txt"
elf_seen="$( bash -c 'source scripts/check_deps.sh --help >/dev/null 2>&1; true'; \
    bash -c "$(awk '/^is_elf\(\)/{print; exit}' scripts/check_deps.sh); is_elf '$elf_probe/real.so' && echo yes; is_elf '$elf_probe/plain.txt' && echo WRONG; true" 2>/dev/null || true )"
[ "$elf_seen" = yes ] \
    || log_err "check_deps.sh's ELF test misreads a binary or a text file (got: '${elf_seen}')."
rm -rf "$elf_probe"
grep -qE '^[^#]*seed=\(\)' config/util_aliases.sh \
    || log_err "mkenv seeds pip/setuptools/wheel into a production venv too (18 MB the runtime never calls)."
# …and the CUDA environment must not advertise a directory the image lacks.
grep -qE '^[^#]*LD_LIBRARY_PATH=/usr/local/cuda' docker/Dockerfile \
    && log_err "the Dockerfile exports LD_LIBRARY_PATH=/usr/local/cuda/lib64 into every image; the CUDA packages install their own ld.so.conf.d entry."
# A non-ROS artifact must not claim a ROS distro: base exported ROS_DISTRO into
# every image and the dev-flavour manifest read 'humble' for a distro it does
# not contain. The ROS stages set it; the manifest is told explicitly.
awk '/AS base$/{p=1} p && /^FROM / && !/AS base$/{p=0} p && /^[[:space:]]*ROS_DISTRO=/{found=1} END{exit found ? 1 : 0}' docker/Dockerfile \
    || log_err "the 'base' stage exports ROS_DISTRO, so a non-ROS image and its release manifest name a distro they do not contain."
grep -qE 'ROS_DISTRO="\$\(\[ "\$PROD_ENV" = ros \]' docker/Dockerfile \
    || log_err "the release manifest is not told which flavour it describes; a PROD_ENV=dev artifact records the ROS distro of the build arg."
grep -qE '^ARG TARGETARCH$' docker/Dockerfile \
    || log_err "ARG TARGETARCH carries a default, which beats the value BuildKit sets from --platform."

# Deployment goal: the shipped tree must not carry plaintext project source.
src_probe="$(probe_dir)"; mkdir -p "$src_probe/pkg/lib/python3/site-packages/pkg" "$src_probe/pkg/share/pkg/launch"
printf 'SECRET=1\n' > "$src_probe/pkg/lib/python3/site-packages/pkg/core.py"
printf 'x\n'        > "$src_probe/pkg/share/pkg/launch/a.launch.py"
# Entry points are called by NAME: an executable node (ROS install(PROGRAMS))
# and a shebang script without the bit. The strip deleted both and exited 0,
# leaving a .pyc nothing invokes.
mkdir -p "$src_probe/pkg/lib/pkg"
printf '#!/usr/bin/env python3\nprint(1)\n' > "$src_probe/pkg/lib/pkg/node.py"; chmod 755 "$src_probe/pkg/lib/pkg/node.py"
printf '#!/usr/bin/env python3\nprint(2)\n' > "$src_probe/pkg/lib/pkg/tool.py"
DEVKIT_STRIP_SOURCE=1 bash scripts/check_deps.sh "$src_probe" >/dev/null 2>&1 || true
if [ -f "$src_probe/pkg/lib/python3/site-packages/pkg/core.py" ]; then
    log_err "DEVKIT_STRIP_SOURCE=1 did not remove plaintext source from the install tree."
elif [ ! -f "$src_probe/pkg/share/pkg/launch/a.launch.py" ]; then
    log_err "Source strip removed a launch file; 'ros2 launch' reads those as source."
elif [ ! -x "$src_probe/pkg/lib/pkg/node.py" ] || [ ! -f "$src_probe/pkg/lib/pkg/tool.py" ]; then
    log_err "Source strip deleted an executable/shebang entry point; the .pyc it leaves is never invoked by name."
fi
# With the no-source policy on top, the conflict must FAIL, naming the file.
src_rc=0; src_out="$(DEVKIT_STRIP_SOURCE=1 DEVKIT_FAIL_ON_SOURCE=1 bash scripts/check_deps.sh "$src_probe" 2>&1)" || src_rc=$?
{ [ "$src_rc" -ne 0 ] && grep -q 'lib/pkg/node.py' <<< "$src_out"; } \
    || log_err "DEVKIT_FAIL_ON_SOURCE=1 with an unstrippable entry point exits ${src_rc} (must fail and name the file)."
rm -rf "$src_probe"
grep -q 'cmake --install' config/util_aliases.sh \
    || log_err "mbuild must install into install/ for prod builds; the runtime image never copies build/."
# The quality-loop tools must not ship. uv installs the `dev` dependency-group
# by DEFAULT, so a production venv would carry ruff and pytest unless uvs opts
# out — asserted against a fake `uv` that echoes the argv it was handed.
printf '#!/bin/sh\necho "$*"\n' > "$prod_probe/bin/uv"; chmod +x "$prod_probe/bin/uv"
mkdir -p "$prod_probe/install/.venv/bin"; printf '#!/bin/sh\n' > "$prod_probe/install/.venv/bin/python3"
chmod +x "$prod_probe/install/.venv/bin/python3"
printf '[project]\nname = "p"\nversion = "0"\n' > "$prod_probe/src/pyproject.toml"
: > "$prod_probe/src/uv.lock"
sync_flags() {
    env -i PATH="$prod_probe/bin:$probe_min_path" HOME=/tmp WORKSPACE_PATH="$prod_probe" \
        ${1:+DEVKIT_BUILD_TYPE=$1} \
        bash -c "source $prod_probe/config/util_aliases.sh 2>/dev/null; uvs"
}
case "$(sync_flags prod)" in
    *--no-default-groups*) ;;
    *) log_err "prod uvs does not pass --no-default-groups; the shipped venv would carry the dev group (ruff, pytest)." ;;
esac
case "$(sync_flags '')" in
    *--no-default-groups*) log_err "dev uvs excludes the dev dependency-group, so mtest/mlint have no runner." ;;
esac
# The flag only helps if the Dockerfile actually sets it on the builder stages.
awk '
    /AS prod-builder$/  {inside=1}
    inside && /^FROM / && !/AS prod-builder$/ {inside=0}
    inside && /mksync/  {found=1}
    inside && /mksync/ && /DEVKIT_BUILD_TYPE=prod/ {ok=1}
    END {exit (found && !ok) ? 1 : 0}' docker/Dockerfile \
    || log_err "docker/Dockerfile: prod-builder runs mksync without DEVKIT_BUILD_TYPE=prod."
# A production build resolves nothing: `uvs` passes --locked, so a missing or
# stale lock must stop the build rather than silently resolve a fresh set.
[ ! -f src/pyproject.toml ] || [ -f src/uv.lock ] \
    || log_err "src/pyproject.toml has no src/uv.lock; 'make bake-prod' passes --locked and would fail."
# …and the lock must still describe THIS pyproject. Presence alone let a
# dependency added without `mksync` through: `uv sync --locked` then failed
# minutes into the production build, which is the one place it must not.
lock_state="$(python3 - <<'PYLOCK' 2>/dev/null || echo 'parse failed'
import pathlib, tomllib
from collections import Counter
proj = tomllib.loads(pathlib.Path('src/pyproject.toml').read_text())
lock = tomllib.loads(pathlib.Path('src/uv.lock').read_text())
p = proj.get('project', {})
def names(reqs):     # 'ruff>=0.6' → ('ruff', '>=0.6')
    out = Counter()
    for r in reqs:
        r = r.split(';')[0].strip()
        for i, ch in enumerate(r):
            if ch in '=<>!~[ ':
                out[(r[:i].lower().replace('_', '-'), r[i:].replace(' ', '').strip())] += 1
                break
        else:
            out[(r.lower().replace('_', '-'), '')] += 1
    return out
declared = names(p.get('dependencies', []))
for extra in (p.get('optional-dependencies') or {}).values():
    declared += names(extra)
for group in (proj.get('dependency-groups') or {}).values():
    declared += names([g for g in group if isinstance(g, str)])
own = [e for e in lock.get('package', []) if e.get('name') == p.get('name')]
if not own:
    print(f"the lock has no entry for '{p.get('name')}'")
    raise SystemExit
meta = own[0].get('metadata', {})
locked = Counter()
for entry in meta.get('requires-dist', []):
    locked[(entry['name'].lower().replace('_', '-'), (entry.get('specifier') or '').replace(' ', ''))] += 1
for group in (meta.get('requires-dev') or {}).values():
    for entry in group:
        locked[(entry['name'].lower().replace('_', '-'), (entry.get('specifier') or '').replace(' ', ''))] += 1
missing = declared - locked
extra = locked - declared
print('in sync' if not missing and not extra else
      f"declared but not locked: {sorted(missing.elements())}; locked but not declared: {sorted(extra.elements())}")
PYLOCK
)"
[ "$lock_state" = "in sync" ] \
    || log_err "src/uv.lock is stale — ${lock_state}. Run mksync in the container and commit the lock, or 'make bake-prod' dies at 'uv sync --locked'."
rm -f "$prod_probe/src/uv.lock"
missing_lock_rc=0
missing_lock_out="$(sync_flags prod 2>&1)" || missing_lock_rc=$?
if [ "$missing_lock_rc" -eq 0 ] || ! grep -q 'Production requires src/uv.lock' <<< "$missing_lock_out"; then
    log_err "prod uvs must reject a missing lockfile with an actionable error."
fi
rm -rf "$prod_probe"
ok "Reproducibility inputs wired (APT snapshot, SOURCE_DATE_EPOCH, GPG pin)."

# =============================================================================
# [prod-entrypoint] Production entrypoint contract
# =============================================================================
# Both refusals, by exit code as well as message: this is PID 1 of the shipped
# artifact, so a supervisor reads the code, and the house convention is 1 for a
# failure and 2 for a usage error (not the sysexits values it once returned).
group
prod_rc=0
prod_out="$(WORKSPACE_PATH="/workspace/nonexistent_path_test" docker/prod_entrypoint.sh true 2>&1)" || prod_rc=$?
{ [ "$prod_rc" -eq 1 ] && grep -q "Workspace path does not exist" <<< "$prod_out"; } \
    || log_err "prod_entrypoint.sh must exit 1 and say so on a missing workspace (got ${prod_rc}: ${prod_out%%$'\n'*})."
prod_rc=0
prod_out="$(env -u APP_COMMAND -u ROS_LAUNCH_COMMAND WORKSPACE_PATH="$ROOT_DIR" \
    docker/prod_entrypoint.sh 2>&1)" || prod_rc=$?
{ [ "$prod_rc" -eq 2 ] && grep -q "No production command configured" <<< "$prod_out"; } \
    || log_err "prod_entrypoint.sh must exit 2 when no command is configured (got ${prod_rc}: ${prod_out%%$'\n'*})."
ok "Production entrypoint refuses a missing workspace (1) and a missing command (2)."

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
# Every KEY= the completion offers must be consumed somewhere. An advertised
# switch that does nothing is worse than no completion at all: it reads as a
# documented feature. Extracted from the opts= strings only, so the script's own
# local variables do not count as knobs.
dead_knobs=""
for knob in $(grep -oE 'opts="[^"]*"' config/devkit_make_completion.bash \
              | grep -oE '[A-Z][A-Z0-9_]+=' | tr -d '=' | sort -u); do
    # Anchored to CODE, and neither .env.example nor this very completion
    # script counts: a knob named only in a comment there vouched for itself.
    grep -rqE "^[^#]*(^|[^A-Za-z0-9_])${knob}([^A-Za-z0-9_]|$)" \
        --exclude=devkit_make_completion.bash --exclude=verify_repo.sh \
        Makefile scripts/ config/ docker-compose.common.yml docker-compose.dev.yml docker/Dockerfile \
        || dead_knobs="${dead_knobs} ${knob}"
done
# The other direction, and the VALUES: completion offered GPU_MODE without
# intel/amd (which the Makefile accepts) and a SLURM time of 01:00:00 where the
# script and .env.example both say 02:00:00 — tab-accepting halved the job's
# documented wall clock.
comp_opts="$(grep -oE 'opts="[^"]*"' config/devkit_make_completion.bash | tr ' ' '\n')"
for comp_mode in auto nvidia igpu intel amd cpu; do
    grep -qF "GPU_MODE=${comp_mode}" <<< "$comp_opts" \
        || { log_err "tab completion does not offer GPU_MODE=${comp_mode}, which the Makefile accepts."; dead_knobs="${dead_knobs} GPU_MODE=${comp_mode}"; }
done
comp_time="$(grep -oE 'DEVKIT_SLURM_TIME=[0-9:]+' config/devkit_make_completion.bash | head -n 1 | cut -d= -f2)"
comp_sbatch="$(sed -n 's/^#SBATCH --time=//p' scripts/slurm_run.sh | head -n 1)"
[ "$comp_time" = "$comp_sbatch" ] \
    || { log_err "tab completion offers DEVKIT_SLURM_TIME=${comp_time} while the script default is ${comp_sbatch}."; dead_knobs="${dead_knobs} DEVKIT_SLURM_TIME"; }
# Every knob a SCRIPT reads must be declared in .env.example, or `make check`
# (which diffs .env against it) cannot see it and `make setup` never offers it.
for comp_knob in DEVKIT_SLURM_EXTRA_ARGS DEVKIT_VERIFY_SIF_HASH DEVKIT_REPO_ROOT \
                 APT_SNAPSHOT_FALLBACK DEVKIT_REQUIRE_PINNED DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET; do
    grep -qE "^#? ?${comp_knob}=" .env.example \
        || { log_err "${comp_knob} is read by a script but not declared in .env.example; 'make check' cannot see it."; dead_knobs="${dead_knobs} ${comp_knob}"; }
done
# Registration is per CHECKOUT: matching the bare filename made a second clone
# report "already registered" while the entry pointed at the first tree, so
# completion was silently dead there.
# pwd -P: the script records the checkout it was run from physically, and on a
# host whose TMPDIR is a symlink (macOS: /var → /private/var) the unresolved
# probe path never matched what .bashrc then held.
comp_home="$(cd "$(probe_dir)" && pwd -P)"; mkdir -p "$comp_home/ck1/config" "$comp_home/ck2/config" "$comp_home/home"
cp config/devkit_make_completion.bash "$comp_home/ck1/config/"; cp config/devkit_make_completion.bash "$comp_home/ck2/config/"
: > "$comp_home/home/.bashrc"
( HOME="$comp_home/home" bash "$comp_home/ck1/config/devkit_make_completion.bash" --install ) >/dev/null 2>&1 || true
comp_second="$( HOME="$comp_home/home" bash "$comp_home/ck2/config/devkit_make_completion.bash" --install 2>&1 || true )"
grep -q 'Registered' <<< "$comp_second" \
    || { log_err "a second checkout reports completion already registered while the entry points at the first tree (got: ${comp_second##*$'\n'})."; dead_knobs="${dead_knobs} completion-path"; }
[ "$(grep -cF "$comp_home/ck2" "$comp_home/home/.bashrc")" = 1 ] \
    || { log_err "registering from a second checkout did not add its own path to .bashrc."; dead_knobs="${dead_knobs} completion-entry"; }
rm -rf "$comp_home"
[ -z "$dead_knobs" ] \
    && log_ok "Tab completion advertises no dead knobs, offers every accepted value, and every script knob is declared." \
    || log_err "tab completion offers knobs nothing consumes:${dead_knobs}"

# =============================================================================
# [vscode-json] VS Code JSON: no shell default expansion ${VAR:-default}
# =============================================================================
group
if grep -rqE '\$\{[A-Za-z_][A-Za-z0-9_]*:-' .vscode .devcontainer 2>/dev/null; then
    log_err "VS Code JSON files must not use \${VAR:-default} shell expansion (VS Code treats it as substitution):"
    grep -rE '\$\{[A-Za-z_][A-Za-z0-9_]*:-' .vscode .devcontainer 2>/dev/null | sed 's/^/    /' >&2
fi
# ${env:WS_*} resolves to NOTHING in the IDE: util_paths.sh exports those into a
# *sourced shell*, which the VS Code server process is not — so every such
# reference became a path rooted at "/" ("/compile_commands.json", "/bin/python",
# a sourceFileMap key of "/src"). ${workspaceFolder} is always defined; only the
# REMOTE→local mappings use ${env:WORKSPACE_PATH}, which compose exports.
# JSONC comment lines are excluded — the note above is written in one.
stray_ide_env="$(grep -rn '\${env:WS_' .vscode .devcontainer 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
[ -z "$stray_ide_env" ] \
    || log_err "IDE config reads \${env:WS_*}, which is never set in the IDE process: $(cut -d: -f1,2 <<< "$stray_ide_env" | tr '\n' ' ')"
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
    || log_err "IDE tasks invoke shell symbols that no longer exist:${ide_missing}"
# A setting must live in ONE file. devcontainer customizations are injected as
# remote settings, which .vscode/settings.json then overrides — so a key present
# in both is a copy that can only ever go stale.
for ide_key in $(sed -n '/"settings": {/,/}/p' .devcontainer/devcontainer.json 2>/dev/null \
                 | grep -oE '"[A-Za-z_][A-Za-z0-9_.]*":' | tr -d '":'); do
    grep -q "\"${ide_key}\"" .vscode/settings.json \
        && log_err "'${ide_key}' is set in both .devcontainer/devcontainer.json and .vscode/settings.json."
done
# Each IntelliSense profile must be documented: docs/DEBUGGING.md tells the user
# which one to pick, and it still named a "Host (Bind Mount)" profile that had
# been renamed twice.
while IFS= read -r ide_profile; do
    [ -f docs/DEBUGGING.md ] || continue
    grep -qF "$ide_profile" docs/DEBUGGING.md \
        || log_err "IntelliSense profile '${ide_profile}' is not documented in docs/DEBUGGING.md."
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
    || log_err "launch.json name extraction collapsed ($(grep -c . <<< "$ide_launch_names") found)."
while IFS= read -r ide_launch; do
    [ -f docs/DEBUGGING.md ] || continue
    grep -qF "$ide_launch" docs/DEBUGGING.md \
        || log_err "debug configuration '${ide_launch}' is not documented in docs/DEBUGGING.md."
done <<< "$ide_launch_names"
# The debuggers' environment is the SOURCED workspace, not a copy: every launch
# reads .vscode/.debug.env (envFile) and carries no static env/environment
# block (colcon's per-package prefixes, ROS 1's devel/ and the GPU library
# path all drifted from the copies); every pre-launch task ends in mdebugenv,
# which writes that file; and no ${input:…} is defined without a reader or
# read without a definition (three dead inputs sat in these files).
ide_env_report="$(python3 - <<'PYIDE' 2>/dev/null || echo 'parse failed'
import json, re, pathlib
def load(p): return json.loads(re.sub(r'(?m)^\s*//.*$', '', pathlib.Path(p).read_text()))
launch, tasks = load('.vscode/launch.json'), load('.vscode/tasks.json')
task_by_label = {t['label']: t for t in tasks['tasks']}
bad = []
for c in launch['configurations']:
    if c.get('request') != 'launch': continue
    if c.get('envFile') != '${workspaceFolder}/.vscode/.debug.env': bad.append(f"{c['name']}: no envFile")
    if 'env' in c or 'environment' in c: bad.append(f"{c['name']}: static env block")
    pre = c.get('preLaunchTask')
    if not pre: bad.append(f"{c['name']}: no preLaunchTask (nothing writes .debug.env)")
    elif pre not in task_by_label: bad.append(f"{c['name']}: preLaunchTask '{pre}' is not a task")
    elif not task_by_label[pre]['command'].rstrip("'\" ").endswith('mdebugenv'): bad.append(f"task '{pre}' does not end in mdebugenv")
for name, doc in (('launch.json', launch), ('tasks.json', tasks)):
    defined = {i['id'] for i in doc.get('inputs', [])}
    used = set(re.findall(r'\$\{input:([A-Za-z]+)\}', pathlib.Path('.vscode/' + name).read_text()))
    for i in sorted(defined - used): bad.append(f"{name}: input '{i}' is defined but never read")
    for i in sorted(used - defined): bad.append(f"{name}: input '{i}' is read but not defined")
print('\n'.join(bad) if bad else 'ok')
PYIDE
)"
[ "$ide_env_report" = ok ] || log_err "IDE debug configuration: ${ide_env_report//$'\n'/; }"
# mdebugenv, executed: the file it writes is what envFile can read.
ide_env_probe="$(probe_dir config scripts)"; mkdir -p "$ide_env_probe/.vscode"
( cd "$ide_env_probe" && WORKSPACE_PATH="$ide_env_probe" bash -c 'source config/util_aliases.sh >/dev/null 2>&1; mdebugenv' ) >/dev/null 2>&1 || true
{ grep -qE '^PATH=' "$ide_env_probe/.vscode/.debug.env" && ! grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=' "$ide_env_probe/.vscode/.debug.env"; } \
    || log_err "mdebugenv did not write a KEY=VALUE .vscode/.debug.env with PATH in it."
rm -rf "$ide_env_probe"
grep -qE '^[[:space:]]+mkbuild$' config/util_aliases.sh \
    || log_err "mksync no longer builds through mkbuild; the IDE pre-launch and mksync would dispatch differently."
# The paths in the IDE contract must be the ones colcon's ISOLATED layout
# writes (cbuild passes no --merge-install): install/include and
# install/lib/python3/dist-packages never exist, so IntelliSense and the
# interpreter resolved nothing.
grep -q 'install/include' .vscode/c_cpp_properties.json \
    && log_err ".vscode/c_cpp_properties.json points at install/include, which the isolated colcon layout never creates (install/<pkg>/include)."
grep -q 'install/lib/python3/dist-packages' .vscode/settings.json \
    && log_err ".vscode/settings.json points at install/lib/python3/dist-packages, which neither ROS 2 isolated nor ROS 1 devel/ creates."
# The rendered file Dev Containers reads must have its service ENABLED: compose
# `config` keeps the profiles key (with 'abstract' from the base anchor), and
# the client then failed with "no service selected".
grep -q 'pop("profiles"' Makefile \
    || log_err "ide-config does not strip the profiles key; the generated compose file enables no service and Dev Containers cannot start it."
if docker_live && [ -f .docker_cache/ide.compose.json ]; then
    ide_svc="$(docker compose -f .docker_cache/ide.compose.json config --services 2>/dev/null | head -n 1 || true)"
    [ -n "$ide_svc" ] \
        || log_err ".docker_cache/ide.compose.json enables no service; 'Reopen in Container' fails with 'no service selected'."
fi
# The editor's own formatter must agree with the files it will reformat.
ide_json_indent="$(awk '/^\[\*\.\{json,json5\}\]/{f=1;next} f && /^indent_size/{print $3; exit}' .editorconfig)"
ide_real_indent="$(awk '/^ *"/{match($0,/^ */); print RLENGTH; exit}' .vscode/settings.json)"
[ "$ide_json_indent" = "$ide_real_indent" ] \
    || log_err ".editorconfig declares indent_size ${ide_json_indent} for json while the tracked .vscode files use ${ide_real_indent}; format-on-save rewrites the shared IDE contract."
for ide_script in $(grep -ohE '(WS_SCRIPTS\}?|scripts)/[A-Za-z0-9_]+\.sh' .vscode/*.json .devcontainer/*.json 2>/dev/null \
                    | sed 's|.*/||' | sort -u); do
    [ -f "scripts/${ide_script}" ] \
        || log_err "IDE tasks reference scripts/${ide_script}, which does not exist."
done
ok "VS Code / devcontainer JSON: no shell expansion, every invoked symbol and script resolves."

# =============================================================================
# [template-version] A fork must be able to tell where it started: VERSION
#      travels with the files (the template button copies no git history) and a
#      baked artifact's manifest names it. What CHANGED is the git history —
#      the annotated tags and the log between them — not a hand-synced copy.
# =============================================================================
group
devkit_version="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
printf '%s' "$devkit_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || log_err "VERSION must hold a single semantic version (got: '${devkit_version:-empty/missing}')."
# VERSION is the ONLY place the template version is written: everything else
# derives it (make from the file, the manifest from the environment), so the
# pieces cannot disagree by construction. src/ is exempt — a fork's
# src/pyproject.toml carries its OWN application version.
# README and docs/ are the fork's to rewrite, and its own release number may
# well coincide, so the scan covers the kit's files and, upstream, its prose.
# Only with a version to look for: an absent or empty VERSION turns this into a
# grep for "", which matched every line of every scanned file.
[ -n "$devkit_version" ] || devkit_version="__devkit_version_unset__"
hardcoded_version="$(grep -rn --fixed-strings "$devkit_version" \
    Makefile config scripts docker docker-compose.common.yml \
    docker-compose.dev.yml .env.example .github \
    $(upstream_checks && echo README.md docs) 2>/dev/null || true)"
[ -z "$hardcoded_version" ] \
    || log_err "the template version is hardcoded outside VERSION: $(cut -d: -f1,2 <<< "$hardcoded_version" | tr '\n' ' ')"
# Asserted by EXECUTION: the manifest is what a deployed artifact carries, and
# the value reaches it through a file the builder stages must actually copy.
version_probe="$(probe_dir)"
if bash scripts/util_release_metadata.sh "$version_probe/r.json" >/dev/null 2>&1; then
    # Separator-agnostic: the generator emits compact JSON.
    grep -qE "\"devkit_version\": ?\"${devkit_version}\"" "$version_probe/r.json" \
        || log_err "the release manifest does not record devkit_version=${devkit_version} (a baked artifact cannot name its template)."
    # The unpinnable layers are made auditable by recording what landed: on a
    # host with dpkg the apt manifest must exist, be non-empty and be counted.
    if command -v dpkg-query >/dev/null 2>&1; then
        { [ -s "$version_probe/devkit-apt-manifest.txt" ] && grep -qE '"apt_packages":[1-9]' "$version_probe/r.json"; } \
            || log_err "the release manifest records no APT package list; an unpinnable rosdep layer could not be audited after the fact."
    fi
else
    log_err "scripts/util_release_metadata.sh failed; a baked artifact would ship without a manifest."
fi
rm -rf "$version_probe"
# …and the builder stages must put VERSION where that script looks, or every
# shipped manifest says "unknown".
awk '
    /AS prod-builder$/        {inside=1}
    inside && /^FROM / && !/AS prod-builder$/ {inside=0}
    inside && /^COPY VERSION/ {found=1}
    END {exit found ? 0 : 1}' docker/Dockerfile \
    || log_err "docker/Dockerfile: prod-builder does not COPY VERSION; the release manifest would say devkit_version=unknown."
ok "Template revision ${devkit_version} is recorded in VERSION and in the release manifest."

# =============================================================================
# [adopt] `make adopt` hands a fork the identity it owns. It edits tracked files,
#      so it must be surgical: a bare `sed s/^name = /` also renamed the
#      [[tool.uv.index]] entries and left [tool.uv.sources] pointing at indexes
#      that no longer existed.
# =============================================================================
group
# Recipe comment lines (\t@#) dropped: the explanation below mentions
# [project] and would satisfy the grep on its own.
adopt_recipe="$(awk '/^adopt:/{inside=1} inside && /^[a-z]/ && !/^adopt:/{inside=0} inside' Makefile \
                | grep -v $'^\t@#')"
grep -q '\[project\]' <<< "$adopt_recipe" \
    || log_err "'make adopt' does not scope its pyproject edit to the [project] table."
# `make setup` rewrites .devcontainer/devcontainer.json to the host's service,
# so the documented order (setup, then adopt) refused on every non-cpu host.
grep -qF 'grep -v ' <<< "$(awk '/^adopt:/{i=1} i && /git status --porcelain/{print} /^$/{if(i)i=0}' Makefile)" \
    || log_err "'make adopt' treats the devcontainer.json that 'make setup' rewrites as an unclean tree; the documented order cannot be followed."
# tomllib is 3.11+: an older interpreter must not report "not valid TOML".
grep -q 'except ImportError' <<< "$(grep -A2 'tomllib' Makefile)" \
    || log_err "'make adopt' requires python 3.11 (tomllib) and reports its absence as invalid TOML."
# The lock names the project too, and `uv sync --locked` refuses one that names
# another: adopt must rename its virtual entry, or the first production build
# after an adoption dies at the sync.
adopt_lock_probe="$(cd "$(probe_dir)" && pwd -P)"
cp Makefile "$adopt_lock_probe/"; mkdir -p "$adopt_lock_probe/src"
cp src/pyproject.toml src/uv.lock "$adopt_lock_probe/src/"
for adopt_link in config scripts docker dependencies; do ln -s "${ROOT_DIR}/${adopt_link}" "$adopt_lock_probe/${adopt_link}"; done
cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.gitignore" "$adopt_lock_probe/"
sed -i.bak 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=devkit-probe-lock/' "$adopt_lock_probe/.env.example"
rm -f "$adopt_lock_probe/.env.example.bak"
( cd "$adopt_lock_probe" && git init -q . && git add -A \
  && git -c user.email=probe@devkit -c user.name=probe commit -qm probe \
  && make adopt NAME=lockprobe DESC=probe ) >/dev/null 2>&1 || true
adopt_lock_name="$(awk '/^\[\[package\]\]$/{n=""} /^name = /{n=$0} /^source = \{ virtual/{print n; exit}' "$adopt_lock_probe/src/uv.lock" 2>/dev/null || true)"
[ "$adopt_lock_name" = 'name = "lockprobe"' ] \
    || log_err "'make adopt' leaves src/uv.lock naming the old project (${adopt_lock_name:-nothing}); 'uv sync --locked' in the production build refuses it."
rm -rf "$adopt_lock_probe"
grep -q 'origin NAME' Makefile \
    || log_err "'make adopt' trusts an inherited NAME; the environment carries one (WSL exports NAME=<hostname>)."
# By message, not by code: make turns EVERY recipe failure into exit 2, so an
# exit-code assertion here passed whatever the recipe did.
adopt_usage="$(make adopt 2>&1 || true)"
grep -q 'Usage: make adopt NAME=' <<< "$adopt_usage" \
    || log_err "'make adopt' without NAME does not print its usage line (got: ${adopt_usage%%$'\n'*})."
# Every index [tool.uv.sources] names must exist — this is what a sloppy rename
# breaks, and uv fails only later, at sync time.
# …and the shipped default must already satisfy the rule adopt enforces: a fork
# that never runs adopt still has to `uv sync`.
uv_index_ok="$(DEVKIT_UPSTREAM_CHECKS="$(upstream_checks && echo 1 || echo 0)" python3 - <<'PYINDEX' 2>/dev/null || true
import os, re, tomllib, pathlib
upstream = os.environ.get('DEVKIT_UPSTREAM_CHECKS') == '1'
d = tomllib.loads(pathlib.Path('src/pyproject.toml').read_text())
uv = d.get('tool', {}).get('uv', {})
index = {i['name'] for i in uv.get('index', [])}
refs = {e['index'] for v in uv.get('sources', {}).values() for e in v if 'index' in e}
name = d.get('project', {}).get('name', '')
if refs - index:
    print(f"[tool.uv.sources] names a missing index: {sorted(refs - index)}")
elif not re.fullmatch(r'[a-z0-9][a-z0-9_-]*', name):
    print(f"[project] name '{name}' fails the rule 'make adopt' enforces")
elif 'build-system' in d:
    print("a [build-system] makes `uv sync` build src/ as a wheel; there is no package there to build")
elif uv.get('package') is not False:
    print("[tool.uv] package is not declared false; whether src/ is installed as a package is left to inference")
elif upstream and (d.get('project', {}).get('optional-dependencies') or uv.get('index') or uv.get('sources')):
    print("the template declares optional-dependencies / uv indexes for real; the torch split is a commented example so no fork pays for a resolution it did not ask for")
elif upstream and not re.search(r'(?m)^# \[project\.optional-dependencies\]', pathlib.Path('src/pyproject.toml').read_text()):
    print("the commented optional-dependencies example is gone; docs/DEPENDENCIES.md still points at it")
else:
    # The example, uncommented the way the docs say, must be one valid TOML
    # document: a second [tool.uv] header in the example once broke the parse.
    text = pathlib.Path('src/pyproject.toml').read_text()
    inside = False; lines = []
    for line in text.splitlines():
        if line.startswith('# --- opt-in example: begin'): inside = True; continue
        if line.startswith('# --- opt-in example: end'):   inside = False; continue
        if inside or line.startswith('# conflicts = '):
            lines.append(line[2:] if line.startswith('# ') else ('' if line == '#' else line))
        else:
            lines.append(line)
    try:
        ex = tomllib.loads("\n".join(lines))
    except tomllib.TOMLDecodeError as e:
        print(f"the opt-in example does not parse once uncommented: {e}"); raise SystemExit
    exuv = ex.get('tool', {}).get('uv', {})
    exidx = {i['name'] for i in exuv.get('index', [])}
    exrefs = {e['index'] for v in exuv.get('sources', {}).values() for e in v if 'index' in e}
    if not ex.get('project', {}).get('optional-dependencies'):
        print("the uncommented example declares no optional-dependencies")
    elif exrefs - exidx or not exuv.get('conflicts'):
        print(f"the uncommented example is inconsistent (indexes {sorted(exrefs - exidx)} missing, conflicts {'present' if exuv.get('conflicts') else 'absent'})")
    else:
        print('ok')
PYINDEX
)"
[ "$uv_index_ok" = "ok" ] \
    || log_err "src/pyproject.toml: ${uv_index_ok}."
grep -q 'name = "torch"' src/uv.lock 2>/dev/null \
    && log_err "src/uv.lock still resolves torch; the lock was not regenerated after the extras became an example."
# The description is user text. Spliced straight into a TOML basic string, a
# quote produced description = "Robot "A"" — and adopt reported success.
adopt_probe="$(make_probe)"
mkdir -p "$adopt_probe/src"

cp "${ROOT_DIR}/src/pyproject.toml" "$adopt_probe/src/"
# .env comes from make_probe: the probe's own identity, not this repository's.
adopt_desc_case() {   # adopt_desc_case <description>
    cp "${ROOT_DIR}/src/pyproject.toml" "$adopt_probe/src/pyproject.toml"
    ( cd "$adopt_probe" && make adopt NAME=robot DESC="$1" ) >/dev/null 2>&1 || true
    python3 - "$adopt_probe/src/pyproject.toml" "$1" <<'PYADOPT' 2>/dev/null
import sys, tomllib
want = sys.argv[2]
got = tomllib.load(open(sys.argv[1], "rb"))["project"]["description"]
raise SystemExit(0 if got == want else 1)
PYADOPT
}
for adopt_desc in 'Robot "A"' "It's a robot" 'back\slash' '한글 설명'; do
    adopt_desc_case "$adopt_desc" \
        || log_err "'make adopt DESC=${adopt_desc}' does not survive a TOML round-trip; the identity file is corrupt."
done
# The committed default follows EVERY adopt, not only the first: matching the
# literal 'myproject' left .env.example naming the previous adoption.
( cd "$adopt_probe" && make adopt NAME=robot2 DESC=second ) >/dev/null 2>&1 || true
adopt_names="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$adopt_probe/.env" "$adopt_probe/.env.example" | sort -u | tr '\n' ' ')"
[ "$adopt_names" = "robot2 " ] \
    || log_err "a second 'make adopt' leaves a stale COMPOSE_PROJECT_NAME behind (.env and .env.example say: ${adopt_names}); the committed default names the previous adoption."
# …and nothing unparsable may be published. Fed a pyproject that is already
# broken, adopt must refuse and leave the file it was given untouched.
# Broken where adopt does NOT rewrite, so the damage survives into the output.
printf '[project]\nname = "x"\ndescription = "d"\nthis line is not toml\n' > "$adopt_probe/src/pyproject.toml"
adopt_before="$(cat "$adopt_probe/src/pyproject.toml")"
( cd "$adopt_probe" && make adopt NAME=robot DESC=fine ) >/dev/null 2>&1 || true
[ "$(cat "$adopt_probe/src/pyproject.toml")" = "$adopt_before" ] \
    || log_err "adopt published a pyproject.toml that does not parse; a half-written identity file is worse than none."
[ ! -f "$adopt_probe/src/pyproject.toml.tmp" ] \
    || log_err "adopt leaves src/pyproject.toml.tmp behind when it refuses."
rm -rf "$adopt_probe"
ok "Adoption is surgical (scoped pyproject edit, explicit NAME, uv indexes intact, description survives quoting)."

# =============================================================================
# [style-config] One declared style. Neither ruff nor clang-format reads
#      .editorconfig, so format-on-save wrapped Python at 88 and C++ at 80
#      against the rulers in the same window. Assert the three agree.
# =============================================================================
group
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
    || log_err ".editorconfig parse yielded no widths (py='${ec_py}' cpp='${ec_cpp}' indent='${ec_cpp_indent}')."
# The WIDTHS are the fork's to choose; what must hold is that the two files
# agree, so format-on-save and the linter cannot fight.
ruff_cols="$(grep -oE '^line-length[[:space:]]*=[[:space:]]*[0-9]+' src/pyproject.toml | grep -oE '[0-9]+' || true)"
[ "${ruff_cols:-}" = "$ec_py" ] \
    || log_err "ruff line-length is '${ruff_cols:-unset}' but .editorconfig says ${ec_py} — format-on-save fights the declared style."
clang_cols="$(grep -oE '^ColumnLimit:[[:space:]]*[0-9]+' .clang-format 2>/dev/null | grep -oE '[0-9]+' || true)"
[ "${clang_cols:-}" = "$ec_cpp" ] \
    || log_err ".clang-format ColumnLimit is '${clang_cols:-unset/missing}' but .editorconfig says ${ec_cpp}."
clang_indent="$(grep -oE '^IndentWidth:[[:space:]]*[0-9]+' .clang-format 2>/dev/null | grep -oE '[0-9]+' || true)"
[ "${clang_indent:-}" = "$ec_cpp_indent" ] \
    || log_err ".clang-format IndentWidth is '${clang_indent:-unset/missing}' but .editorconfig says ${ec_cpp_indent}."
# The rulers a developer sees must be exactly those two limits.
for style_col in "$ec_py" "$ec_cpp"; do
    grep -qE "\"editor.rulers\": \[[^]]*\b${style_col}\b" .vscode/settings.json \
        || log_err "editor.rulers does not include ${style_col}, the width .editorconfig declares."
done
ok "Style config agrees across .editorconfig, ruff, clang-format and the editor rulers (py ${ec_py}, c++ ${ec_cpp})."

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
# [sif-contract] SIF pipeline: build args forwarded, inputs rejected loudly.
# =============================================================================
# Pins real failures: bake dropping CUDA_VERSION, bake swallowing a typo'd flag,
# the CUDA repo helper degrading to a stub.
group
# What a prod bake hands docker, captured from a stub: CUDA_VERSION must ride
# along (a SIF baked on a GPU host once shipped without CUDA), and the flavour
# must select the single parameterised chain (prod-runtime + PROD_ENV).
sif_argv="$(bake_argv prod ros CUDA_VERSION=12.4)"
grep -qxF 'CUDA_VERSION=12.4' <<< "$sif_argv" \
    || log_err "apptainer_bake.sh no longer forwards CUDA_VERSION — baked SIFs would silently ship without CUDA."
grep -qxF 'PROD_ENV=ros' <<< "$sif_argv" && grep -qxF 'prod-runtime' <<< "$sif_argv" \
    || log_err "a prod bake for ENV=ros does not build '--target prod-runtime --build-arg PROD_ENV=ros'."
# The SIF's CUDA footprint follows PROD_FULL_CUDA alone: FULL_CUDA is the dev
# image's knob and make exports it, so it used to shadow the SIF's own answer.
grep -qxF 'FULL_CUDA=false' <<< "$(bake_argv prod dev FULL_CUDA=true PROD_FULL_CUDA=false)" \
    || log_err "a bake lets the dev image's FULL_CUDA override PROD_FULL_CUDA=false."
grep -qxF 'FULL_CUDA=true' <<< "$(bake_argv prod dev FULL_CUDA=false PROD_FULL_CUDA=1)" \
    || log_err "PROD_FULL_CUDA=1 does not reach the bake as FULL_CUDA=true."
grep -qxF 'FULL_CUDA=false' <<< "$(bake_argv prod dev FULL_CUDA=true)" \
    || log_err "with PROD_FULL_CUDA unset a bake inherits FULL_CUDA=true instead of the documented default false."
# The dev snapshot is `COPY .`: what the kit itself generates beside the tree
# (catkin's devel/, the bake's own *.oci.tar) must not ride into the next
# snapshot. Statically, and against a real build context where docker runs.
for ctx_pat in '**/devel/' '**/build/' '**/.docker_cache/' '.claude/' '*.oci.tar' '!dependencies/*.tar.gz'; do
    grep -qxF "$ctx_pat" .dockerignore \
        || log_err ".dockerignore lacks '${ctx_pat}': a dev snapshot would carry (or drop) it."
done
if docker_live; then
    ctx_probe="$(probe_dir)"; mkdir -p "$ctx_probe/devel" "$ctx_probe/dependencies" "$ctx_probe/src"
    cp .dockerignore "$ctx_probe/"; : > "$ctx_probe/devel/setup.bash"; : > "$ctx_probe/old.oci.tar"; : > "$ctx_probe/dependencies/dep.tar.gz"; : > "$ctx_probe/src/main.py"
    # NESTED copies of what the file claims to exclude: docker matches a bare
    # pattern against the context ROOT only, so a fork's src/app/.env and every
    # src/**/.venv and __pycache__ rode into the context and into the snapshot.
    mkdir -p "$ctx_probe/src/app/.venv/lib" "$ctx_probe/src/pkg/__pycache__" "$ctx_probe/src/app/build" \
             "$ctx_probe/src/.docker_cache" "$ctx_probe/.claude"
    : > "$ctx_probe/src/app/.env"; : > "$ctx_probe/src/app/.venv/lib/big.so"; : > "$ctx_probe/src/pkg/__pycache__/m.pyc"
    : > "$ctx_probe/src/pkg/n.swp"; : > "$ctx_probe/src/app/build/o.o"
    # A nested build output and per-user agent state (which can hold tokens):
    # `make bake-dev` is `COPY .`, and its artifact is handed to a cluster.
    : > "$ctx_probe/src/.docker_cache/x"; : > "$ctx_probe/.claude/settings.local.json"
    printf 'FROM busybox\nCOPY . /ctx\nCMD find /ctx -type f\n' > "$ctx_probe/Dockerfile"
    ctx_files="$( (docker build -q -t devkit-verify-ctx-$$ "$ctx_probe" >/dev/null 2>&1 && docker run --rm devkit-verify-ctx-$$ 2>/dev/null; docker rmi -f devkit-verify-ctx-$$ >/dev/null 2>&1) | grep -vE '^/ctx/(Dockerfile|\.dockerignore)$' | sort | tr '\n' ' ')"
    [ "$ctx_files" = "/ctx/dependencies/dep.tar.gz /ctx/src/main.py " ] \
        || log_err "a real build context with this .dockerignore holds '${ctx_files}' (expected only dependencies/dep.tar.gz and src/main.py)."
    rm -rf "$ctx_probe"
fi
# A DIRECT script call must read the same two layers make renders: every knob
# below was silently dropped, so a CUDA_VERSION or ROS_SNAPSHOT_DATE set in
# .env produced an artifact without it and the host's own LANG/TZ leaked in.
bake_env_probe="$(cd "$(probe_dir config scripts docker dependencies src)" && pwd -P)"
cp "${ROOT_DIR}/.env.example" "$bake_env_probe/"
printf 'CUDA_VERSION=12.8.0\nROS_SNAPSHOT_DATE=2026-01-01\nIMAGE_TAG=rel1\n' > "$bake_env_probe/.env"
mkdir -p "$bake_env_probe/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 1\n' "$bake_env_probe" > "$bake_env_probe/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$bake_env_probe/bin/apptainer"
chmod +x "$bake_env_probe/bin/docker" "$bake_env_probe/bin/apptainer"
( cd "$bake_env_probe" && env -u CUDA_VERSION -u ROS_SNAPSHOT_DATE -u IMAGE_TAG -u LANG -u TZ \
  PATH="$bake_env_probe/bin:$probe_min_path" WORKSPACE_PATH="$bake_env_probe" \
  bash scripts/apptainer_bake.sh --mode prod --env ros ) >/dev/null 2>&1 || true
bake_env_argv="$(tr '\n' ' ' < "$bake_env_probe/argv" 2>/dev/null || echo '<docker never called>')"
for bake_env_want in CUDA_VERSION=12.8.0 ROS_SNAPSHOT_DATE=2026-01-01 IMAGE_TAG=rel1 LANG=C.UTF-8 TZ=UTC; do
    case " $bake_env_argv " in
        *" $bake_env_want "*) ;;
        *) log_err "a direct apptainer_bake.sh call drops '${bake_env_want}' (argv: ${bake_env_argv})." ;;
    esac
done
rm -rf "$bake_env_probe"
# The two long steps run through sif_run_and_record, which forwards TERM/INT/HUP
# and waits: a signal to the bake alone left apptainer building into a temp file
# the EXIT trap had already deleted, and it reappeared minutes later.
grep -qE '^[^#]*sif_run_and_record "\$RUNTIME" build' scripts/apptainer_bake.sh \
    || log_err "apptainer_bake.sh runs the SIF conversion outside sif_run_and_record; a TERM orphans the build."
# Both artifacts are published readable: mktemp makes 0600 and `docker save -o`
# reuses that inode, so the archive whose whole purpose is to be handed on was
# private to the baking user.
grep -c 'chmod 644' scripts/apptainer_bake.sh | grep -qx 2 \
    || log_err "apptainer_bake.sh does not publish both the .sif and the .oci.tar readable (mktemp leaves them 0600)."
grep -qxF 'PROD_ENV=dev' <<< "$(bake_argv prod dev)" \
    || log_err "a prod bake for ENV=dev does not pass PROD_ENV=dev; the ROS builder base would be used."
# …and every ENV the bake accepts needs its builder base, or `FROM
# builder-base-${PROD_ENV}` fails to resolve inside docker build.
for sif_env in $(sed -n 's/^sif_require_choice --env "\$ENV_NAME" \(.*\) || exit 2$/\1/p' scripts/apptainer_bake.sh); do
    grep -qE "^FROM .* AS builder-base-${sif_env}$" docker/Dockerfile \
        || log_err "docker/Dockerfile has no 'builder-base-${sif_env}' stage; 'make bake-prod ENV=${sif_env}' cannot resolve its FROM."
done
grep -qE '^FROM builder-base-\$\{PROD_ENV\} AS prod-builder$' docker/Dockerfile \
    || log_err "docker/Dockerfile: prod-builder no longer derives its base from PROD_ENV; the flavours would drift into two copies again."
# setup-cuda-repo needs the network and root; the images.yml apt job runs it.
grep -Eq '^[^#]*sources\.list\.d/cuda\.list' scripts/util_apt_helper.sh \
    || log_err "util_apt_helper.sh setup-cuda-repo no longer configures the NVIDIA repository."
# The managed interpreter must sit where ANY uid can traverse: a baked venv
# symlinks into it and Apptainer runs as the invoking user. Under /root (0700)
# PATH fell through to /usr/bin/python3 and the venv's packages vanished.
uv_python_dir="$(grep -oE '^ENV UV_PYTHON_INSTALL_DIR=[^[:space:]]+' docker/Dockerfile | head -1 | cut -d= -f2)"
case "${uv_python_dir:-}" in
    "")       log_err "docker/Dockerfile does not set UV_PYTHON_INSTALL_DIR; uv installs into the calling user's home, which no other uid can read." ;;
    /root/*)  log_err "UV_PYTHON_INSTALL_DIR is under /root (${uv_python_dir}); an Apptainer run as your own uid cannot traverse it." ;;
esac
grep -qE '^[^#]*/root/\.local/share/uv' docker/Dockerfile \
    && log_err "a Dockerfile stage still references /root/.local/share/uv — that path is unreachable for a non-root uid."
# Ownership is taken in the layer that INSTALLS the interpreter. A chown -R in
# a later stage rewrites the whole tree into a second ~90 MB layer (measured
# with docker history). Continuations joined, so one RUN is one line.
# Comment LINES dropped rather than '^[^#]*': the dev-core RUN carries a '#'
# inside a printf, which hid exactly the chown this looks for.
uv_chown_stray="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' docker/Dockerfile | grep -v '^[[:space:]]*#' \
    | grep -nE 'chown[^&]*/opt/uv' | grep -v 'uv python install' || true)"
[ -z "$uv_chown_stray" ] \
    || log_err "docker/Dockerfile chowns /opt/uv outside the layer that installs it, duplicating the interpreter layer: $(cut -d: -f1 <<< "$uv_chown_stray" | tr '\n' ' ')"
# …and the runtime stages must actually copy it from there, or the venv symlink
# in the shipped image points at nothing.
# Only where a venv resolves into it: the pure (dev) venv does; the ROS venv
# shares the system interpreter (mkenv forces --share under /opt/ros, verified
# in the image: install/.venv/bin/python3 -> /usr/bin/python3.10), so copying
# the tree into the ROS runtime shipped 90 MB nothing referenced.
uv_stage_copies() {   # uv_stage_copies <stage> — 0 when the stage COPYs the managed interpreter
    awk -v stage="$1" -v dir="${uv_python_dir:-/dev/null}" '
        $0 ~ "AS " stage        {inside=1}
        inside && /^FROM / && $0 !~ "AS " stage {inside=0}
        inside && /^COPY / && index($0, dir) {found=1}
        END {exit found ? 0 : 1}' docker/Dockerfile
}
uv_stage_copies prod-runtime \
    || log_err "docker/Dockerfile: prod-runtime does not copy ${uv_python_dir:-the managed interpreter}; the pure venv would symlink to a missing interpreter."
# …while the ROS flavour empties it in the builder before that COPY: a ROS venv
# shares the system interpreter (verified in the image), so shipping the tree
# was 90 MB nothing referenced.
awk '/AS prod-builder$/{inside=1} inside && /^FROM / && !/AS prod-builder$/{inside=0}
     inside && /PROD_ENV" = ros/ && /\/opt\/uv\/python/ && /-delete/ {found=1} END {exit found ? 0 : 1}' docker/Dockerfile \
    || log_err "docker/Dockerfile: prod-builder does not empty ${uv_python_dir} for PROD_ENV=ros; the ROS artifact would carry an interpreter its venv never uses."
# The runtime stage must END as a non-root uid: a root artifact is rejected by
# k8s runAsNonRoot, and the stage's last USER wins.
last_user="$(awk '/AS prod-runtime$/{inside=1} inside && /^FROM / && !/AS prod-runtime$/{inside=0}
                  inside && /^USER /{u=$2} END {print u}' docker/Dockerfile)"
case "$last_user" in
    ""|root|0) log_err "docker/Dockerfile: prod-runtime runs as ${last_user:-root} (no USER); k8s runAsNonRoot rejects it." ;;
esac
rc=0; bash scripts/apptainer_bake.sh --bogus-flag >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || log_err "apptainer_bake.sh must reject unknown flags with exit 2, not silently ignore them."
grep -Eq '^[^#]*source "/opt/ros/.*setup\.bash' scripts/check_deps.sh \
    || log_err "check_deps.sh no longer sources the ROS environment — prod ROS 1 builds would fail their binding check."
# Execution-based: a typo'd ENV must die in make's read phase, before any
# recipe — probed on `down`, the target where a wrong profile deletes volumes
# (and detector-exempt, so this probe has no host-detection side effect).
rc=0; env_probe="$(make -n down ENV=__bogus__ 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && grep -q "ENV must be" <<< "$env_probe"; } \
    || log_err "Makefile no longer rejects an invalid ENV on teardown — 'make down ENV=ros2' would remove the wrong profile's volumes."
# The CUDA pin's escape hatch: base stage must re-declare ARG STRICT_GPG_CHECK
# or the documented STRICT_GPG_CHECK=false override never reaches setup-cuda-repo.
awk '/^FROM .* AS base$/,/^FROM [^ ]* AS build-core$/' docker/Dockerfile | grep -q '^ARG STRICT_GPG_CHECK' \
    || log_err "Dockerfile base stage lost 'ARG STRICT_GPG_CHECK' — the documented escape hatch cannot reach setup-cuda-repo."
# A multi-word job command must reach the container as separate argv words (a
# "$*" join + bash -c re-parse would re-interpret metacharacters inside them).
# Against a stub runtime that records what it was handed.
argv_probe="$(probe_dir config scripts)"
mkdir -p "$argv_probe/bin"; : > "$argv_probe/a.sif"
printf '#!/bin/sh\ncase "$*" in *"test -x /entrypoint.sh"*) exit 0 ;; *grep*) exit 1 ;; esac\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 0\n' \
    "$argv_probe" > "$argv_probe/bin/apptainer"; chmod +x "$argv_probe/bin/apptainer"
( PATH="$argv_probe/bin:$probe_min_path" WORKSPACE_PATH="$argv_probe" SLURM_RUN_ROOT="$argv_probe/runs" \
  bash scripts/slurm_run.sh "$argv_probe/a.sif" python3 'a b' c ) >/dev/null 2>&1 || true
{ grep -qxF 'a b' "$argv_probe/argv" 2>/dev/null && grep -qxF 'c' "$argv_probe/argv"; } \
    || log_err "slurm_run.sh no longer hands a multi-word command to the runtime word for word (got: $(tr '\n' '|' < "$argv_probe/argv" 2>/dev/null))."
rm -rf "$argv_probe"
# Host/container path confusion: the Makefile exports WORKSPACE_PATH=/workspace
# to EVERY recipe, host-side ones included, so a script that trusts it resolves
# /workspace/scripts/... and dies — invisibly to every flag assertion above.
[ "$(WORKSPACE_PATH=/nonexistent-devkit bash -c 'source config/util_paths.sh; printf %s "$WS_ROOT"')" = "$ROOT_DIR" ] \
    || log_err "config/util_paths.sh trusts WORKSPACE_PATH even when it is not a DevKit tree here — host scripts resolve /workspace/..."
# `apptainer exec` skips the image ENTRYPOINT, so both run paths must route
# through it or the job starts with no ROS/venv (`import rclpy` failed).
# By EXECUTION against a stub runtime: the prefix differs per image, and a
# grep cannot tell whether that distinction survived.
sif_probe="$(probe_dir)"
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
    || log_err "sif_entry_args drops the dev entrypoint's --env wrapper; a SIF command loses the ROS environment."
[ "$(entry_probe 0)" = "/entrypoint.sh" ] \
    || log_err "sif_entry_args passes --env to a production entrypoint that does not accept it."
rm -rf "$sif_probe"
for sif_runner in scripts/apptainer_run.sh scripts/slurm_run.sh; do
    grep -qE '^[^#]*sif_entry_args' "$sif_runner" \
        || log_err "${sif_runner} no longer routes the command through /entrypoint.sh; a SIF run loses the ROS environment."
done
# One runtime resolution for bake, run and the job script: the copies drifted
# and run/slurm died with a bare "singularity: command not found".
for sif_caller in scripts/apptainer_bake.sh scripts/apptainer_run.sh scripts/slurm_run.sh; do
    grep -qE '^[^#]*sif_runtime' "$sif_caller" \
        || log_err "${sif_caller} resolves the apptainer/singularity binary itself instead of via sif_runtime."
done
# Same rule for the architecture tag: bake writes it into the filename and run
# probes for it, so a second uname translation would make run miss the artifact
# bake just produced. Asserted by EXECUTION against both spellings.
for sif_arch_probe in x86_64:amd64 aarch64:arm64 arm64:arm64; do
    [ "$(TARGETARCH="${sif_arch_probe%%:*}" bash -c 'source scripts/util_sif_common.sh; sif_arch')" \
      = "${sif_arch_probe##*:}" ] \
        || log_err "sif_arch does not normalise ${sif_arch_probe%%:*} to ${sif_arch_probe##*:}."
done
for sif_arch_caller in scripts/apptainer_bake.sh scripts/apptainer_run.sh; do
    grep -qE '^[^#]*sif_arch' "$sif_arch_caller" \
        || log_err "${sif_arch_caller} spells the architecture tag itself instead of using sif_arch; bake and run would disagree."
done
# slurm submits the PRODUCTION artifact (there is no bake --mode slurm): with
# no SIF_FILE, the default probe must find <project>-<env>-prod-<arch>.sif.
# Physical path: apptainer_run.sh canonicalises the artifact with `pwd`, and on
# macOS $TMPDIR is /var/… -> /private/var/…, so an unresolved probe path never
# matched what sbatch was handed.
slurm_art="$(cd "$(probe_dir config scripts)" && pwd -P)"
mkdir -p "$slurm_art/bin"; : > "$slurm_art/probe-dev-prod-amd64.sif"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$slurm_art" > "$slurm_art/bin/sbatch"; chmod +x "$slurm_art/bin/sbatch"
( PATH="$slurm_art/bin:$probe_min_path" WORKSPACE_PATH="$slurm_art" COMPOSE_PROJECT_NAME=probe TARGETARCH=amd64 \
  env -u SIF_FILE bash scripts/apptainer_run.sh --mode slurm --env dev 'true' ) >/dev/null 2>&1 || true
grep -qxF "$slurm_art/probe-dev-prod-amd64.sif" "$slurm_art/argv" 2>/dev/null \
    || log_err "SIF_MODE=slurm does not resolve the default artifact to the prod SIF (sbatch got: $(tr '\n' ' ' < "$slurm_art/argv" 2>/dev/null))."
rm -rf "$slurm_art"
# RUN_ARGS must survive make without a second round of shell parsing: the
# documented RUN_ARGS='python3 -c "print(1)"' produced an unbalanced-quote
# syntax error when it was passed as an argument instead of via the environment.
bash -n <<< "$(make -n run-sif RUN_ARGS='python3 -c "print(1)"' 2>/dev/null)" 2>/dev/null \
    || log_err "'make run-sif RUN_ARGS=...' emits invalid shell when RUN_ARGS contains quotes (pass it through the environment)."
sif_root_probe="$(SIF_FILE=/nonexistent.sif WORKSPACE_PATH=/nonexistent-devkit \
    bash scripts/apptainer_run.sh --mode prod --env ros 2>&1 || true)"
grep -q 'SIF artifact not found' <<< "$sif_root_probe" \
    || log_err "apptainer_run.sh cannot resolve the repository root when WORKSPACE_PATH points at the container: ${sif_root_probe%%$'\n'*}"
ok "SIF pipeline contract: build args forwarded, bad inputs rejected, CUDA repo wired."

# =============================================================================
# [security-defaults] Fail-closed GPG, unprivileged containers, TLS snapshot.
# =============================================================================
group
grep -Eq '^[^#]*STRICT_GPG_CHECK: \$\{STRICT_GPG_CHECK:-true\}' docker-compose.common.yml \
    || log_err "STRICT_GPG_CHECK compose default regressed to fail-open."
grep -Eq '^[^#]*privileged: \$\{PRIVILEGED:-false\}' docker-compose.common.yml \
    || log_err "PRIVILEGED compose default regressed to true (container escape is trivial when privileged)."
# Universal, not existential: ANY http:// snapshot mirror line is a regression
# (a single reverted sed line still passed the old at-least-one-https check).
grep -Eq '^[^#]*http://snapshot\.ubuntu\.com' scripts/util_apt_helper.sh \
    && log_err "A snapshot mirror regressed to http:// (Check-Valid-Until is off — TLS is the only anti-rollback control)."
grep -Eq '^[^#]*NVIDIA_GPG_FINGERPRINT="[A-F0-9]{40}"' scripts/util_apt_helper.sh \
    || log_err "NVIDIA CUDA key fingerprint pin removed (TOFU regression)."
# Every stage that SHIPS must undo init-apt's cache retention: keep-cache only
# serves BuildKit cache mounts, and left in place a runtime `apt install` in the
# deployed image hoards .debs forever. One verb, asserted per stage.
grep -q '^    restore-docker-clean)' scripts/util_apt_helper.sh \
    || log_err "util_apt_helper.sh no longer offers restore-docker-clean; the shipped stages have nothing to call."
# …and must drop the bootstrap tools `base` installed (init-apt: curl, gnupg,
# lsb-release) — through purge-bootstrap, which spares what an installed
# package still depends on. A bare `purge -y curl … lsb-release` took
# ros-*-libcurl-vendor and python3-rospkg with it; the ROS runtime once purged
# 'gnupg2', a name never installed, and the dev runtime purged nothing.
awk '/AS prod-runtime$/{inside=1} inside && /^FROM / && !/AS prod-runtime$/{inside=0}
     inside && /purge-bootstrap/{found=1} END {exit found ? 0 : 1}' docker/Dockerfile \
    || log_err "docker/Dockerfile: prod-runtime does not call 'util_apt_helper.sh purge-bootstrap'; curl and gnupg would ship."
grep -qE '^[^#]*apt-get purge[^#]*(curl|gnupg|lsb-release)' docker/Dockerfile \
    && log_err "docker/Dockerfile purges the bootstrap tools by name; purge-bootstrap must decide, or a dependent package goes with them."
# The decision itself, against stubs: curl has an installed dependent, the
# rest do not — so apt-get must be asked for gnupg/dirmngr/lsb-release only.
purge_probe="$(probe_dir)"
printf '#!/bin/sh\necho ii\n' > "$purge_probe/dpkg-query"
printf '#!/bin/sh\nfor a; do :; done\nprintf "%%s\\nReverse Depends:\\n" "$a"\n[ "$a" != curl ] || echo "  ros-humble-libcurl-vendor"\n' > "$purge_probe/apt-cache"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$purge_probe" > "$purge_probe/apt-get"
chmod +x "$purge_probe/dpkg-query" "$purge_probe/apt-cache" "$purge_probe/apt-get"
# …and what the runtime manifest requested by name (`gnupg # runtime` here —
# an app's own call to it is a dependency apt cannot see) is kept even with no
# reverse dependency. The ROS distro selects apt_ros.txt as it does for install.
mkdir -p "$purge_probe/deps"
printf 'gnupg # runtime\nlsb-release # dev\n' > "$purge_probe/deps/apt.txt"
printf 'dirmngr=1.0 # runtime ros2\n' > "$purge_probe/deps/apt_ros.txt"
( PATH="$purge_probe:$probe_min_path" DEVKIT_DEPS_DIR="$purge_probe/deps" \
  bash scripts/util_apt_helper.sh purge-bootstrap humble ) >/dev/null 2>&1 || true
purge_argv="$(tr '\n' ' ' < "$purge_probe/argv" 2>/dev/null || echo '<apt-get never called>')"
for purge_keep in curl gnupg dirmngr; do
    case " $purge_argv " in
        *" $purge_keep "*) log_err "purge-bootstrap purges '${purge_keep}' although an installed package depends on it or the runtime manifest requested it (argv: ${purge_argv})." ;;
    esac
done
case " $purge_argv " in
    *" lsb-release "*) ;;
    *) log_err "purge-bootstrap keeps 'lsb-release' although nothing depends on it and only '# dev' asked for it (argv: ${purge_argv})." ;;
esac
awk '/AS prod-runtime$/{inside=1} inside && /^FROM / && !/AS prod-runtime$/{inside=0}
     inside && /purge-bootstrap \$\{ROS_DISTRO\}/{found=1} END {exit found ? 0 : 1}' docker/Dockerfile \
    || log_err "docker/Dockerfile: the ROS prod-runtime does not pass ROS_DISTRO to purge-bootstrap; a '# runtime' entry in apt_ros.txt would not be spared."
rm -rf "$purge_probe"
# `make term` must probe with a binary the image actually ships: xset lives in
# x11-xserver-utils (not installed) and made the target report "no display" on a
# working X11 host. xdpyinfo comes from x11-utils, which the image does install.
grep -q 'xset q' Makefile \
    && log_err "'make term' probes X11 with xset, absent from the image (x11-xserver-utils); use xdpyinfo."
# …and it must open the window as the container user with the flag terminator
# has. It ran as root with `-u <config>` — -u is --no-dbus, the path became a
# positional argument and terminator exited before drawing; `docker exec -d`
# reports 0 for a detached process, so nothing ever said so.
term_dry_run="$(make -n term 2>/dev/null || true)"
term_recipe="$(grep -E 'docker exec -d' <<< "$term_dry_run" || true)"
[ -n "$term_recipe" ] && ! grep -qvE 'USER_FLAG' <<< "$term_recipe" \
    || log_err "'make term' launches a terminal without the EXEC_USER_FLAG the other attach targets use; every pane would be a root shell."
grep -qE 'terminator -g ' <<< "$term_recipe" && ! grep -qE 'terminator -u' <<< "$term_recipe" \
    || log_err "'make term' passes the terminator layout with a flag other than -g (-u is --no-dbus; a positional path aborts the launch)."
# terminator and its font are OPT-IN: offered in dependencies/apt.txt as a
# commented '# gui' line, absent from the Dockerfile, nothing fetched from
# GitHub into every image — and `make term` must probe for the binary and say
# how to opt in, since a detached exec cannot report a missing program.
grep -v '^[[:space:]]*#' docker/Dockerfile | grep -qE '(^|[[:space:]])terminator([[:space:]\\]|$)' \
    && log_err "docker/Dockerfile installs terminator into every dev image; it is opt-in through dependencies/apt.txt."
# Upstream only: DEPENDENCIES.md tells a fork to uncomment this very line.
! upstream_checks || grep -qE '^#? ?terminator # gui' dependencies/apt.txt \
    || log_err "dependencies/apt.txt no longer offers the 'terminator # gui' line; there is no way left to opt in."
grep -qE '^[^#]*curl [^#]*github\.com' docker/Dockerfile \
    && log_err "docker/Dockerfile downloads from GitHub into the image (the D2Coding font once did); fonts are opt-in via dependencies/."
# The probe must run INSIDE a shell: `command` is a builtin, and `docker exec
# <c> command -v x` exec'd it as a program — "not found" (127) in every image,
# so `make term` refused even with terminator installed. The exact probe the
# recipe uses is lifted from the dry run and executed in a real minimal
# container where one is available.
term_probe="$(sed -n "s/.*docker exec \$CONTAINER \(sh -c '[^']*' _\) \"\$TERM_BIN\".*/\1/p" <<< "$term_dry_run")"
[ -n "$term_probe" ] && grep -q 'dependencies/apt.txt' <<< "$term_dry_run" \
    || log_err "'make term' does not probe for the terminal binary through 'sh -c' and point at dependencies/apt.txt (found: '${term_probe:-no sh -c probe}')."
if [ -n "$term_probe" ] && docker_live; then
    eval "docker run --rm ubuntu:22.04 $term_probe bash" >/dev/null 2>&1 \
        || log_err "the 'make term' binary probe reports an installed program (bash) as missing in a real container."
    eval "docker run --rm ubuntu:22.04 $term_probe devkit-no-such-binary" >/dev/null 2>&1 \
        && log_err "the 'make term' binary probe reports a missing program as installed in a real container."
fi
grep -qE '(^|[[:space:]])x11-utils([[:space:]\\]|$)' docker/Dockerfile \
    || log_err "x11-utils dropped from the image; 'make term' has no way left to probe the display."
grep -Eq '^[^#]*for E in.*"local:' Makefile \
    && log_err "xhost 'local:' grant reintroduced — it admits EVERY local user, not just root."
# make setup writes the username into COMPOSE_PROJECT_NAME: without the tr
# sanitize, LDAP/AD names (John.Doe, LAB\user) break every compose invocation.
grep -Eq "^[^#]*tr -c 'a-z0-9_-'" Makefile \
    || log_err "make setup lost the username sanitize — non-[a-z0-9_-] usernames would break compose project naming."
# No script may fall back to sourcing a world-writable path: two did, with a
# /tmp/util_paths.sh that no image ever holds.
tmp_source="$(grep -nE '^[^#]*source +"?/tmp/' scripts/*.sh config/*.sh docker/*.sh 2>/dev/null | grep -v verify_repo.sh || true)"
[ -z "$tmp_source" ] \
    || log_err "a script sources a file under /tmp (world-writable, and absent from every image): $(cut -d: -f1,2 <<< "$tmp_source" | tr '\n' ' ')"
# mclean with no WS_ROOT (util_paths sourced '|| true' and failed) must stop
# before its first find/rm: a plain ${WS_ROOT} once turned it into rm -rf /build.
mclean_root="$(probe_dir)"
printf '#!/bin/sh\necho "$0 $*" >> "%s/calls"\n' "$mclean_root" > "$mclean_root/rm"
cp "$mclean_root/rm" "$mclean_root/find"; chmod +x "$mclean_root/rm" "$mclean_root/find"
mclean_root_rc=0
mclean_root_out="$(PATH="$mclean_root:$probe_min_path" bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1; unset WS_ROOT; mclean" 2>&1)" || mclean_root_rc=$?
{ [ "$mclean_root_rc" -ne 0 ] && grep -q 'WS_ROOT' <<< "$mclean_root_out" && [ ! -s "$mclean_root/calls" ]; } \
    || log_err "mclean with an empty WS_ROOT ran on (rc ${mclean_root_rc}, calls: $(tr '\n' ';' < "$mclean_root/calls" 2>/dev/null)); it would delete /build and /install."
rm -rf "$mclean_root"
# Empty-array "${arr[@]}" is fatal under set -u on bash < 4.4 — the RHEL 7/8
# bash SLURM nodes run. Guarded form is ${arr[@]+"${arr[@]}"}.
grep -nE '"\$\{(GPU_FLAGS|BIND_OPTS|SBATCH_OPTS)\[@\]\}"' scripts/slurm_run.sh scripts/apptainer_run.sh \
    | grep -qFv '[@]+' \
    && log_err "Unguarded empty-array expansion in the SLURM path — fatal under set -u on bash<4.4."
# Functional probe: --makefile emit must stay one 'KEY := value' line per key
# even when a host value carries a newline (else detected-env.mk is injectable).
nl_bad="$(WORKSPACE_PATH=$'x\ninjected' bash scripts/check_env.sh --makefile 2>/dev/null | grep -cvE '^[A-Z0-9_]+ := ' || true)"
[ "${nl_bad:-1}" -eq 0 ] \
    || log_err "check_env.sh --makefile emitted a non 'KEY := value' line — newline in a host value injects make code into the cache."
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
        log_err "a GPG fingerprint mismatch does NOT abort by default — the pin is decorative."
    elif ! grep -q FATAL <<< "$gpg_strict_out"; then
        log_err "a GPG fingerprint mismatch aborts without saying so (no FATAL line to diagnose)."
    fi
    gpg_probe false >/dev/null 2>&1 \
        || log_err "STRICT_GPG_CHECK=false no longer continues past a mismatch (documented escape hatch broken)."
fi
ok "Security defaults: fail-closed GPG pins, unprivileged containers, TLS snapshot, scoped xhost, guarded rm/arrays."

# =============================================================================
# [cli-convention] Every executed script answers --help with 0 and refuses an
#      unknown flag. `check_deps --help` once died with "Target directory
#      '--help' does not exist"; check_env.sh took a typo'd mode as its
#      default and cached a detected-env.mk make cannot parse.
# =============================================================================
group
cli_count=0
# Derived from the directory, not a hand-kept list: a new script that skips the
# convention has to be exempted here on purpose. Exempt are the sourced-only
# libraries (they define functions and never look at argv) and this script,
# which is checked below with a recursion guard.
for cli_path in scripts/*.sh; do
    case " $sourced_only " in *" ${cli_path##*/} "*) continue ;; esac
    cli_count=$((cli_count + 1))
    bash "$cli_path" --help >/dev/null 2>&1 \
        || log_err "${cli_path} does not answer --help with exit 0."
    # …and again with the CONTAINER path exported, because that is how `make`
    # runs every host-side script (WORKSPACE_PATH=/workspace is exported to all
    # recipes). A script that anchors itself on it instead of asking
    # config/util_paths.sh dies here with 127 or 1 — as two of them did.
    WORKSPACE_PATH=/nonexistent-devkit bash "$cli_path" --help >/dev/null 2>&1 \
        || log_err "${cli_path} --help fails when WORKSPACE_PATH points at the container; resolve the root through config/util_paths.sh."
    rc=0; bash "$cli_path" --devkit-bogus-flag >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
        || log_err "${cli_path} accepts an unknown flag silently — a typo would run the wrong mode."
done
# This script too, but only one level deep: DEVKIT_VERIFY_NESTED stops the child
# from spawning its own copy. Without the guard a regression in the flag check
# below would fork the whole suite recursively.
if [ -z "${DEVKIT_VERIFY_NESTED:-}" ]; then
    cli_count=$((cli_count + 1))
    rc=0; DEVKIT_VERIFY_NESTED=1 bash scripts/verify_repo.sh --devkit-bogus-flag >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
        || log_err "scripts/verify_repo.sh accepts an unknown flag silently — 'verify_repo.sh --fix' would report success for a request it ignored."
    bash scripts/verify_repo.sh --help >/dev/null 2>&1 \
        || log_err "scripts/verify_repo.sh does not answer --help with exit 0."
fi
# setup_gpu.sh is SOURCED by the `gpu` helper, so a rejected mode must leave the
# caller's shell untouched — validation has to precede the variable reset.
gpu_typo="$(bash --norc -c "WORKSPACE_PATH='${ROOT_DIR}' source config/util_aliases.sh >/dev/null 2>&1
    export LIBGL_ALWAYS_SOFTWARE=probe
    gpu devkit-bogus-mode >/dev/null 2>&1; printf '%s %s' \"\$?\" \"\${LIBGL_ALWAYS_SOFTWARE:-unset}\"" 2>/dev/null || true)"
[ "$gpu_typo" = "2 probe" ] \
    || log_err "'gpu <typo>' must exit 2 without resetting the shell's GPU variables (got: ${gpu_typo})."
ok "CLI convention holds (${cli_count} scripts: --help exits 0, unknown flags rejected)."

# =============================================================================
# [legacy-bash] The support matrix claims bash 3.2 (macOS, and the RHEL 7/8
#      SLURM login nodes): RUN the shared helpers and the host CLIs there, not
#      just `bash -n` them. Syntax passes on constructs whose behaviour differs,
#      and the macOS runner answers with whatever bash is first on its PATH.
# =============================================================================
# The class, checked statically first: five of these reached the macOS runner
# before anything noticed, each because a probe asked the HOST for a tool only
# GNU userland has. One table, over every file that runs on a host — this suite
# included, since its own probes are what kept breaking. The rule lines carry a
# tab, which is how they exclude themselves from their own scan.
# Container- and Linux-only libraries are out of scope: hwcheck and the shell
# helpers only ever run inside the image, the link setup with them, and
# check_wsl.sh only under WSL — all GNU userland by construction.
legacy_host_files="Makefile $(ls scripts/*.sh config/*.sh \
    | grep -vE 'check_hardware\.sh|util_aliases\.sh|util_setup_links\.sh|check_wsl\.sh' | tr '\n' ' ')"
while IFS="$(printf '\t')" read -r legacy_pat legacy_why; do
    [ -n "$legacy_pat" ] || continue
    legacy_hits="$(grep -nE "^[^#]*${legacy_pat}" $legacy_host_files 2>/dev/null | grep -v "$(printf '\t')" || true)"
    [ -z "$legacy_hits" ] \
        || log_err "host-side code uses ${legacy_why}: $(cut -d: -f1,2 <<< "$legacy_hits" | tr '\n' ' ')"
done <<'LEGACY_RULES'
sed.*\\[|+?]	GNU-only BRE in a sed expression; BSD sed reads the escape as a literal and matches nothing
make --eval	make --eval, which is GNU make 3.82+ (macOS ships 3.81)
grep -[a-zA-Z]*P 	grep -P, a GNU extension
(^|[^-_[:alnum:]])timeout +[0-9]	a bare timeout; macOS has neither it nor gtimeout, so use devkit_timeout
\$\(python3 -c[^)]*yaml	a value read out of PyYAML, which the macOS interpreter does not have (a guarded capability test is fine)
readlink -f	readlink -f, which macOS does not support (use devkit_resolve_path)
LEGACY_RULES
if docker_live; then
    legacy_out="$(docker run --rm -v "${ROOT_DIR}:/w:ro" -w /w -e SOURCED_ONLY="$sourced_only" bash:3.2 bash -c '
        [ "${BASH_VERSINFO[0]}" = 3 ] || { echo "WRONG-BASH ${BASH_VERSION}"; exit 1; }
        for s in scripts/*.sh; do
            case " $SOURCED_ONLY " in *" ${s##*/} "*) continue ;; esac
            bash "$s" --help >/dev/null 2>&1 || echo "HELP-FAILED $s"
        done
        source config/util_paths.sh >/dev/null 2>&1 || { echo "SOURCE-FAILED util_paths"; exit 1; }
        source scripts/util_logging.sh >/dev/null 2>&1 || { echo "SOURCE-FAILED util_logging"; exit 1; }
        printf "K=one\nK=two\n" > /tmp/legacy.env
        [ "$(devkit_env_value K /tmp/legacy.env)" = two ] || echo "BROKEN devkit_env_value"
        [ "$(devkit_resolve_path scripts/../config)" = /w/config ] || echo "BROKEN devkit_resolve_path"
        devkit_is_true yes || echo "BROKEN devkit_is_true"
        devkit_timeout 2 true || echo "BROKEN devkit_timeout"
        devkit_env_entries config >/dev/null 2>&1 || true
        VIRTUAL_ENV_PROMPT="(name) "; devkit_venv_prompt
        [ "$VIRTUAL_ENV_PROMPT" = name ] || echo "BROKEN devkit_venv_prompt"
        # The recipe in `make gpus` probes device nodes with compgen -G.
        compgen -G "/dev/null" >/dev/null 2>&1 || echo "BROKEN compgen-G"
        echo LEGACY-OK' 2>&1 | grep -vE '^\s*$' || true)"
    # Any diagnostic on the way counts, not just a failed test: bash 3.2 prints
    # "bad substitution" for a bash-4 expansion and CARRIES ON, so a probe that
    # only watched exit codes reported a helper working that had already failed.
    legacy_bad="$(grep -E 'WRONG-BASH|HELP-FAILED|SOURCE-FAILED|BROKEN|bad substitution|syntax error|unexpected|command not found' <<< "$legacy_out" | tr '\n' ' ' || true)"
    { grep -q '^LEGACY-OK$' <<< "$legacy_out" && [ -z "$legacy_bad" ]; } \
        || log_err "the shared helpers or a host CLI do not run under bash 3.2, which the support matrix claims: ${legacy_bad:-no LEGACY-OK marker}"
    { grep -q '^LEGACY-OK$' <<< "$legacy_out" && [ -z "$legacy_bad" ]; } \
        && log_ok "The helpers and every host CLI run under real bash 3.2 (macOS / RHEL SLURM nodes)."
else
    log_warn "bash 3.2 execution skipped (no docker): here the macOS/SLURM-node claim rests on CI alone."
fi

# =============================================================================
# [doc-references] Every check slug cited in docs or comments must resolve.
#      Numbered ids drifted silently — two checks were both cited as [22].
# =============================================================================
cited="$( { grep -rhoE '(check|verify|verify`) \[[a-z][a-z-]+\]' README.md docs/*.md docker/Dockerfile \
             config/*.sh scripts/*.sh 2>/dev/null || true; } | grep -oE '\[[a-z][a-z-]+\]' | tr -d '[]' | sort -u)"
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

# README advertises how many contracts this suite enforces, and the number went
# stale twice (24 while 32 groups existed). Derived from the slug headers, which
# are also what the docs cite.
readme_contracts="$(grep -oE '[0-9]+개 계약' README.md | grep -oE '[0-9]+' | head -1 || true)"
slug_groups="$(grep -cE '^# \[[a-z][a-z-]+\]' scripts/verify_repo.sh)"
# A budget, so "the suite is getting big" is a check and not an opinion. A
# template's verification has to stay readable by whoever forked it: a new group
# either replaces one or moves this ceiling on purpose.
suite_lines="$(wc -l < scripts/verify_repo.sh)"
{ [ "$suite_lines" -le 5200 ] && [ "$slug_groups" -le 70 ]; } \
    || log_err "the contract suite is ${suite_lines} lines in ${slug_groups} groups, past the 5200/70 budget; replace a group or move the ceiling on purpose."
# Every group opens with `group` and closes with `ok`: without the open, a
# group inherits the previous verdict and its line goes silently missing —
# the one failure mode the per-group flags could not have had.
[ "$(grep -c '^group$' scripts/verify_repo.sh)" = "$(grep -c '^ok "' scripts/verify_repo.sh)" ] \
    || log_err "the suite has $(grep -c '^group$' scripts/verify_repo.sh) 'group' openers for $(grep -c '^ok \"' scripts/verify_repo.sh) 'ok' lines; a group without its opener reports the previous group's verdict."
upstream_checks || readme_contracts="$slug_groups"   # a fork's README describes the fork
[ "${readme_contracts:-0}" = "$slug_groups" ] \
    && log_ok "README's contract count matches the suite (${slug_groups} groups)." \
    || log_err "README advertises ${readme_contracts:-no} contracts; the suite has ${slug_groups} check groups."

# Every relative link in the docs must resolve — file AND anchor. Splitting this
# guide left a link to docs/LICENSE, which never existed. python3 is already a
# dependency of this suite (util_release_metadata.sh), and one call costs ~40 ms.
# One python3 call for both: a link that resolves and a command that exists.
# `make release` outlived its target in the docs once, so the second half reads
# only code spans and fences — prose like "make them pass" is not a claim.
# Keep the heredoc outside a command substitution: Apple's Bash 3.2 scans its
# contents for a closing ')' and starts reading Python strings as shell code.
doc_upstream=0
upstream_checks && doc_upstream=1
doc_probe="$(probe_dir)"
if ! DEVKIT_UPSTREAM_CHECKS="$doc_upstream" DEVKIT_PHONY="$phony_targets" \
    python3 - > "$doc_probe/problems" <<'PYCHECK'
import os, pathlib, re

def slug(h):
    h = re.sub(r'[^\w\s-]', '', h.lstrip('#').strip().lower(), flags=re.UNICODE)
    return re.sub(r'\s', '-', h)

def code_only(text):
    """Fenced blocks and inline `spans` — the parts that claim to be runnable."""
    fenced = re.findall(r'```[^\n]*\n(.*?)```', text, re.S)
    return "\n".join(fenced + re.findall(r'`([^`\n]+)`', text))

targets = set(os.environ.get('DEVKIT_PHONY', '').split())
bad = []
# README is the fork's: its links and headings are checked upstream only.
upstream = os.environ.get('DEVKIT_UPSTREAM_CHECKS') == '1'
files = sorted(pathlib.Path('.github').glob('*.md')) + sorted(pathlib.Path('docs').glob('*.md'))
if upstream:
    files.insert(0, pathlib.Path('README.md'))
elif not pathlib.Path('docs').is_dir():
    # A fork may delete docs/ wholesale (the ownership table says so); the kit's
    # remaining guides then link into a directory that is gone by its choice.
    files = []
for f in files:
    text = f.read_text()
    for m in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', text):
        target = m.group(1)
        if target.startswith(('http://', 'https://', '#')):
            continue
        path, _, frag = target.partition('#')
        p = (f.parent / path) if path else f
        if not p.exists():
            bad.append(f'{f} -> {target} (no such file)')
        check_fragment = upstream or p.name != 'README.md'
        if p.exists() and frag and check_fragment \
                and frag not in [slug(l) for l in p.read_text().splitlines() if l.startswith('#')]:
            bad.append(f'{f} -> {target} (no such heading)')
    # [ \t], not \s: two adjacent inline spans must not join into a phantom
    # "make" + "source …" across the newline between them.
    for m in re.finditer(r'\bmake[ \t]+([a-z][a-z0-9-]*)', code_only(text)):
        if m.group(1) not in targets:
            bad.append(f'{f} -> make {m.group(1)} (no such target)')
print(" | ".join(bad))
PYCHECK
then
    log_err "documentation validator could not run."
fi
doc_problems="$(cat "$doc_probe/problems" 2>/dev/null || true)"
rm -rf "$doc_probe"
[ -z "$doc_problems" ] \
    || log_err "documentation is out of date: ${doc_problems}"
# …and no guide may sit unreferenced, wherever it lives: GEMINI.md was reachable
# from nothing, and moving a file between docs/ and .github/ must not drop it
# out of this check the way scoping the loop to docs/*.md once did.
doc_all="$(ls docs/*.md .github/*.md 2>/dev/null || true)"
upstream_checks || doc_all=""   # a fork's README need not map the kit's guides
for doc_file in $doc_all; do
    case "$doc_file" in .github/PULL_REQUEST_TEMPLATE.md) continue ;; esac  # GitHub loads it by name
    grep -rqF "$(basename "$doc_file")" README.md $(grep -v "^${doc_file}$" <<< "$doc_all") \
        || log_err "${doc_file} is referenced by no other document."
done

# =============================================================================
# [venv-identity] The venv is named after the project and the prompt shows it.
#      Both were lost once: mkenv dropped --prompt (every project read
#      "(.venv)"), and PS1 is assigned after activation.
# =============================================================================
group
# Continuations joined first: the flag sits on the next physical line, and a
# per-line grep would report a false regression (it did).
# Comment lines stripped: a usage note naming `uv venv` is not a creation path.
venv_cmds="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' config/util_aliases.sh | grep -v '^[[:space:]]*#')"
# EVERY creation path, not just one: mkenv has two (uv, and the python3 -m venv
# fallback) and naming only one of them would hide the other.
venv_creates="$(grep -cE '(uv venv|python3 -m venv) ' <<< "$venv_cmds" || true)"
venv_named="$(grep -cE '(uv venv|python3 -m venv) [^|]*--prompt' <<< "$venv_cmds" || true)"
{ [ "$venv_creates" -ge 2 ] && [ "$venv_creates" -eq "$venv_named" ]; } \
    || log_err "${venv_named}/${venv_creates} venv creation paths pass --prompt: an unnamed one renders as the generic '(.venv)'."
grep -qE '^[^#]*COMPOSE_PROJECT_NAME' config/util_aliases.sh \
    || log_err "the venv prompt is no longer derived from COMPOSE_PROJECT_NAME."
# One source for the path: a stray ${WS_ROOT}/install/.venv outside the
# ${WS_VENV:-…} fallback drifts the moment WS_VENV changes.
stray_venv="$(grep -nE '\$\{WS_ROOT\}/install/\.venv' config/util_aliases.sh | grep -v 'WS_VENV:-' || true)"
[ -z "$stray_venv" ] \
    || log_err "venv path hardcoded outside \${WS_VENV}: $(cut -d: -f1,2 <<< "$stray_venv" | tr '\n' ' ')"
# The interpreter path is composed once too (${WS_VENV_PY}): the five sites
# that spelled it themselves used three different fallbacks. docker/ and
# .devcontainer/ are exempt — an image ENV cannot source the path SSOT.
stray_venv_py="$(grep -rn '\.venv/bin/python' config scripts | grep -vE '^(config/util_paths\.sh|scripts/verify_repo\.sh):' || true)"
[ -z "$stray_venv_py" ] \
    || log_err "the venv interpreter path is re-composed outside \${WS_VENV_PY}: $(cut -d: -f1,2 <<< "$stray_venv_py" | tr '\n' ' ')"
# Rendered, not grepped: PS1 is re-expanded at every prompt, so an active venv
# must surface there regardless of the order activation and PS1 happen in.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    log_info "PS1 rendering needs \${var@P} (bash 4.4+); this shell is ${BASH_VERSION%%(*} — probe skipped."
else
ps1_probe="$(bash --norc -ic "VIRTUAL_ENV_PROMPT=__probe__
    WORKSPACE_PATH='${ROOT_DIR}' source config/init_bash.sh >/dev/null 2>&1
    printf %s \"\${PS1@P}\"" 2>/dev/null || true)"
grep -q '(__probe__)' <<< "$ps1_probe" \
    || log_err "the interactive prompt does not show the active virtualenv (PS1 lost \${VIRTUAL_ENV_PROMPT})."
fi
grep -q 'VIRTUAL_ENV_DISABLE_PROMPT' config/init_bash.sh \
    || log_err "VIRTUAL_ENV_DISABLE_PROMPT is unset — running 'activate' would stack a second venv marker."
# `uv sync` must pin the venv's own interpreter: against UV_PYTHON uv REPLACES
# a mismatching environment, turning `mksync --share` pure and losing rospy.
# And activation must not be skipped just because the image pre-set VIRTUAL_ENV.
act_probe="$(probe_dir)"
mkdir -p "$act_probe/config" "$act_probe/install/.venv/bin"
cp config/init_bash.sh config/util_paths.sh "$act_probe/config/"
printf 'VIRTUAL_ENV_PROMPT=probe-name\n' > "$act_probe/install/.venv/bin/activate"
act_seen="$(VIRTUAL_ENV="$act_probe/install/.venv" WORKSPACE_PATH="$act_probe" \
    bash --norc -c "source '$act_probe/config/init_bash.sh' >/dev/null 2>&1; printf %s \"\${VIRTUAL_ENV_PROMPT:-}\"" 2>/dev/null || true)"
[ "$act_seen" = "probe-name" ] \
    || log_err "config/init_bash.sh skips activation when VIRTUAL_ENV is pre-set by the image — no deactivate, no prompt (got: '${act_seen}')."
rm -rf "$act_probe"
grep -qE 'uv sync [^|]*--python' <<< "$venv_cmds" \
    || log_err "uvs no longer pins 'uv sync --python <venv>': uv would replace a shared venv and drop rospy."
ok "Virtualenv identity: project-named, single path source, shown in the prompt, interpreter pinned."

# =============================================================================
# [build-flags] The MOTD advertises --debug/--release/--pkg/--meta, and a
#      rewrite once dropped all four while the advertisement stayed. Assert both
#      directions against a stub colcon: parsed, and present in the argv.
# =============================================================================
group
adv_flags="$(sed -n 's/^ *"cbuild|[^(]*(\([^)]*\)).*/\1/p' scripts/show_welcome.sh | tr -d ' ' | tr ',' ' ')"
[ "$(wc -w <<< "$adv_flags")" -ge 4 ] \
    || log_err "the MOTD build-flag advertisement could not be parsed ($adv_flags) — did the row change shape?"
for flag in $adv_flags; do
    grep -qE "^[[:space:]]*${flag}\)" config/util_aliases.sh \
        || log_err "MOTD advertises 'cbuild ${flag}' but __parse_build_flags does not handle it."
done
# The other flag the help table advertises, from a different parser.
grep -qE '^[[:space:]]*--share\)' config/util_aliases.sh \
    || log_err "the help table advertises 'mksync [--share]' but __parse_share_flag no longer handles it."
# The IDE is a third advertiser: .vscode/tasks.json invokes cbuild with these
# flags, and all four tasks were silently broken while the parser was missing.
for flag in $(grep -oE 'cbuild [^"'"'"']*' .vscode/tasks.json | grep -oE '\-\-[a-z-]+' | sort -u); do
    grep -qE "^[[:space:]]*${flag}\)" config/util_aliases.sh \
        || log_err ".vscode/tasks.json runs 'cbuild ${flag}' but __parse_build_flags does not handle it."
done
# …and tab completion offers those same flags, not raw colcon/CMake ones.
cbuild_completion="$(sed -n 's/^complete -W "\([^"]*\)" cbuild.*/\1/p' config/util_aliases.sh)"
for flag in $adv_flags; do
    grep -qE "(^| )${flag}( |$)" <<< "$cbuild_completion" \
        || log_err "tab completion for cbuild does not offer '${flag}' (offers: ${cbuild_completion:-nothing})."
done
flag_probe="$(probe_dir)"
mkdir -p "$flag_probe/bin" "$flag_probe/config"
cp config/util_aliases.sh config/util_paths.sh "$flag_probe/config/"
printf '#!/bin/sh\necho "$*"\n' > "$flag_probe/bin/colcon"; chmod +x "$flag_probe/bin/colcon"
flag_run() { env -i PATH="$flag_probe/bin:$probe_min_path" HOME=/tmp WORKSPACE_PATH="$flag_probe" \
    ROS_VERSION=2 bash -lc "source $flag_probe/config/util_aliases.sh 2>/dev/null; cbuild $1" 2>/dev/null; }
# Default: an unoptimised build is a silent performance regression.
case "$(flag_run '')"        in *-DCMAKE_BUILD_TYPE=RelWithDebInfo*) ;; *) log_err "cbuild lost its default -DCMAKE_BUILD_TYPE=RelWithDebInfo." ;; esac
case "$(flag_run --debug)"   in *-DCMAKE_BUILD_TYPE=Debug*)          ;; *) log_err "cbuild --debug no longer selects a Debug build." ;; esac
case "$(flag_run --release)" in *-DCMAKE_BUILD_TYPE=Release*)        ;; *) log_err "cbuild --release no longer selects a Release build." ;; esac
case "$(flag_run '--pkg a b')" in *"--packages-select a b"*)         ;; *) log_err "cbuild --pkg no longer maps to --packages-select." ;; esac
case "$(flag_run --meta)"    in *--metas*colcon.meta*)               ;; *) log_err "cbuild --meta no longer passes config/colcon.meta to colcon (the file would be inert)." ;; esac
rm -rf "$flag_probe"
ok "Advertised build flags work (default RelWithDebInfo, --debug/--release/--pkg/--meta)."

# =============================================================================
# [project-layout] What the workspace is reported to BE and what a build can
#      actually configure must be the same answer. The detector searched under
#      src/ (thirdparty included) while mbuild looked at the repository root, so
#      a root-level CMake project reported PYTHON and a thirdparty-only tree
#      reported CPP and then failed with "No CMakeLists.txt".
# =============================================================================
group
# layout_case <label> <relative CMakeLists path or ''> <expected type> <expected entry|->
layout_case() {
    local label="$1" place="$2" want_type="$3" want_entry="$4"
    local probe; probe="$(probe_dir config scripts)"
    mkdir -p "$probe/src"
    [ -z "$place" ] || { mkdir -p "$(dirname "$probe/$place")"; : > "$probe/$place"; }
    local got
    got="$( WORKSPACE_PATH="$probe" bash -c 'source config/util_aliases.sh >/dev/null 2>&1
        entry="$(__cmake_entry 2>/dev/null)"
        case "$entry" in "") entry=- ;; "$WS_ROOT") entry=root ;; *) entry="${entry##*/}" ;; esac
        printf "%s %s" "$(__detect_project_type)" "$entry"' 2>/dev/null || true )"
    rm -rf "$probe"
    [ "$got" = "$want_type $want_entry" ] \
        || log_err "layout '${label}': reported '${got}', expected '${want_type} ${want_entry}' — the detector and mbuild disagree."
}
layout_case "CMakeLists at the repository root" CMakeLists.txt          CPP    root
layout_case "CMakeLists in src/"                src/CMakeLists.txt      CPP    src
layout_case "only a nested package"             src/pkg/CMakeLists.txt  PYTHON -
layout_case "only thirdparty"                   src/thirdparty/lib/CMakeLists.txt PYTHON -
layout_case "no CMake at all"                   ""                      PYTHON -
# …and mbuild must CONFIGURE that entry, not resolve one of its own. Probed
# with a stub cmake, because a second resolution is exactly what drifted.
layout_probe="$(probe_dir config scripts)"
mkdir -p "$layout_probe/src" "$layout_probe/bin"
: > "$layout_probe/CMakeLists.txt"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/cmake.log"\nexit 1\n' "$layout_probe" > "$layout_probe/bin/cmake"
chmod +x "$layout_probe/bin/cmake"
( PATH="$layout_probe/bin:$PATH" WORKSPACE_PATH="$layout_probe" bash -c \
    'source config/util_aliases.sh >/dev/null 2>&1; mbuild' ) >/dev/null 2>&1 || true
layout_src="$(awk '/^-S$/{getline; print; exit}' "$layout_probe/cmake.log" 2>/dev/null || true)"
[ "$layout_src" = "$layout_probe" ] \
    || log_err "mbuild configures '${layout_src:-nothing}' for a root-level CMake project, not the entry point the detector reports."
rm -rf "$layout_probe"
ok "The project type and the CMake entry point are one answer, and mbuild configures it (5 layouts)."

# =============================================================================
# [workspace-overlay] Which setup.bash a shell picks up. ROS 1's catkin_make
#      writes devel/ and only fills install/ when asked, so a dev build's
#      packages were invisible to every shell — all three sites looked at
#      install/ alone. Production keeps its install-only entrypoint on purpose.
# =============================================================================
group
overlay_probe="$(probe_dir config scripts)"
mkdir -p "$overlay_probe/devel" "$overlay_probe/install"
printf 'export DEVKIT_OVERLAY=devel\n'   > "$overlay_probe/devel/setup.bash"
printf 'export DEVKIT_OVERLAY=install\n' > "$overlay_probe/install/setup.bash"
overlay_pick() {   # overlay_pick <distro>
    ( WORKSPACE_PATH="$overlay_probe" ROS_DISTRO="$1" \
      bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_overlay_setup' 2>/dev/null || true )
}
[ "$(overlay_pick noetic)" = "$overlay_probe/devel/setup.bash" ] \
    || log_err "a ROS 1 workspace picks '$(overlay_pick noetic)', not devel/setup.bash; a catkin_make build stays invisible."
[ "$(overlay_pick humble)" = "$overlay_probe/install/setup.bash" ] \
    || log_err "a ROS 2 workspace no longer picks install/setup.bash."
# A setup.bash that fails must not be reported as sourced.
printf 'return 17\n' > "$overlay_probe/install/setup.bash"
overlay_rc="$( WORKSPACE_PATH="$overlay_probe" ROS_DISTRO=humble bash -c \
    'source config/util_aliases.sh >/dev/null 2>&1; __smart_source >/dev/null 2>&1; printf %s $?' 2>/dev/null || true )"
[ "$overlay_rc" = "17" ] \
    || log_err "__smart_source returns ${overlay_rc:-0} for a setup.bash that failed; the shell is missing the packages the log claims."
rm -rf "$overlay_probe"
# Every shell that loads an overlay must go through the one rule.
for overlay_site in config/init_bash.sh docker/entrypoint.sh config/util_aliases.sh; do
    grep -qE '^[^#]*devkit_overlay_setup' "$overlay_site" \
        || log_err "${overlay_site} resolves the workspace overlay itself instead of through devkit_overlay_setup."
done
# …but the shipped artifact does not: it carries install/ and nothing else.
grep -qE '^[^#]*devkit_overlay_setup' docker/prod_entrypoint.sh \
    && log_err "docker/prod_entrypoint.sh looks for a devel/ overlay; the production image copies install/ only."
ok "ROS 1 loads devel/, ROS 2 loads install/, a failed setup.bash propagates, and prod stays install-only."

# =============================================================================
# [in-container-clean] `mclean` must empty what a build produced, with the same
#      scope the host's `make clean` uses. Naming install/bin and install/lib
#      alone left colcon's per-package trees, install/share and a ROS 1 devel/
#      in place — and still reported success.
# =============================================================================
group
mclean_tree() {   # rebuild a workspace with every layout a build can leave
    local probe="$1"
    mkdir -p "$probe/build/x" "$probe/devel/old" "$probe/log/y" \
             "$probe/install/.venv/bin" "$probe/install/bin" \
             "$probe/install/pkg/lib/node" "$probe/install/share/x"
    : > "$probe/install/.venv/bin/python3"; : > "$probe/install/pkg/lib/node/n"
    : > "$probe/install/share/x/f"; : > "$probe/devel/old/f"; : > "$probe/build/x/o"
}
mclean_left() {   # what survived, workspace-relative
    ( cd "$1" && find build devel log install -mindepth 1 2>/dev/null | sort | tr '\n' ' ' )
}
mclean_probe="$(probe_dir config scripts)"; mclean_tree "$mclean_probe"
( WORKSPACE_PATH="$mclean_probe" bash -c 'source config/util_aliases.sh >/dev/null 2>&1; mclean' ) >/dev/null 2>&1 || true
[ "$(mclean_left "$mclean_probe")" = "install/.venv install/.venv/bin install/.venv/bin/python3 " ] \
    || log_err "mclean left '$(mclean_left "$mclean_probe")'; the default scope must empty build/, devel/, log/ and install/ except the venv."
rm -rf "$mclean_probe"

mclean_probe="$(probe_dir config scripts)"; mclean_tree "$mclean_probe"
( WORKSPACE_PATH="$mclean_probe" bash -c 'source config/util_aliases.sh >/dev/null 2>&1; mclean --all' ) >/dev/null 2>&1 || true
[ -z "$(mclean_left "$mclean_probe")" ] \
    || log_err "mclean --all left '$(mclean_left "$mclean_probe")'; it must remove the venv too."
rm -rf "$mclean_probe"

# A leftover the command could not remove must fail, not be reported as clean.
mclean_probe="$(probe_dir config scripts)"; mclean_tree "$mclean_probe"
chmod -w "$mclean_probe/install/share" 2>/dev/null
mclean_rc=0
( WORKSPACE_PATH="$mclean_probe" bash -c 'source config/util_aliases.sh >/dev/null 2>&1; mclean' ) >/dev/null 2>&1 || mclean_rc=$?
chmod +w "$mclean_probe/install/share" 2>/dev/null
if [ "$(id -u)" -ne 0 ]; then
    [ "$mclean_rc" -ne 0 ] \
        || log_err "mclean reports success while an entry it could not delete is still there."
fi
rm -rf "$mclean_probe"
ok "mclean empties build/, devel/, log/ and install/ (keeping the venv), and fails on what it could not remove."

# =============================================================================
# [prod-build-inputs] The production builder COPYs an explicit input set; the
#      project-type detector (`__cmake_entry`) must see the same tree as a dev
#      build. A repository-root CMake project resolved to PYTHON inside the
#      builder — the root CMakeLists.txt was never copied — and shipped no
#      binary. The COPY sources are parsed from the Dockerfile and applied to a
#      fixture tree the way BuildKit applies them (bracket globs, optional).
# =============================================================================
group
pbi_probe="$(probe_dir)"
mkdir -p "$pbi_probe/ctx/src" "$pbi_probe/ctx/cmake" "$pbi_probe/ctx/dependencies" "$pbi_probe/img"
ln -s "${ROOT_DIR}/config" "$pbi_probe/ctx/config"; ln -s "${ROOT_DIR}/scripts" "$pbi_probe/ctx/scripts"
: > "$pbi_probe/ctx/CMakeLists.txt"; : > "$pbi_probe/ctx/cmake/Deps.cmake"; : > "$pbi_probe/ctx/src/main.py"; : > "$pbi_probe/ctx/VERSION"
# COPY <src…> <dst> lines of the prod-builder stage (no --from: those are stage copies).
pbi_copies="$(awk '/AS prod-builder$/{inside=1; next} inside && /^FROM /{inside=0}
                   inside && /^COPY / && !/--from/ {sub(/^COPY /, ""); print}' docker/Dockerfile)"
[ -n "$pbi_copies" ] || log_err "prod-builder has no COPY lines to parse."
while read -r pbi_line; do
    [ -n "$pbi_line" ] || continue
    set -- $pbi_line
    pbi_dst="${!#}"; pbi_dst="${pbi_dst//\$\{WORKSPACE_PATH\}/$pbi_probe/img}"
    while [ $# -gt 1 ]; do
        for pbi_src in $pbi_probe/ctx/$1; do   # unquoted: the bracket glob expands, or stays literal (absent)
            [ -e "$pbi_src" ] || continue
            # COPY semantics: a directory source contributes its CONTENTS.
            if [ -d "$pbi_src" ] && [ ! -L "$pbi_src" ]; then mkdir -p "$pbi_dst" && cp -R "$pbi_src/." "$pbi_dst"
            else case "$pbi_dst" in */) mkdir -p "$pbi_dst" ;; *) mkdir -p "$(dirname "$pbi_dst")" ;; esac; cp -R "$pbi_src" "$pbi_dst"; fi
        done
        shift
    done
done <<< "$pbi_copies"
pbi_type() { ( WORKSPACE_PATH="$1" bash -c 'source config/util_aliases.sh >/dev/null 2>&1; __detect_project_type; __cmake_entry' 2>/dev/null || true ) | tr '\n' ' ' | sed 's/ $//'; }
pbi_ctx="$(pbi_type "$pbi_probe/ctx")"; pbi_img="$(pbi_type "$pbi_probe/img")"
[ "$pbi_ctx" = "CPP $pbi_probe/ctx" ] \
    || log_err "the detector does not see a root CMake project as CPP at the root (got: ${pbi_ctx})."
[ "$pbi_img" = "CPP $pbi_probe/img" ] \
    || log_err "inside the production builder the same tree resolves to '${pbi_img}' — the COPY set drops a build input (root CMakeLists.txt / cmake/)."
[ -f "$pbi_probe/img/cmake/Deps.cmake" ] \
    || log_err "the production builder does not receive cmake/ modules a root CMakeLists.txt includes."
rm -rf "$pbi_probe"
ok "Production builder inputs: a root CMake project resolves to CPP inside the builder as it does in a dev build."

# =============================================================================
# [dependency-presence] "Are there external repositories?" must have ONE answer.
#      A regex anchored to a line starting with url: saw nothing in flow-style
#      YAML, so a populated .repos reported "nothing to import" and exited 0
#      with vcstool absent; the first-run check counted the shipped .gitkeep as
#      content and skipped the sync entirely.
# =============================================================================
group
deps_probe="$(probe_dir config scripts)"
mkdir -p "$deps_probe/dependencies" "$deps_probe/src/thirdparty" "$deps_probe/bin"
deps_hash="0123456789abcdef0123456789abcdef01234567"
deps_repos() { printf '%s\n' "$1" > "$deps_probe/dependencies/dependencies.repos"; }
# Without vcstool a declared repository must FAIL, in either YAML style.
deps_missing_tool() {
    ( PATH="$probe_min_path" WORKSPACE_PATH="$deps_probe" \
      bash scripts/setup_sync_deps.sh 2>&1 || true )
}
deps_repos "repositories:
  a: {type: git, url: https://example.invalid/a.git, version: ${deps_hash}}"
grep -qi 'vcstool is missing' <<< "$(deps_missing_tool)" \
    || log_err "a flow-style .repos reads as empty; a populated file would report 'nothing to import' and exit 0."
deps_repos "repositories:
  a:
    type: git
    url: https://example.invalid/a.git
    version: ${deps_hash}"
grep -qi 'vcstool is missing' <<< "$(deps_missing_tool)" \
    || log_err "a block-style .repos no longer counts as declaring a repository."
deps_repos "repositories:"
grep -qi 'No external repositories' <<< "$(deps_missing_tool)" \
    || log_err "an empty .repos no longer reads as empty; every container start would fail on a missing vcstool."
# The shipped template, verbatim: its example is commented out, so a stock
# workspace declares nothing. Counting those lines made every `make exec` demand
# python3-vcstool and fired the first-run sync on every container start.
cp dependencies/dependencies.repos "$deps_probe/dependencies/dependencies.repos"
grep -qi 'No external repositories' <<< "$(deps_missing_tool)" \
    || log_err "the shipped dependencies.repos reads as populated; a stock workspace would fail on a missing vcstool."

# The entrypoint's first-run condition, extracted and evaluated: the shipped
# .gitkeep must not count as "already synced", and SYNC_TARGET_DIR must be used.
# The whole block, not just the `if`: the paths it tests are computed on the
# lines above it, and evaluating the condition alone tested empty variables.
deps_cond="$(awk '/^SYNC_DEPS=/,/then$/' docker/entrypoint.sh \
    | sed -e 's/^if /DEVKIT_FIRSTRUN=; if /' -e 's/; *then$/; then DEVKIT_FIRSTRUN=1; fi/' \
    | grep -v '^#')"
[ -n "$deps_cond" ] \
    || log_err "verify_repo.sh can no longer find the first-run sync condition in docker/entrypoint.sh."
deps_firstrun() {   # deps_firstrun [SYNC_TARGET_DIR]
    ( WS_ROOT="$deps_probe"; SYNC_TARGET_DIR="${1:-}"
      eval "$deps_cond"
      [ -n "${DEVKIT_FIRSTRUN:-}" ] ) >/dev/null 2>&1
}
: > "$deps_probe/src/thirdparty/.gitkeep"
cp dependencies/dependencies.repos "$deps_probe/dependencies/dependencies.repos"
deps_firstrun \
    && log_err "the first-run sync fires on the shipped .repos, whose only example is commented out."
deps_repos "repositories:
  a: {type: git, url: https://example.invalid/a.git, version: ${deps_hash}}"
deps_firstrun \
    || log_err "the first-run sync is skipped when only the shipped .gitkeep is present; a filled .repos would never import."
mkdir -p "$deps_probe/src/thirdparty/already"
deps_firstrun \
    && log_err "the first-run sync fires on a populated target; every container start would pay for a network import."
# …and it must look at the configured target, not a hardcoded src/thirdparty.
mkdir -p "$deps_probe/elsewhere"
deps_firstrun "$deps_probe/elsewhere" \
    || log_err "the first-run check ignores SYNC_TARGET_DIR and inspects src/thirdparty instead."
# The first-run sync runs BEFORE the privilege drop, as root, into the bind
# mount. The clone must be handed to the container user or nobody — not the
# container user, not the host — can modify or remove it afterwards.
# Recursively, and without the "already owned" shortcut: the target itself is
# tracked (.gitkeep) so the bind mount hands it over user-owned already, and the
# shortcut then skipped every repository cloned inside it. [env-bridge] proves
# the result in a container; this keeps the call where the sync leaves it.
awk '/bash "\$SYNC_DEPS"/ {seen=1} seen && /chown -R .*THIRD_PARTY/ {ok=1} END {exit ok ? 0 : 1}' docker/entrypoint.sh \
    || log_err "docker/entrypoint.sh does not chown -R the first-run sync target; the clone stays root-owned."
rm -rf "$deps_probe"
ok "One answer for 'are there external repositories': both YAML styles, an empty file, .gitkeep and a custom target; the first-run clone is handed to the user."

# =============================================================================
# [query-side-effects] A read-only view must leave the caller's shell as it
#      found it. `gpu` sources setup_gpu.sh, and the colour stripping there
#      rewires stdout with `exec > >(sed …)` — after `gpu status` returned, the
#      user's shell was still writing through that filter.
# =============================================================================
group
# The verdict leaves on fd 9: a redirection on the CALL would scope the exec
# under test and hide exactly the effect being measured, so the command runs
# with the shell's own stdout.
query_fd() {   # query_fd <command…> → same | changed | unsupported
    local out; out="$(mktemp "${DEVKIT_PROBE_ROOT}/fd.XXXXXX")"
    # No display: the question is the file descriptor, and with one set the
    # three status calls ran glxinfo/eglinfo/vulkaninfo for real — 6.6 s, 44 %
    # of the whole suite on a WSLg host.
    ( cd "$ROOT_DIR" && env -u DISPLAY -u WAYLAND_DISPLAY WORKSPACE_PATH="$ROOT_DIR" bash -c '
        exec 9>"'"$out"'"
        source config/util_aliases.sh >/dev/null 2>&1
        before="$(readlink /proc/$$/fd/1 2>/dev/null || true)"
        # An empty read is not evidence of "unchanged": without /proc (macOS)
        # both reads came back empty and every rewire passed as same.
        [ -n "$before" ] || { echo unsupported >&9; exit 0; }
        '"$1"'
        after="$(readlink /proc/$$/fd/1 2>/dev/null || true)"
        [ "$before" = "$after" ] && echo same >&9 || echo changed >&9' ) >/dev/null 2>&1 || true
    cat "$out" 2>/dev/null; rm -f "$out"
}
# Three calls, not one: a rewire that reinstalls itself each time stacks filter
# processes on the caller's stdout, and one call cannot tell that apart.
query_verdict="$(query_fd 'NO_COLOR=1 gpu status; NO_COLOR=1 gpu status; NO_COLOR=1 gpu status')"
case "$query_verdict" in
    same) ;;
    unsupported) log_warn "fd check skipped: this host has no /proc/<pid>/fd (the Linux runners cover it)." ;;
    *) log_err "'gpu status' leaves the caller's stdout rewired (${query_verdict:-no verdict}); every later line goes through a filter it never asked for." ;;
esac
# …while a mode change must still reach the caller: that is why it is sourced.
query_mode="$( WORKSPACE_PATH="$ROOT_DIR" bash -c '
    source config/util_aliases.sh >/dev/null 2>&1
    gpu cpu >/dev/null 2>&1
    printf %s "${LIBGL_ALWAYS_SOFTWARE:-unset}"' 2>/dev/null || true )"
[ "$query_mode" = "1" ] \
    || log_err "'gpu cpu' no longer reaches the caller's environment (LIBGL_ALWAYS_SOFTWARE=${query_mode})."
ok "A GPU status query leaves the caller's shell untouched; a mode change still reaches it."

# =============================================================================
# [compile-db] The IDE reads build/compile_commands.json, and only a build can
#      produce it. Every automatic caller passed --skip-compile-commands, so the
#      aggregation ran on a manual invocation and nowhere else — while shell
#      startup, which must stay fast, is the one place that should skip it.
# =============================================================================
group
ccdb_probe="$(probe_dir config scripts)"
mkdir -p "$ccdb_probe/build/pkg_a" "$ccdb_probe/build/pkg_b" "$ccdb_probe/bin" "$ccdb_probe/src"
printf '[{"directory":"/x","command":"cc a.c","file":"a.c"}]' > "$ccdb_probe/build/pkg_a/compile_commands.json"
printf '[{"directory":"/x","command":"cc b.c","file":"b.c"}]' > "$ccdb_probe/build/pkg_b/compile_commands.json"
printf '#!/bin/sh\nexit 0\n' > "$ccdb_probe/bin/colcon"; chmod +x "$ccdb_probe/bin/colcon"
( PATH="$ccdb_probe/bin:$probe_min_path" WORKSPACE_PATH="$ccdb_probe" ROS_DISTRO=humble \
  bash -c 'source config/util_aliases.sh >/dev/null 2>&1; cbuild' ) >/dev/null 2>&1 || true
ccdb_count="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' \
    "$ccdb_probe/build/compile_commands.json" 2>/dev/null || echo 0)"
[ "$ccdb_count" = "2" ] \
    || log_err "a build leaves ${ccdb_count} entries in build/compile_commands.json; the per-package files were never merged and the IDE reads nothing."
[ -e "$ccdb_probe/compile_commands.json" ] \
    || log_err "no compile_commands.json link at the workspace root; .vscode points at a path that does not exist."
# A deleted package must drop out rather than linger.
rm -rf "$ccdb_probe/build/pkg_b"
( PATH="$ccdb_probe/bin:$probe_min_path" WORKSPACE_PATH="$ccdb_probe" ROS_DISTRO=humble \
  bash -c 'source config/util_aliases.sh >/dev/null 2>&1; cbuild' ) >/dev/null 2>&1 || true
[ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' \
    "$ccdb_probe/build/compile_commands.json" 2>/dev/null || echo 0)" = "1" ] \
    || log_err "a removed package still appears in the aggregated compile database."
rm -rf "$ccdb_probe"
# …and the interactive shell must not pay for the whole search on every start.
grep -qE '^[^#]*util_setup_links\.sh.*--skip-compile-commands' config/init_bash.sh \
    || log_err "config/init_bash.sh aggregates the compile database at shell startup; every new terminal would scan build/."
ok "A build refreshes the aggregated compile database (and drops removed packages); shell startup does not."

# =============================================================================
# [library-loader] devkit_require must report what actually happened. It ran
#      `source` and returned 0 regardless, then recorded the library as loaded —
#      so a partly-initialised shell looked healthy and the next call skipped
#      the retry.
# =============================================================================
group
loader_probe="$(probe_dir)"
mkdir -p "$loader_probe/config" "$loader_probe/scripts"
cp "${ROOT_DIR}/config/util_paths.sh" "$loader_probe/config/"
printf 'return 17\n'   > "$loader_probe/scripts/util_devkit_broken.sh"
printf 'DEVKIT_OK=1\n' > "$loader_probe/scripts/util_devkit_fine.sh"
loader_out="$( WORKSPACE_PATH="$loader_probe" bash -c '
    cd "$WORKSPACE_PATH" && source config/util_paths.sh
    devkit_require util_devkit_broken.sh 2>/dev/null; printf "first=%s " $?
    devkit_require util_devkit_broken.sh 2>/dev/null; printf "again=%s " $?
    devkit_require util_devkit_fine.sh;               printf "good=%s ok=%s " $? "${DEVKIT_OK:-unset}"
    devkit_require util_devkit_fine.sh;               printf "cached=%s" $?' 2>/dev/null || true )"
rm -rf "$loader_probe"
case "$loader_out" in
    *"first=17"*) ;;
    *) log_err "devkit_require returns 0 for a library that failed to load: ${loader_out}" ;;
esac
case "$loader_out" in
    *"again=17"*) ;;
    *) log_err "devkit_require remembers a FAILED library as loaded and skips the retry: ${loader_out}" ;;
esac
case "$loader_out" in
    *"good=0 ok=1"*) ;;
    *) log_err "devkit_require no longer loads a working library: ${loader_out}" ;;
esac
case "$loader_out" in
    *"cached=0"*) ;;
    *) log_err "devkit_require re-sources a library it already loaded: ${loader_out}" ;;
esac
ok "devkit_require propagates a failed load, retries it, and caches only what succeeded."

# =============================================================================
# [build-boundary] A setting the host advertises has to arrive INSIDE the image
#      build. OPENCV_CUDA reached the dev runtime but no builder stage, so a
#      release compiled with the default; APT_SNAPSHOT_FALLBACK had a consumer
#      and no route to it; and a GPU_MODE build arg was passed to stages that
#      declare no such ARG. A name existing in both files proves none of this.
# =============================================================================
group
boundary_probe="$(probe_dir)"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit 1\n' "$boundary_probe" > "$boundary_probe/docker"
printf '#!/bin/sh\nexit 0\n' > "$boundary_probe/apptainer"
chmod +x "$boundary_probe/docker" "$boundary_probe/apptainer"
# Values that differ from every default, so a hardcoded fallback cannot pass.
( PATH="$boundary_probe:$probe_min_path" OPENCV_CUDA=off APT_SNAPSHOT_FALLBACK=false \
  bash scripts/apptainer_bake.sh --mode prod --env ros ) >/dev/null 2>&1 || true
for boundary_arg in "OPENCV_CUDA=off" "APT_SNAPSHOT_FALLBACK=false"; do
    grep -qxF -- "$boundary_arg" "$boundary_probe/argv" 2>/dev/null \
        || log_err "'${boundary_arg%%=*}' never reaches the image build; the host value is read only outside it."
done
# …and nothing may be passed that no stage declares: BuildKit drops it silently.
while IFS= read -r boundary_passed; do
    [ -n "$boundary_passed" ] || continue
    grep -qE "^ARG ${boundary_passed}(=|$)" docker/Dockerfile \
        || log_err "the bake passes --build-arg ${boundary_passed}, which no Dockerfile stage declares; BuildKit discards it."
done <<< "$(awk '/^--build-arg$/{getline; sub(/=.*/, ""); print}' "$boundary_probe/argv" 2>/dev/null || true)"
rm -rf "$boundary_probe"
# The stage that RUNS the consumer must declare the ARG, or the value stops at
# the stage boundary instead of the build boundary.
awk '/^FROM /{stage=$NF} /^ARG OPENCV_CUDA/{declared[stage]=1}
     /mksync/ && $0 !~ /^#/ {uses[stage]=1}
     END { for (s in uses) if (!declared[s]) { print s; rc=1 } exit rc }' docker/Dockerfile >/dev/null \
    || log_err "a stage runs mksync without declaring ARG OPENCV_CUDA; the builder compiles against the default."
# …and the two places a default is spelled must agree: an ARG default that
# drifts from .env.example makes a direct `docker build` produce a different
# image than `make build` (uv 0.10.10 vs whatever the ARG still said). Every
# shared key at once, so a new pin is covered the day it is added. Upstream
# only: a fork is told to edit .env.example (ROS_DISTRO, UV_EXTRA) and has no
# reason to touch the Dockerfile's default.
if upstream_checks; then
    pin_count=0
    while IFS= read -r pin_line; do
        pin_key="${pin_line%%=*}"; pin_val="${pin_line#*=}"
        # The image bakes a fallback LABEL here; the project name lives in .env.
        [ "$pin_key" = COMPOSE_PROJECT_NAME ] && continue
        pin_arg="$(sed -n "s/^ARG ${pin_key}=//p" docker/Dockerfile | head -n 1)"
        [ -n "$pin_arg" ] || continue
        pin_count=$((pin_count + 1))
        # Both sides unquoted: the Dockerfile writes ARG X="" where .env.example
        # writes X= for the same "no value".
        pin_arg="${pin_arg%\"}"; pin_arg="${pin_arg#\"}"
        pin_val="${pin_val%\"}"; pin_val="${pin_val#\"}"
        [ "$pin_arg" = "$pin_val" ] \
            || log_err "${pin_key} is '${pin_arg}' in docker/Dockerfile but '${pin_val}' in .env.example; a direct docker build differs from 'make build'."
    done < <(grep -E '^[A-Z0-9_]+=' .env.example)
    [ "$pin_count" -ge 10 ] \
        || log_err "the ARG/.env.example pin comparison found only ${pin_count} shared keys; the extraction broke."
fi
ok "Advertised build settings arrive inside the image, and nothing is passed that no stage declares."

# =============================================================================
# Result
# =============================================================================
echo ""
# Say what could NOT be checked here. Five groups need a live daemon (the ROS
# repo codename refusal, the entrypoint boot and ownership probes, the real
# build-context probe, the `make term` binary probe); without one the report
# used to be byte-identical to a full run and still read as complete coverage.
docker_live || log_warn "No docker daemon: 6 container-backed groups were checked statically only (ROS repo codename, entrypoint boot, first-run ownership, build context, terminal probe, bash 3.2)."
if [ "$FAILED" -gt 0 ]; then
    echo -e "  \033[0;31m[FAIL]\033[0m ${FAILED} verification check(s) failed!" >&2
    exit 1
fi
log_ok "DevKit repository verification complete!"

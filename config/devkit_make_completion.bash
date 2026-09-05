#!/usr/bin/env bash
# =============================================================================
# DevKit Makefile Tab Completion (Ultra-Lean & Fast Engine) — bash only.
# One shell, one dialect: the container is bash, every script is bash, and
# maintaining a second array-semantics dialect for zsh bought nothing but an
# untestable code path. zsh users: run `bash` (or chsh) for completion; every
# make target works from any shell regardless.
# =============================================================================

# Silent no-op outside bash so a stray rc entry never prints errors.
[ -z "${BASH_VERSION:-}" ] && return 0 2>/dev/null

# Locate the DevKit Makefile by walking up from $PWD, so completion works from
# any subdirectory (src/, docs/, …) exactly like `git` does. Printing nothing
# and returning 1 means "this is not a DevKit tree".
_devkit_find_makefile() {
    local dir="$PWD"
    while :; do
        if [ -f "$dir/Makefile" ] && grep -q "DevKit Makefile" "$dir/Makefile" 2>/dev/null; then
            printf '%s' "$dir/Makefile"
            return 0
        fi
        [ "$dir" = "/" ] || [ -z "$dir" ] && break
        dir="${dir%/*}"
        [ -z "$dir" ] && dir="/"
    done
    return 1
}

_devkit_make_completion() {
    local makefile

    # COMP_WORDS splits KEY=VALUE at '=' (a COMP_WORDBREAKS character), which
    # breaks both value completion ('ENV=<Tab>') and target detection. Rebuild
    # the words from the raw line instead.
    local line="${COMP_LINE:0:${COMP_POINT:-${#COMP_LINE}}}"
    local -a words=()
    read -ra words <<< "$line"
    local cur=""
    [[ "$line" == *" " ]] || cur="${words[${#words[@]}-1]:-}"

    # Outside a DevKit tree, hand back to the system completion instead of
    # returning an empty list — silently completing nothing is worse than
    # plain filename completion.
    if ! makefile="$(_devkit_find_makefile)"; then
        if declare -F _make >/dev/null 2>&1; then
            _make
        elif declare -F _completion_loader >/dev/null 2>&1; then
            _completion_loader make && return 124
        else
            compopt -o default 2>/dev/null || true
        fi
        return 0
    fi

    # Determine target (first non-assignment word after 'make', excluding the
    # word currently being completed)
    local target="" word i n=${#words[@]}
    [ -n "$cur" ] && n=$((n - 1))
    for ((i=1; i<n; i++)); do
        word="${words[i]}"
        [[ "$word" == *=* ]] && continue
        [[ "$word" == -* ]] && continue
        target="$word"
        break
    done

    # 1. Target completion: 'make <Tab>'
    if [ -z "$target" ]; then
        local targets
        targets=$(awk '/^\.PHONY:/ { sub(/^\.PHONY:[[:space:]]*/, ""); print }' "$makefile" 2>/dev/null | tr '\n' ' ')
        COMPREPLY=( $(compgen -W "$targets" -- "$cur") )
        return 0
    fi

    # 2. Key=Value option completion: 'make <target> <Tab>'
    # Only knobs that are actually honoured by the Makefile or the invoked
    # script belong here — an advertised switch that does nothing is a bug.
    local opts=""
    case "$target" in
        build)
            opts="ENV=ros ENV=dev GPU_MODE=auto GPU_MODE=nvidia GPU_MODE=igpu GPU_MODE=cpu NO_CACHE=1"
            ;;
        start|restart)
            opts="ENV=ros ENV=dev GPU_MODE=auto GPU_MODE=nvidia GPU_MODE=igpu GPU_MODE=cpu DEVKIT_VCS_ALLOW_FAILURE=1 DEVKIT_ROSDEP_ALLOW_FAILURE=1"
            ;;
        exec)
            opts="CMD="
            ;;
        adopt)
            opts="NAME= DESC="
            ;;
        test)
            opts="ENV=ros ENV=dev"
            ;;
        lint)
            opts="FIX=1 ENV=ros ENV=dev"
            ;;
        clean)
            opts="KEEP_VENV=0 KEEP_VENV=1"
            ;;
        clean-all)
            opts="KEEP_VENV=1 FORCE=1"
            ;;
        stop|down|shell|term|top|logs|stats|status|check)
            opts="ENV=ros ENV=dev"
            ;;
        bake-dev)
            opts="ENV=ros ENV=dev SHARE=1 IMAGE_TAG=latest"
            ;;
        bake-prod)
            opts="ENV=ros ENV=dev PROD_FULL_CUDA=1 IMAGE_TAG=latest SOURCE_DATE_EPOCH=0 DEVKIT_STRIP_SOURCE=1 DEVKIT_FAIL_ON_SOURCE=1"
            ;;
        run-sif)
            opts="SIF_MODE=dev SIF_MODE=prod SIF_MODE=slurm ENV=ros ENV=dev SIF_FILE= RUN_ARGS= APP_COMMAND= DEVKIT_SLURM_PARTITION=gpu DEVKIT_SLURM_GRES=gpu:1 DEVKIT_SLURM_CPUS_PER_TASK=8 DEVKIT_SLURM_MEM=32G DEVKIT_SLURM_TIME=01:00:00"
            ;;
    esac

    if [ -n "$opts" ]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        # A bare 'KEY=' still needs a value: don't append a word-ending space.
        if [ "${#COMPREPLY[@]}" -eq 1 ] && [[ "${COMPREPLY[0]}" == *= ]]; then
            compopt -o nospace 2>/dev/null || true
        fi
        # bash's readline replaces only the text after the LAST wordbreak
        # character ('=' and ':' are both in COMP_WORDBREAKS — think
        # DEVKIT_SLURM_GRES=gpu:1), so candidates must drop everything up to
        # and including it.
        if [[ "$cur" == *[=:]* ]] && [ "${#COMPREPLY[@]}" -gt 0 ]; then
            local suffix="${cur##*[=:]}"
            local prefix="${cur%"$suffix"}"
            COMPREPLY=( "${COMPREPLY[@]#"$prefix"}" )
        fi
        return 0
    fi
}

# Auto-installer when executed directly (e.g. via 'make setup')
if [ "${1:-}" = "--install" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    COMPLETION_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/devkit_make_completion.bash"
    ENTRY="[ -f \"$COMPLETION_SRC\" ] && source \"$COMPLETION_SRC\""
    RC_FILE="$HOME/.bashrc"
    if [ -f "$RC_FILE" ]; then
        if ! grep -q "devkit_make_completion.bash" "$RC_FILE" 2>/dev/null; then
            printf '\n# DevKit Makefile Tab Completion\n%s\n' "$ENTRY" >> "$RC_FILE"
            echo -e "  \033[32m[OK]\033[0m Registered Tab completion in ${RC_FILE}"
        else
            echo -e "  \033[32m[OK]\033[0m Tab completion already registered in ${RC_FILE}"
        fi
    else
        echo -e "  \033[33m[WARN]\033[0m No ~/.bashrc — completion not registered (bash-only feature)."
    fi
    return 0 2>/dev/null || exit 0
fi

complete -F _devkit_make_completion make

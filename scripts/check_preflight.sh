#!/bin/bash
# =============================================================================
# scripts/check_preflight.sh — host toolchain preflight for `make build`.
# Docker + Compose v2 + BuildKit are hard requirements; without this check a
# minimal or podman-only host dies deep inside compose ("'compose' is not a
# command"). Exit 0 = ok (warnings allowed), 1 = blocking. GPU checks live in
# `make check`.
# =============================================================================

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }  # host-only: never fall back to world-writable /tmp
devkit_require "util_logging.sh"
LOG_PREFIX="[Preflight]"

# check [cli-convention]: --help answers, a typo is refused. This once ran the
# full audit and reported success for `check_preflight.sh --fix`.
case "${1:-}" in
    "") ;;
    -h|--help)
        echo "Usage: check_preflight.sh   (no options; audits host prerequisites for 'make build')"
        exit 0 ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
esac

# Strip colour when piped/redirected or NO_COLOR is set (see util_logging.sh).
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

errors=0
warnings=0
# The host tools every workflow reaches for. Kept as a table so check
# [host-prereqs] can hold it and docs/DEPENDENCIES.md to the same list.
# name|blocking|why
HOST_REQUIRED='python3|yes|repository verification and host detection
git|yes|make adopt, the git_commit in a baked artifact, safe.directory
curl|no|make update-gpg fetches the archive signing keys
gpg|no|make update-gpg verifies those keys
xauth|no|GUI forwarding writes the X cookie the container reads
gh|no|make ci switches GitHub Actions on and off'
while IFS='|' read -r tool blocking why; do
    [ -n "$tool" ] || continue
    command -v "$tool" >/dev/null 2>&1 && continue
    if [ "$blocking" = yes ]; then
        log_error "${tool} is required on the host: ${why}."
        errors=$((errors + 1))
    else
        log_warn "${tool} not found: ${why}."
        warnings=$((warnings + 1))
    fi
done <<< "$HOST_REQUIRED"

# 1. Docker CLI presence
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker CLI not found in PATH."
    log_detail  "Install Docker Engine (native Linux) or Docker Desktop with WSL2 integration." >&2
    errors=$((errors + 1))
else
    # 2. Docker daemon reachability. The output is kept: the NVIDIA runtime
    # check below reads it too, and `docker info` costs ~300 ms a call.
    if ! docker_info="$(docker info 2>/dev/null)"; then
        log_error "Docker daemon is not reachable."
        log_detail  "Native Linux: 'sudo systemctl start docker' and add your user to the 'docker' group ('sudo usermod -aG docker \$USER', then re-login)." >&2
        log_detail  "WSL2: start Docker Desktop and enable integration for this distro." >&2
        errors=$((errors + 1))
    fi

    # 3. Compose v2 plugin (the Makefile invokes 'docker compose', not 'docker-compose')
    compose_version="$(docker compose version --short 2>/dev/null || true)"
    if [ -z "$compose_version" ]; then
        log_error "'docker compose' (Compose v2 plugin) is not available — this project requires it."
        if command -v docker-compose >/dev/null 2>&1; then
            log_detail "Found legacy 'docker-compose' (v1), which is NOT used. Install the Compose v2 plugin (package 'docker-compose-plugin')." >&2
        else
            log_detail "Install the Docker Compose v2 plugin (package 'docker-compose-plugin')." >&2
        fi
        errors=$((errors + 1))
    elif ! awk -F. '{gsub(/^v/, ""); exit !($1 > 2 || ($1 == 2 && $2 >= 24))}' <<< "$compose_version"; then
        log_error 'Docker Compose 2.24+ is required (include and service-scoped teardown).'
        errors=$((errors + 1))
    fi

    # 4. BuildKit (the Dockerfile uses --mount=type=cache/bind, which require BuildKit)
    if ! docker buildx version >/dev/null 2>&1 || [ "${DOCKER_BUILDKIT:-1}" = 0 ]; then
        log_error "BuildKit/buildx is required and must be enabled."
        log_detail "The Dockerfile requires BuildKit. Export DOCKER_BUILDKIT=1 or install the buildx plugin ('docker-buildx-plugin')." >&2
        errors=$((errors + 1))
    fi
fi

# The NVIDIA runtime, in ONE place. An explicit GPU_MODE=nvidia without it fails
# deep in docker with "could not select device driver", so refuse here; a GPU
# the detector saw (HAS_NVIDIA, exported by make) with auto merely warns, since
# auto falls back to the iGPU/CPU profile.
# The runtime NAME (docker info's Runtimes list), and only when the daemon
# answered at all: an unreachable daemon blamed the missing toolkit instead,
# and a host whose NAME contains 'nvidia' passed with no runtime at all.
docker_runtimes="$(timeout 10 docker info --format '{{range $r, $_ := .Runtimes}}{{$r}} {{end}}' 2>/dev/null || true)"
if command -v docker >/dev/null 2>&1 && [ -n "${docker_info:-}" ] && ! grep -qw nvidia <<< " ${docker_runtimes} "; then
    if [ "${GPU_MODE:-auto}" = nvidia ]; then
        log_error "GPU_MODE=nvidia, but Docker has no NVIDIA runtime (nvidia-container-toolkit)."
        log_detail  "Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker" >&2
        errors=$((errors + 1))
    elif [ "${HAS_NVIDIA:-false}" = true ]; then
        log_warn "NVIDIA GPU detected, but Docker has no NVIDIA runtime configured."
        log_detail "Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker" >&2
        log_detail "Until then DevKit falls back to the iGPU/CPU profile." >&2
        warnings=$((warnings + 1))
    fi
fi

if [ "$errors" -gt 0 ]; then
    log_error "Preflight failed: ${errors} blocking issue(s), ${warnings} warning(s). Resolve the above before 'make build'."
    exit 1
fi

if [ "$warnings" -gt 0 ]; then
    log_warn "Preflight passed with ${warnings} warning(s)."
else
    log_ok "Host prerequisites present (docker, compose v2, BuildKit, python3, git)."
fi
exit 0

#!/bin/bash
# =============================================================================
# scripts/check_preflight.sh
# Host toolchain preflight for `make build`.
#
# Purpose: fail fast with a CLEAR, actionable message instead of a cryptic error
# deep inside `docker compose` / BuildKit when host prerequisites are missing.
# This project hard-requires Docker + Compose v2 + BuildKit; on a fresh/minimal,
# older, or podman-only host `make build` would otherwise die with something like
# "docker: 'compose' is not a command" or "unknown flag: --mount".
#
# Exit codes: 0 = ok (warnings allowed), 1 = blocking prerequisite missing.
# GPU/NVIDIA specifics are intentionally left to `make check` to avoid
# duplicating that logic here.
# =============================================================================

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }  # host-only: never fall back to world-writable /tmp
devkit_require "util_logging.sh"
LOG_PREFIX="[Preflight]"

# Strip colour when piped/redirected or NO_COLOR is set (see util_logging.sh).
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

errors=0
warnings=0

# 1. Docker CLI presence
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker CLI not found in PATH."
    log_info  "Install Docker Engine (native Linux) or Docker Desktop with WSL2 integration."
    errors=$((errors + 1))
else
    # 2. Docker daemon reachability
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not reachable."
        log_info  "Native Linux: 'sudo systemctl start docker' and add your user to the 'docker' group ('sudo usermod -aG docker \$USER', then re-login)."
        log_info  "WSL2: start Docker Desktop and enable integration for this distro."
        errors=$((errors + 1))
    fi

    # 3. Compose v2 plugin (the Makefile invokes 'docker compose', not 'docker-compose')
    if ! docker compose version >/dev/null 2>&1; then
        log_error "'docker compose' (Compose v2 plugin) is not available — this project requires it."
        if command -v docker-compose >/dev/null 2>&1; then
            log_info "Found legacy 'docker-compose' (v1), which is NOT used. Install the Compose v2 plugin (package 'docker-compose-plugin')."
        else
            log_info "Install the Docker Compose v2 plugin (package 'docker-compose-plugin')."
        fi
        errors=$((errors + 1))
    fi

    # 4. BuildKit (the Dockerfile uses --mount=type=cache/bind, which require BuildKit)
    if ! docker buildx version >/dev/null 2>&1 && [ "${DOCKER_BUILDKIT:-1}" != "1" ]; then
        log_warn "BuildKit appears unavailable (no 'docker buildx' and DOCKER_BUILDKIT is not 1)."
        log_info "The Dockerfile requires BuildKit. Export DOCKER_BUILDKIT=1 or install the buildx plugin ('docker-buildx-plugin')."
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
    log_ok "Host toolchain preflight passed (docker, compose v2, BuildKit)."
fi
exit 0

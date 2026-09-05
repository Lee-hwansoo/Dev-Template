#!/bin/bash
# =============================================================================
# scripts/util_cuda_apt.sh — the CUDA/cuDNN apt profiles for the development and
# production images. A no-op unless HAS_NVIDIA=true and CUDA_VERSION is set.
# =============================================================================

set -euo pipefail

PROFILE="${1:-}"
HAS_NVIDIA="${HAS_NVIDIA:-false}"
CUDA_VERSION="${CUDA_VERSION:-}"
CUDNN_VERSION="${CUDNN_VERSION:-}"
FULL_CUDA="${FULL_CUDA:-false}"

is_truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_bool_value() {
    case "${1,,}" in
        1|0|true|false|yes|no|on|off) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: util_cuda_apt.sh dev|runtime

Installs CUDA/cuDNN apt packages when HAS_NVIDIA=true and CUDA_VERSION is set.
CUDNN_VERSION accepts a major version only, such as 8 or 9.
FULL_CUDA accepts 1, true, yes, or on.
Set DEVKIT_DRY_RUN=1 to print the selected package list without installing.
EOF
}

case "$PROFILE" in
    dev|runtime) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if ! is_bool_value "$HAS_NVIDIA"; then
    echo "[ERROR] HAS_NVIDIA must be a boolean value (1/0, true/false, yes/no, on/off): $HAS_NVIDIA" >&2
    exit 2
fi

if ! is_bool_value "$FULL_CUDA"; then
    echo "[ERROR] FULL_CUDA must be a boolean value (1/0, true/false, yes/no, on/off): $FULL_CUDA" >&2
    exit 2
fi

is_truthy "$HAS_NVIDIA" || exit 0
[ -n "$CUDA_VERSION" ] || exit 0

IFS=. read -r CUDA_MAJOR CUDA_MINOR _ <<< "$CUDA_VERSION"
for part in "$CUDA_MAJOR" "$CUDA_MINOR"; do
    case "$part" in
        ''|*[!0-9]*)
            echo "[ERROR] CUDA_VERSION must start with numeric major and minor components: $CUDA_VERSION" >&2
            exit 2
            ;;
    esac
done
CUDA_MAJOR_MINOR="${CUDA_MAJOR}-${CUDA_MINOR}"

PACKAGES=()
if is_truthy "$FULL_CUDA"; then
    PACKAGES=( "cuda-${CUDA_MAJOR_MINOR}" )
elif [ "$PROFILE" = "dev" ]; then
    PACKAGES=(
        "cuda-nvcc-${CUDA_MAJOR_MINOR}"
        "cuda-cudart-dev-${CUDA_MAJOR_MINOR}"
        "cuda-nvtx-${CUDA_MAJOR_MINOR}"
        "libcublas-dev-${CUDA_MAJOR_MINOR}"
        "cuda-nvml-dev-${CUDA_MAJOR_MINOR}"
    )
else
    PACKAGES=(
        "cuda-cudart-${CUDA_MAJOR_MINOR}"
        "cuda-nvtx-${CUDA_MAJOR_MINOR}"
        "libcublas-${CUDA_MAJOR_MINOR}"
    )
fi

if [ -n "$CUDNN_VERSION" ]; then
    case "$CUDNN_VERSION" in
        ''|*[!0-9]*)
            echo "[ERROR] CUDNN_VERSION must be a numeric major version, such as 8 or 9: $CUDNN_VERSION" >&2
            exit 2
            ;;
    esac
    if [ "$CUDNN_VERSION" -ge 9 ]; then
        PACKAGES+=( "libcudnn${CUDNN_VERSION}-cuda-${CUDA_MAJOR}" )
        [ "$PROFILE" = "dev" ] && PACKAGES+=( "libcudnn${CUDNN_VERSION}-dev-cuda-${CUDA_MAJOR}" )
    else
        PACKAGES+=( "libcudnn${CUDNN_VERSION}" )
        [ "$PROFILE" = "dev" ] && PACKAGES+=( "libcudnn${CUDNN_VERSION}-dev" )
    fi
fi

if [ "${DEVKIT_DRY_RUN:-}" = "1" ]; then
    printf '%s\n' "${PACKAGES[@]}"
    exit 0
fi

apt-get update
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

# Ensure the container uses the host driver through nvidia-container-runtime.
apt-get purge -y \
    "libnvidia-cfg[0-9]*" \
    "libnvidia-compute-[0-9]*" \
    "nvidia-compute-utils-[0-9]*" \
    "nvidia-persistenced" \
    "nvidia-utils-[0-9]*" \
    "libnvidia-extra-[0-9]*" || true

dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
    | awk '$1 == "ii" && $2 ~ /^(cuda-|gds-tools-|libcu(bl|d|ff|file|pti|rand|solver|sparse)|libnpp|libnv|nsight-)/ && $2 !~ /^(libnvidia|nvidia-)/ {print $2}' \
    | xargs -r apt-mark manual

ldconfig

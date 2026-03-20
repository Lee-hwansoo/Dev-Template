#!/bin/bash
# =============================================================================
# scripts/sync_deps.sh
# 서드파티 의존성 소스 코드 동기화 및 오버레이 병합 도구
#
# 기능:
#   1. vcstool(.repos)을 통한 외부 저장소 일괄 Import/Pull
#   2. dependencies/overlay/ 내부 파일의 타겟 워크스페이스 병합
#   3. rosdep 기반 누락된 시스템 의존성 자동 확인
# =============================================================================

# 로깅 유틸리티 로드
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sync Deps]"

# 1. 작업 공간 및 프로젝트 루트 감지 (Hierarchical Detection)
# 컨테이너 내 볼륨(/workspace) 우선, 그 외에는 스크립트 위치 기준 상위 탐색
if [ -d "/workspace/dependencies" ]; then
    PROJECT_ROOT="/workspace"
else
    # 스크립트(scripts/sync_deps.sh)로부터 상위 폴더를 루트로 간주
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# 2. 주요 경로 설정 (SSOT)
# SYNC_TARGET_DIR이 환경변수로 주입되었으면 이를 사용하고, 없으면 src/thirdparty를 기본값으로 사용
REPOS_FILE="${PROJECT_ROOT}/dependencies/dependencies.repos"
OVERLAY_DIR="${PROJECT_ROOT}/dependencies/overlay"
TARGET_DIR="${PROJECT_ROOT}/${SYNC_TARGET_DIR:-src/thirdparty}"

mkdir -p "$TARGET_DIR"

# 3. vcs 도구 확인 및 실행
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    vcs import "$TARGET_DIR" < "$REPOS_FILE" || log_warn "vcs import completed with some warnings."

    # 신규 추가된 저장소 확인 후 업데이트
    log_info "Performing vcs pull to update existing repositories..."
    vcs pull "$TARGET_DIR" || log_warn "vcs pull completed with some warnings."
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 3. 오버레이(Overlay) 적용
if [ -d "$OVERLAY_DIR" ]; then
    HAS_FILES=$(find "$OVERLAY_DIR" -mindepth 1 -not -name "*.md" | wc -l)
    if [ "$HAS_FILES" -gt 0 ]; then
        log_info "Applying overlays from $OVERLAY_DIR ..."
        cp -a "$OVERLAY_DIR/." "$TARGET_DIR/"
        log_ok "Overlays applied successfully."
    fi
fi

# 4. rosdep 패키지 종속성 해소 (ros2 타겟 전용)
# 기본적으로 생략하고 --rosdep 플래그가 있는 경우에만 실행
DO_ROSDEP=false
for arg in "$@"; do
    if [ "$arg" == "--rosdep" ]; then
        DO_ROSDEP=true
        break
    fi
done

if [ "$DO_ROSDEP" = true ] && command -v rosdep &>/dev/null && [ -n "${ROS_DISTRO}" ]; then
    log_info "Checking rosdep dependencies for ${TARGET_DIR}..."
    apt-get update -qq || true
    if ! rosdep install --from-paths "$TARGET_DIR" --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        log_warn "Some rosdep packages failed to install. Check the output above."
    else
        log_ok "rosdep check completed."
    fi
elif [ "$DO_ROSDEP" = false ] && command -v rosdep &>/dev/null; then
    log_info "Skipping rosdep install. (Use --rosdep to force check)"
fi

#!/bin/bash
# scripts/check_deps.sh
# 빌드 아티팩트의 런타임 공유 라이브러리 의존성 누락 여부 검사

TARGET_DIR=${1:-/workspace/install}
MISSING_COUNT=0

# 로깅 유틸리티 로드
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sanity Check]"

log_info "Scanning for missing dependencies in $TARGET_DIR..."

# 실행 파일 및 공유 라이브러리(.so) 찾기 - 프로세스 치환을 사용하여 MISSING_COUNT 값 보존
while IFS= read -r -d '' file; do
    # ELF 파일인지 확인 (바이너리 파일만 ldd 실행)
    if file "$file" | grep -qE 'ELF|shared object'; then
        MISSING=$(ldd "$file" 2>/dev/null | grep "not found")
        if [ -n "$MISSING" ]; then
            log_error "Missing dependencies for: $file\n$(echo "$MISSING" | sed 's/^/  /')"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
    fi
done < <(find "$TARGET_DIR" -type f \( -executable -o -name "*.so*" \) ! -name "*.py" -print0)

if [ $MISSING_COUNT -gt 0 ]; then
    log_error "$MISSING_COUNT files have missing dependencies."
    log_info "Please add missing packages to dependencies/apt.txt (with # runtime comment)."
    exit 1
else
    log_ok "All runtime dependencies are satisfied."
    exit 0
fi

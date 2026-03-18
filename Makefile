# =============================================================================
# ros2_docker_template/Makefile
# 원 커맨드 워크플로우 (KISS 기반 명령어 통합)
# =============================================================================

# 환경 변수 로드
-include .env

# 진단 엔진 연동 (자동 감지)
DETECTOR := bash scripts/env_detector.sh
$(foreach line,$(shell $(DETECTOR)),$(eval $(line)))

# TARGETARCH 자동 매칭
TARGETARCH ?= $(HOST_ARCH)
WORKSPACE_PATH ?= $(CURDIR)
export

COMPOSE := docker compose
COMPOSE_DEV := -f docker-compose.dev.yml
COMPOSE_PROD := -f docker-compose.prod.yml

# 매크로 (Deduplication & SSOT)
# GPU 모드 감지 로직 통합
DETECT_MODE := \
	CHOSEN_MODE=$(GPU_MODE); \
	if [ -z "$$CHOSEN_MODE" ] || [ "$$CHOSEN_MODE" = "auto" ]; then \
		if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then CHOSEN_MODE=nvidia; \
		elif [ "$(HAS_DRI)" = "true" ]; then CHOSEN_MODE=igpu; \
		else CHOSEN_MODE=cpu; fi; \
	elif [ "$$CHOSEN_MODE" = "intel" ] || [ "$$CHOSEN_MODE" = "amd" ]; then \
		CHOSEN_MODE=igpu; \
	fi;

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define RUN_SERVICE
	@$(DETECT_MODE) \
	PROF=$$CHOSEN_MODE; \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo "  [$$CHOSEN_MODE] $3 환경을 시작합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d $$TARGET_SVC
endef

# $1: ENV_VAR_NAME
define CHECK_ENV
	@if [ -z "$($1)" ]; then \
		echo "  [오류] $1 변수가 .env에 설정되어 있지 않습니다. 배포를 위해 반드시 필요합니다."; \
		exit 1; \
	fi
endef

define VALIDATE_ROS_ENV
	@if [ -n "$(ROS_DOMAIN_ID)" ]; then \
		if ! [ "$(ROS_DOMAIN_ID)" -eq "$(ROS_DOMAIN_ID)" ] 2>/dev/null || [ "$(ROS_DOMAIN_ID)" -lt 0 ] || [ "$(ROS_DOMAIN_ID)" -gt 101 ]; then \
			echo "  [오류] ROS_DOMAIN_ID는 0에서 101 사이의 숫자여야 합니다 (현재: $(ROS_DOMAIN_ID))"; \
			exit 1; \
		fi \
	fi
	@if [ -n "$(RMW_IMPLEMENTATION)" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_cyclonedds_cpp" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_fastrtps_cpp" ]; then \
		echo "  [경고] 비표준 RMW_IMPLEMENTATION이 감지되었습니다: $(RMW_IMPLEMENTATION)"; \
	fi
endef

define VALIDATE_COMPOSE_NAME
	@if echo "$(COMPOSE_PROJECT_NAME)" | grep -q '[A-Z[:space:]]'; then \
		echo "  [오류] COMPOSE_PROJECT_NAME은 소문자와 대시(-)/언더스코어(_)만 포함해야 합니다."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (오류 시 표시용)
define EXEC_CONTAINER
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER $2; \
	else \
		echo "  [오류] 실행 중인 $3 컨테이너가 없습니다."; \
		exit 1; \
	fi
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define SCALE_SERVICE
	@$(DETECT_MODE) \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo "  [$3] 서비스를 $(N)개로 확장합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d --scale $$TARGET_SVC=$(N) $$TARGET_SVC
endef

# 인프라 핵심 변수 export
export HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_ARCH TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY HOST_HOME DOCKER_VOL_MOUNT_ROOT NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES NVIDIA_GPU_COUNT HOST_CACHE_DIR

.PHONY: help setup check xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros dev ros-shell dev-shell ros-term dev-term \
		build-ros-prod build-dev-prod rebuild-ros-prod rebuild-dev-prod \
        ros-prod dev-prod \
        logs down clean clean-cache clean-all clean-builder \
        scale-basic scale-ros

# =============================================================================
# Default & Help
# =============================================================================
help:
	@echo "======================================================================"
	@echo "        🚀 All-in-One Docker Dev Environment Template 🚀              "
	@echo "======================================================================"
	@echo ""
	@echo "  [ 초기 설정 & 상태 (Setup & Status) ]"
	@echo "    make setup          : .env 초기화 및 기본 환경 구성 (최초 1회 실행)"
	@echo "    make status         : 현재 프로젝트 설정, GPU 가속, 디스플레이 상태 확인"
	@echo ""
	@echo "  [ 개발 환경 (Development) ]"
	@echo "    make ros            : ROS 개발 컨테이너 실행 (CPU/iGPU/NVIDIA 자동 감지)"
	@echo "    make ros-shell      : 실행 중인 ROS 컨테이너 셸 진입"
	@echo "    make ros-term       : 새 창(Terminator)으로 ROS 셸 실행"
	@echo "    make dev            : 순수 개발 컨테이너 실행 (CPU/iGPU/NVIDIA 자동 감지)"
	@echo "    make dev-shell      : 실행 중인 순수 개발 컨테이너 셸 진입"
	@echo "    make dev-term       : 새 창(Terminator)으로 순수 개발 셸 실행"
	@echo "    make build-ros      : ROS용 도커 이미지 빌드"
	@echo "    make build-dev      : 순수 개발용 도커 이미지 빌드"
	@echo "    make rebuild-ros    : 캐시 없이 ROS 이미지 전체 재빌드"
	@echo "    make rebuild-dev    : 캐시 없이 순수 개발용 도커 이미지 처음부터 다시 빌드"
	@echo "    make build-ros-prod : 배포용 ROS 이미지 빌드"
	@echo "    make build-dev-prod : 배포용 순수 개발 이미지 빌드"
	@echo "    make rebuild-ros-prod : 캐시 없이 배포용 ROS 이미지 빌드"
	@echo "    make rebuild-dev-prod : 캐시 없이 배포용 순수 개발 이미지 빌드"
	@echo ""
	@echo "  [ 배포 환경 (Production) ] - Bake & Switch 전략 기반 런타임"
	@echo "    make ros-prod       : 배포용 ROS 서비스 실행"
	@echo "    make dev-prod       : 배포용 순수 개발 서비스 실행"
	@echo ""
	@echo "  [ 유지보수 & 도구 (Maintenance) ]"
	@echo "    make logs           : 현재 실행 중인 컨테이너의 실시간 로그 스트리밍 (계속 감시, Ctrl+C로 종료)"
	@echo "    make down           : 실행 중인 모든 컨테이너 중지 및 제거"
	@echo "    make clean          : 빌드 결과물(build, install, log) 도커 볼륨 삭제"
	@echo "    make clean-cache    : 호스트 측 .docker_cache (ccache, uv) 완전 삭제"
	@echo "    make clean-builder  : 도커 빌드 캐시(BuildKit) 정리 (디스크 용량 확보)"
	@echo "    make clean-all      : 프로젝트 관련 모든 도커 리소스(볼륨/이미지) 완전 초기화"
	@echo ""
	@echo "  [ 수평 확장 (Scaling) ]"
	@echo "    make scale-basic N=2: 순수 개발 서비스를 N개로 확장"
	@echo "    make scale-ros N=2  : ROS 개발 서비스를 N개로 확장"
	@echo "======================================================================"

# =============================================================================
# 초기 설정 및 상태 확인
# =============================================================================
setup:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "  .env 파일이 생성되었습니다. 설정을 수정하세요."; \
	else \
		echo "  .env 파일이 이미 존재합니다."; \
	fi
	@$(MAKE) xauth

status: check
	@echo ""
	@echo "  [프로젝트 상태 정보]"
	@echo "  ---------------------------------------------------"
	@echo "  프로젝트 이름: $(COMPOSE_PROJECT_NAME)"
	@echo "  ROS 버전:      $(ROS_DISTRO)"
	@echo "  아키텍처:      $(HOST_ARCH) (Target: $(TARGETARCH))"
	@echo "  디스플레이:    $(DISPLAY) ($(DISPLAY_TYPE))"
	@echo "  ---------------------------------------------------"
	@echo "  [실행 중인 컨테이너]"
	@docker ps --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
	@echo "  ---------------------------------------------------"
	@echo "  [생성된 도커 볼륨]"
	@docker volume ls --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Name}}\t{{.Driver}}"
	@echo "  ---------------------------------------------------"
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		echo "  [NVIDIA GPU 상세]"; \
		nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | sed 's/^/  /'; \
	fi
	@echo ""

check-host:
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "false" ]; then \
		echo "  [경고] NVIDIA GPU가 감지되었으나 NVIDIA Container Toolkit이 없습니다."; \
	fi

xauth:
	@if [ "$(DISPLAY_TYPE)" = "X11" ] && [ -n "$(DISPLAY)" ]; then \
		if command -v xauth >/dev/null 2>&1; then \
			touch $(HOST_XAUTHORITY) 2>/dev/null || true; \
			xauth nlist $(DISPLAY) | sed -e 's/^..../ffff/' | xauth -f $(HOST_XAUTHORITY) nmerge - 2>/dev/null || true; \
		fi \
	fi
	@if command -v xhost >/dev/null 2>&1; then \
		xhost +local:root > /dev/null 2>&1 || true; \
	fi

check: check-host
	@if [ ! -f .env ]; then echo "  오류: .env가 없습니다. make setup 실행 필요"; exit 1; fi
	@if [ ! -d "$(WORKSPACE_PATH)" ]; then echo "  [오류] WORKSPACE_PATH($(WORKSPACE_PATH))가 존재하지 않는 디렉토리입니다."; exit 1; fi
	$(call VALIDATE_COMPOSE_NAME)
	$(call VALIDATE_ROS_ENV)
	@mkdir -p ~/.ssh && touch ~/.gitconfig
	@if [ ! -f $(HOST_XAUTHORITY) ]; then touch $(HOST_XAUTHORITY) 2>/dev/null || true; fi

# 빌드 (Build)
# =============================================================================
build-ros: check
	@$(DETECT_MODE) \
	TARGET_SVC=ros-$$CHOSEN_MODE; \
	echo "  [Build] ROS 이미지를 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_DEV) build $$TARGET_SVC
	@echo "\n[Hint] 빌드가 완료되었습니다! 'make ros'를 실행하여 컨테이너를 시작하세요."

build-dev: check
	@$(DETECT_MODE) \
	TARGET_SVC=basic-$$CHOSEN_MODE; \
	echo "  [Build] 순수 개발 이미지를 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_DEV) build $$TARGET_SVC
	@echo "\n[Hint] 빌드가 완료되었습니다! 'make dev'를 실행하여 컨테이너를 시작하세요."

rebuild-ros: check
	@$(DETECT_MODE) \
	TARGET_SVC=ros-$$CHOSEN_MODE; \
	echo "  [Rebuild] 캐시 없이 ROS 이미지를 처음부터 다시 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_DEV) build --no-cache $$TARGET_SVC
	@echo "\n[Hint] 빌드가 완료되었습니다! 'make ros'를 실행하여 컨테이너를 시작하세요."

rebuild-dev: check
	@$(DETECT_MODE) \
	TARGET_SVC=basic-$$CHOSEN_MODE; \
	echo "  [Rebuild] 캐시 없이 순수 개발 이미지를 처음부터 다시 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_DEV) build --no-cache $$TARGET_SVC
	@echo "\n[Hint] 빌드가 완료되었습니다! 'make dev'를 실행하여 컨테이너를 시작하세요."

build-ros-prod: check
	@$(DETECT_MODE) \
	TARGET_SVC=ros-$$CHOSEN_MODE; \
	$(COMPOSE) $(COMPOSE_PROD) build $$TARGET_SVC
	@echo "\n  [Hint] 배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make ros-prod'로 실행하세요."

build-dev-prod: check
	@$(DETECT_MODE) \
	TARGET_SVC=basic-$$CHOSEN_MODE; \
	echo "  [Bake] 배포용 순수 개발 이미지를 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_PROD) build $$TARGET_SVC
	@echo "\n  [Hint] 배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make dev-prod'로 실행하세요."

rebuild-ros-prod: check
	@$(DETECT_MODE) \
	TARGET_SVC=ros-$$CHOSEN_MODE; \
	echo "  [Rebuild] 캐시 없이 배포용 ROS 이미지를 처음부터 다시 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_PROD) build --no-cache $$TARGET_SVC
	@echo "\n  [Hint] 배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make ros-prod'로 실행하세요."

rebuild-dev-prod: check
	@$(DETECT_MODE) \
	TARGET_SVC=basic-$$CHOSEN_MODE; \
	echo "  [Rebuild] 캐시 없이 배포용 순수 개발 이미지를 처음부터 다시 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $(COMPOSE_PROD) build --no-cache $$TARGET_SVC
	@echo "\n  [Hint] 배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make dev-prod'로 실행하세요."

# =============================================================================
# 실행 및 셸 진입 (Dev) - 자동 GPU 감지
# =============================================================================
ros: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),ros,ROS 개발)
	@echo "\n  [Hint] 컨테이너가 시작되었습니다! 컨테이너 접속을 위해 'make ros-shell' 또는 'make ros-term'을 사용하세요."

dev: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),basic,순수 개발)
	@echo "\n  [Hint] 컨테이너가 시작되었습니다! 컨테이너 접속을 위해 'make dev-shell' 또는 'make dev-term'을 사용하세요."

# 필터 정의
ROS_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]ros-(cpu|igpu|nvidia)
DEV_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]basic-(cpu|igpu|nvidia)

ros-shell: check
	$(call EXEC_CONTAINER,$(ROS_FILTER),bash,ROS)

ros-term: check xauth
	$(call EXEC_CONTAINER,$(ROS_FILTER),terminator,ROS)

dev-shell: check
	$(call EXEC_CONTAINER,$(DEV_FILTER),bash,개발)

dev-term: check xauth
	$(call EXEC_CONTAINER,$(DEV_FILTER),terminator,개발)

# 수평 확장 (Scaling)
scale-basic: check
	@if [ -z "$(N)" ]; then echo "  [오류] 확장할 개수 N을 지정하세요. (예: make scale-basic N=2)"; exit 1; fi
	$(call SCALE_SERVICE,$(COMPOSE_DEV),basic,개발)

scale-ros: check
	@if [ -z "$(N)" ]; then echo "  [오류] 확장할 개수 N을 지정하세요. (예: make scale-ros N=2)"; exit 1; fi
	$(call SCALE_SERVICE,$(COMPOSE_DEV),ros,ROS)

# =============================================================================
# 배포 실행 (Prod) - 자동 GPU 감지
# =============================================================================
ros-prod: check xauth
	$(call CHECK_ENV,ROS_LAUNCH_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),ros,ROS 배포)
	@$(MAKE) logs

dev-prod: check xauth
	$(call CHECK_ENV,APP_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),basic,순수 배포)
	@$(MAKE) logs

# =============================================================================
# 유지보수
# =============================================================================
down:
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down --remove-orphans
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down --remove-orphans 2>/dev/null || true; \
	fi

logs:
	@if [ -n "$$($(COMPOSE) $(COMPOSE_DEV) ps --status running -q 2>/dev/null)" ]; then \
		echo "  [Dev] 개발 환경 로그를 스트리밍합니다..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
	elif [ -f docker-compose.prod.yml ] && [ -n "$$($(COMPOSE) $(COMPOSE_PROD) ps --status running -q 2>/dev/null)" ]; then \
		echo "  [Prod] 배포 환경 로그를 스트리밍합니다..."; \
		$(COMPOSE) $(COMPOSE_PROD) logs -f --tail 100; \
	fi

clean-builder:
	@echo "  Docker BuildKit 캐시를 정리하여 용량을 확보합니다..."
	docker builder prune -f

clean:
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down -v --remove-orphans
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down -v --remove-orphans 2>/dev/null || true; \
	fi
	@echo "  $(COMPOSE_PROJECT_NAME) 관련 모든 네임드 볼륨을 삭제합니다..."
	@VOLUMES=$$(docker volume ls -q --filter "name=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$VOLUMES" ]; then \
		docker volume rm $$VOLUMES 2>/dev/null || true; \
	fi

clean-cache:
	@CACHE_DIR=$(HOST_CACHE_DIR); \
	if [ -z "$$CACHE_DIR" ] || [ "$$CACHE_DIR" = "/" ] || ! (echo "$$CACHE_DIR" | grep -q "$(COMPOSE_PROJECT_NAME)" || echo "$$CACHE_DIR" | grep -q "$(WORKSPACE_PATH)"); then \
		echo "  [오류] 캐시 경로($$CACHE_DIR)가 유효하지 않거나 안전하지 않습니다."; \
		exit 1; \
	fi; \
	if [ -d "$$CACHE_DIR" ]; then \
		echo "  호스트 측 도커 캐시 폴더($$CACHE_DIR)를 정말 삭제하시겠습니까? [y/N]"; \
		read ans && if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo "  삭제를 취소합니다."; exit 1; fi; \
		echo "  호스트 측 도커 캐시 폴더($$CACHE_DIR)를 삭제합니다..."; \
		sudo rm -rf "$$CACHE_DIR"; \
	fi

clean-all: clean clean-cache
	@echo "  $(COMPOSE_PROJECT_NAME) 관련 모든 도커 빌드 캐시를 정리합니다..."
	docker builder prune -a -f

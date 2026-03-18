# =============================================================================
# ros2_docker_template/Makefile
# 원 커맨드 워크플로우 (KISS 기반 명령어 통합)
#
# 주요 명령어:
#   make setup       — 초기 설정 (최초 1회)
#   make ros         — ROS 개발 환경 시작 (NVIDIA 자동 감지)
#   make dev         — 순수 개발 환경 시작 (NVIDIA 자동 감지)
#   make ros-prod    — ROS 배포 환경 시작
#   make dev-prod    — 순수 배포 환경 시작
#   make status      — 프로젝트 및 GPU 상태 확인
# =============================================================================

# 진단 엔진 연동 (자동 감지)
DETECTOR := bash scripts/env_detector.sh
$(foreach line,$(shell $(DETECTOR)),$(eval $(line)))

# TARGETARCH 자동 매칭
TARGETARCH := $(HOST_ARCH)

# 환경 변수 로드 (.env 설정이 자동 감지값보다 우선하도록 나중에 로드)
-include .env
export

COMPOSE := docker compose
COMPOSE_DEV := -f docker-compose.dev.yml
COMPOSE_PROD := -f docker-compose.prod.yml

# 인프라 핵심 변수 export
export HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_ARCH TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY

.PHONY: help setup check xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros dev ros-shell dev-shell ros-term dev-term \
        ros-prod dev-prod \
        clean clean-cache clean-all clean-builder

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
	@echo "  [ 개발 환경 (Development) ] - GPU 및 GUI(X11/Wayland) 자동 감지 적용"
	@echo "    make ros            : ROS 개발 컨테이너 백그라운드 실행"
	@echo "    make ros-shell      : 실행 중인 ROS 컨테이너 셸(bash) 진입"
	@echo "    make ros-term       : 새 창(Terminator)으로 ROS 셸 실행 (GUI 필수)"
	@echo "    make dev            : 순수 C++/Python 컨테이너 백그라운드 실행 (ROS 미포함)"
	@echo "    make dev-shell      : 실행 중인 순수 개발 컨테이너 셸(bash) 진입"
	@echo "    make dev-term       : 새 창(Terminator)으로 순수 개발 셸 실행 (GUI 필수)"
	@echo "    make build-ros      : ROS용 도커 이미지 빌드"
	@echo "    make build-dev      : 순수 개발용 도커 이미지 빌드"
	@echo ""
	@echo "  [ 배포 환경 (Production) ] - Bake & Switch 전략 기반 런타임"
	@echo "    make ros-prod       : 배포용 ROS 서비스 실행"
	@echo "    make dev-prod       : 배포용 순수 C++/Python 서비스 실행"
	@echo ""
	@echo "  [ 유지보수 & 도구 (Maintenance) ]"
	@echo "    make logs           : 현재 실행 중인 컨테이너의 실시간 로그 스트리밍 (계속 감시, Ctrl+C로 종료)"
	@echo "    make down           : 실행 중인 모든 컨테이너 중지 및 제거"
	@echo "    make clean          : 빌드 결과물(build, install, log) 도커 볼륨 삭제"
	@echo "    make clean-cache    : 호스트 측 .docker_cache (ccache, uv) 완전 삭제"
	@echo "    make clean-builder  : 도커 빌드 캐시(BuildKit) 정리 (디스크 용량 확보)"
	@echo "    make clean-all      : 프로젝트 관련 모든 도커 리소스(볼륨/이미지) 완전 초기화"
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
	@if [ "$(DISPLAY_TYPE)" = "Wayland" ]; then \
		echo "  Wayland 소켓:  $(HOST_XDG_RUNTIME_DIR)/$(HOST_WAYLAND_DISPLAY)"; \
		if [ ! -S "$(HOST_XDG_RUNTIME_DIR)/$(HOST_WAYLAND_DISPLAY)" ]; then \
			echo "  [경고] Wayland 소켓 파일을 찾을 수 없습니다."; \
		fi \
	fi
	@echo "  ---------------------------------------------------"
	@echo "  [GPU 가속 상태]"
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		echo "  NVIDIA GPU:     검출됨"; \
		if [ "$(HAS_TOOLKIT)" = "true" ]; then \
			echo "  Docker 런타임:  NVIDIA Container Toolkit 활성"; \
		else \
			echo "  Docker 런타임:  [경고] NVIDIA Container Toolkit 미검출 (CPU 모드로 동작)"; \
		fi \
	else \
		echo "  GPU 가속:       기본 모드 (Intel/AMD/CPU)"; \
	fi
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
		echo "  설치 안내: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"; \
	fi
	@if [ -n "$(DISPLAY)" ] && ! xhost > /dev/null 2>&1; then \
		echo "  [경고] X11 권한 확인 불가. xhost +local:root 실행이 필요할 수 있습니다."; \
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
	@mkdir -p ~/.ssh && touch ~/.gitconfig
	@if [ ! -f $(HOST_XAUTHORITY) ]; then touch $(HOST_XAUTHORITY) 2>/dev/null || true; fi

# 빌드 (Build)
# =============================================================================
build-ros: check
	$(COMPOSE) $(COMPOSE_DEV) build ros-basic

build-dev: check
	$(COMPOSE) $(COMPOSE_DEV) build basic

rebuild-ros: check
	$(COMPOSE) $(COMPOSE_DEV) build --no-cache ros-basic

rebuild-dev: check
	$(COMPOSE) $(COMPOSE_DEV) build --no-cache basic

# =============================================================================
# 실행 및 셸 진입 (Dev) - 자동 GPU 감지
# =============================================================================
ros: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 ROS 환경을 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) $(COMPOSE_DEV) --profile ros-nvidia up -d ros-nvidia; \
	elif [ "$(HAS_DRI)" = "true" ]; then \
		echo "  iGPU(Intel/AMD) 가속 모드로 ROS 환경을 시작합니다..."; \
		GPU_MODE=igpu $(COMPOSE) $(COMPOSE_DEV) --profile ros-igpu up -d ros-igpu; \
	else \
		echo "  기본 모드로 ROS 환경을 시작합니다..."; \
		$(COMPOSE) $(COMPOSE_DEV) up -d ros-basic; \
	fi
	@echo "  셸 진입: make ros-shell (기존 창) 또는 make ros-term (새 창)"

dev: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 순수 개발 환경을 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) $(COMPOSE_DEV) --profile nvidia up -d nvidia; \
	elif [ "$(HAS_DRI)" = "true" ]; then \
		echo "  iGPU(Intel/AMD) 가속 모드로 순수 개발 환경을 시작합니다..."; \
		GPU_MODE=igpu $(COMPOSE) $(COMPOSE_DEV) --profile igpu up -d basic-igpu; \
	else \
		echo "  기본 모드로 순수 개발 환경을 시작합니다..."; \
		$(COMPOSE) $(COMPOSE_DEV) up -d basic; \
	fi
	@echo "  셸 진입: make dev-shell (기존 창) 또는 make dev-term (새 창)"

# 필터 정의 (Go 정규식 준수)
ROS_FILTER := $(COMPOSE_PROJECT_NAME)_ros
DEV_FILTER := $(COMPOSE_PROJECT_NAME)_(basic|nvidia)

ros-shell: check
	@CONTAINER=$$(docker ps --filter "name=$(ROS_FILTER)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER bash; \
	else \
		echo "  실행 중인 ROS 컨테이너가 없습니다. make ros를 먼저 실행하세요."; \
	fi

ros-term: check xauth
	@CONTAINER=$$(docker ps --filter "name=$(ROS_FILTER)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo "  새 창(Terminator)을 엽니다..."; \
		docker exec -d $$CONTAINER terminator; \
	else \
		echo "  실행 중인 ROS 컨테이너가 없습니다. make ros를 먼저 실행하세요."; \
	fi

dev-shell: check
	@CONTAINER=$$(docker ps --filter "name=$(DEV_FILTER)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER bash; \
	else \
		echo "  실행 중인 개발 컨테이너가 없습니다. make dev를 먼저 실행하세요."; \
	fi

dev-term: check xauth
	@CONTAINER=$$(docker ps --filter "name=$(DEV_FILTER)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo "  새 창(Terminator)을 엽니다..."; \
		docker exec -d $$CONTAINER terminator; \
	else \
		echo "  실행 중인 개발 컨테이너가 없습니다. make dev를 먼저 실행하세요."; \
	fi

# =============================================================================
# 배포 실행 (Prod) - 자동 GPU 감지
# =============================================================================
ros-prod: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 ROS 배포 서비스를 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) $(COMPOSE_PROD) up -d --profile ros-nv; \
	elif [ "$(HAS_DRI)" = "true" ]; then \
		echo "  iGPU(Intel/AMD) 가속 모드로 ROS 배포 서비스를 시작합니다..."; \
		GPU_MODE=igpu $(COMPOSE) $(COMPOSE_PROD) up -d --profile ros-igpu; \
	else \
		echo "  기본 모드로 ROS 배포 서비스를 시작합니다..."; \
		GPU_MODE=cpu $(COMPOSE) $(COMPOSE_PROD) up -d --profile ros; \
	fi
	@$(MAKE) logs

dev-prod: check xauth
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then \
		echo "  NVIDIA 모드로 순수 배포 서비스를 시작합니다..."; \
		GPU_MODE=nvidia $(COMPOSE) $(COMPOSE_PROD) up -d --profile dev-nv; \
	elif [ "$(HAS_DRI)" = "true" ]; then \
		echo "  iGPU(Intel/AMD) 가속 모드로 순수 배포 서비스를 시작합니다..."; \
		GPU_MODE=igpu $(COMPOSE) $(COMPOSE_PROD) up -d --profile dev-igpu; \
	else \
		echo "  기본 모드로 순수 배포 서비스를 시작합니다..."; \
		GPU_MODE=cpu $(COMPOSE) $(COMPOSE_PROD) up -d --profile dev; \
	fi
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
	else \
		echo "  [Dev] 개발 환경 로그를 스트리밍합니다..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
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
	@CACHE_DIR=$(DOCKER_DEV_CACHE_DIR); \
	if [ -z "$$CACHE_DIR" ]; then CACHE_DIR=$(WORKSPACE_PATH)/.docker_cache; fi; \
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

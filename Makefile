# =============================================================================
# ros2_docker_template/Makefile
# 원 커맨드 워크플로우 (KISS 기반 명령어 통합)
# =============================================================================

SHELL := /bin/bash

# 색상 및 로깅 정의
BLUE   := \033[0;34m
GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
NC     := \033[0m
INFO   := $(CYAN)[INFO]$(NC)
OK     := $(GREEN)[OK]$(NC)
WARN   := $(YELLOW)[WARN]$(NC)
ERROR  := $(RED)[ERROR]$(NC)

# 환경 변수 로드
-include .env

# 진단 엔진 연동 (자동 감지 - 필요한 타겟에서만 실행)
# help, setup, env-check와 같은 로컬 도구 외에 모든 도커 관련 타겟에 적용
NEEDS_DETECTOR := $(filter-out help setup env-check%,$(MAKECMDGOALS))
ifneq ($(NEEDS_DETECTOR),)
$(foreach line,$(shell bash scripts/env_detector.sh),$(eval $(line)))
endif

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
	echo -e "  $(INFO) [$$CHOSEN_MODE] $3 환경을 시작합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d $$TARGET_SVC
endef

# $1: ENV_VAR_NAME
define CHECK_ENV
	@if [ -z "$($1)" ]; then \
		echo -e "  $(ERROR) $1 변수가 .env에 설정되어 있지 않습니다. 배포를 위해 반드시 필요합니다."; \
		exit 1; \
	fi
endef

define VALIDATE_ROS_ENV
	@if [ -n "$(ROS_DOMAIN_ID)" ]; then \
		if ! [ "$(ROS_DOMAIN_ID)" -eq "$(ROS_DOMAIN_ID)" ] 2>/dev/null || [ "$(ROS_DOMAIN_ID)" -lt 0 ] || [ "$(ROS_DOMAIN_ID)" -gt 101 ]; then \
			echo -e "  $(ERROR) ROS_DOMAIN_ID는 0에서 101 사이의 숫자여야 합니다 (현재: $(ROS_DOMAIN_ID))"; \
			exit 1; \
		fi \
	fi
	@if [ -n "$(RMW_IMPLEMENTATION)" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_cyclonedds_cpp" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_fastrtps_cpp" ]; then \
		echo -e "  $(WARN) 비표준 RMW_IMPLEMENTATION이 감지되었습니다: $(RMW_IMPLEMENTATION)"; \
	fi
endef

define VALIDATE_COMPOSE_NAME
	@if echo "$(COMPOSE_PROJECT_NAME)" | grep -q '[^a-z0-9_-]'; then \
		echo -e "  $(ERROR) COMPOSE_PROJECT_NAME은 소문자와 대시(-)/언더스코어(_)만 포함해야 합니다."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (오류 시 표시용)
define EXEC_CONTAINER
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER $2 || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) 실행 중인 $3 컨테이너가 없습니다."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (오류 시 표시용)
define EXEC_DETACHED
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER $2 || [ $$? -eq 130 ]; \
	else \
		echo "  [오류] 실행 중인 $3 컨테이너가 없습니다."; \
		exit 1; \
	fi
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define SCALE_SERVICE
	@$(DETECT_MODE) \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) [$3] 서비스를 $(N)개로 확장합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d --scale $$TARGET_SVC=$(N) $$TARGET_SVC
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG, $4: EXTRA_ARGS, $5: HINT_MSG
define BUILD_SERVICE
	@$(DETECT_MODE) \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) [$3] 이미지를 빌드합니다 (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 build $4 $$TARGET_SVC
	@echo -e "\n  $(INFO) [Hint] $5"
endef

# 인프라 핵심 변수 export
export HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_ARCH TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY HOST_HOME NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES NVIDIA_GPU_COUNT HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_SSH_DIR

.PHONY: help setup check check-host xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros ros-restart dev dev-restart ros-shell dev-shell ros-term dev-term \
		build-ros-prod build-dev-prod rebuild-ros-prod rebuild-dev-prod \
        ros-prod dev-prod \
		save-ros save-dev load-ros load-dev \
        stats top logs down clean clean-cache clean-all docker-clean env-check \
        scale-basic scale-ros

# =============================================================================
# Default & Help
# =============================================================================
help:
	@echo "======================================================================"
	@echo "            All-in-One Docker Dev Environment Template                "
	@echo "======================================================================"
	@echo ""
	@echo "  [ 초기 설정 & 상태 (Setup & Status) ]"
	@echo "    make setup          : .env 초기화 및 기본 환경 구성 (최초 1회 실행)"
	@echo "    make status         : 현재 프로젝트 설정, GPU 가속, 디스플레이 상태 확인"
	@echo ""
	@echo "  [ 개발 환경 (ROS) ]"
	@echo "    make ros            : ROS 개발 컨테이너 실행 (CPU/iGPU/NVIDIA 자동 감지)"
	@echo "    make ros-restart    : ROS 서비스 안전하게 재시작"
	@echo "    make ros-shell      : 실행 중인 ROS 컨테이너 셸 진입"
	@echo "    make ros-term       : 새 창(Terminator)으로 ROS 셸 실행"
	@echo "    make build-ros      : ROS용 도커 이미지 빌드"
	@echo "    make rebuild-ros    : 캐시 없이 ROS 이미지 전체 재빌드"
	@echo "    make build-ros-prod : 배포용 ROS 이미지 빌드"
	@echo "    make rebuild-ros-prod : 캐시 없이 배포용 ROS 이미지 빌드"
	@echo ""
	@echo "  [ 개발 환경 (Pure Dev) ]"
	@echo "    make dev            : 순수 개발 컨테이너 실행 (CPU/iGPU/NVIDIA 자동 감지)"
	@echo "    make dev-restart    : 순수 개발 서비스 안전하게 재시작"
	@echo "    make dev-shell      : 실행 중인 순수 개발 컨테이너 셸 진입"
	@echo "    make dev-term       : 새 창(Terminator)으로 순수 개발 셸 실행"
	@echo "    make build-dev      : 순수 개발용 도커 이미지 빌드"
	@echo "    make rebuild-dev    : 캐시 없이 순수 개발용 도커 이미지 처음부터 다시 빌드"
	@echo "    make build-dev-prod : 배포용 순수 개발 이미지 빌드"
	@echo "    make rebuild-dev-prod : 캐시 없이 배포용 순수 개발 이미지 빌드"
	@echo ""
	@echo "  [ 배포 환경 (Production) ] - Bake & Switch 전략 기반 런타임"
	@echo "    make ros-prod       : 배포용 ROS 서비스 실행"
	@echo "    make save-ros       : 배포용 ROS 이미지를 압축파일로 추출"
	@echo "    make load-ros       : 압축파일에서 ROS 이미지 복원"
	@echo "    make dev-prod       : 배포용 순수 개발 서비스 실행"
	@echo "    make save-dev       : 배포용 ROS 이미지를 압축파일로 추출"
	@echo "    make load-dev       : 압축파일에서 ROS 이미지 복원"
	@echo ""
	@echo "  [ 유지보수 & 도구 (Maintenance) ]"
	@echo "    make stats          : 시스템 전체 가용 자원(CPU/Mem/GPU) 실시간 모니터링"
	@echo "    make top            : 프로젝트 컨테이너 기반 상세 모니터링 (CPU 코어/GPU 프로세스)"
	@echo "    make logs           : 현재 실행 중인 컨테이너의 실시간 로그 스트리밍 (계속 감시, Ctrl+C로 종료)"
	@echo "    make down           : 실행 중인 모든 컨테이너 중지 및 제거"
	@echo "    make clean          : 빌드 결과물(build, install, log) 도커 볼륨 삭제"
	@echo "    make clean-cache    : 호스트 측 .docker_cache (ccache, uv, apt) 완전 삭제"
	@echo "    make clean-all      : 프로젝트 관련 모든 도커 리소스(이미지/볼륨/캐시) 완전 초기화"
	@echo "    make docker-clean   : 도커 시스템 전역 정리 (시스템 전체 빌드 캐시 및 미사용 이미지 삭제)"
	@echo "    make env-check      : .env 설정 누락 여부 확인 (.env.example 기준)"
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
		echo -e "  $(OK) .env 파일이 생성되었습니다. 설정을 수정하세요."; \
	else \
		echo -e "  $(INFO) .env 파일이 이미 존재합니다."; \
	fi
	@$(MAKE) xauth

status: check
	@echo "  [프로젝트 상태 정보]"
	@echo "  ---------------------------------------------------"
	@echo "  프로젝트 이름: $(COMPOSE_PROJECT_NAME)"
	@echo "  ROS 버전:      $(ROS_DISTRO)"
	@echo "  아키텍처:      $(HOST_ARCH) (Target: $(TARGETARCH))"
	@echo "  디스플레이:    $(DISPLAY) ($(DISPLAY_TYPE))"
	@echo "  GPU 모드(설정): $(GPU_MODE)"
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

check-host:
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "false" ]; then \
		echo -e "  $(WARN) NVIDIA GPU가 감지되었으나 NVIDIA Container Toolkit이 없습니다."; \
	fi

xauth:
	@if [ "$(DISPLAY_TYPE)" = "X11" ] && [ -n "$(DISPLAY)" ]; then \
		if command -v xauth >/dev/null 2>&1; then \
			touch $(HOST_XAUTHORITY) 2>/dev/null || true; \
			xauth nlist $(DISPLAY) | sed -e 's/^..../ffff/' | xauth -f $(HOST_XAUTHORITY) nmerge - 2>/dev/null || true; \
		fi; \
	fi
	@if [ -n "$(DISPLAY)" ] && command -v xhost >/dev/null 2>&1; then \
		xhost +local:root > /dev/null 2>&1 || true; \
	fi

check: check-host
	@if [ ! -f .env ]; then echo -e "  $(ERROR) .env가 없습니다. make setup 실행 필요"; exit 1; fi
	@if [ ! -d "$(WORKSPACE_PATH)" ]; then echo -e "  $(ERROR) WORKSPACE_PATH($(WORKSPACE_PATH))가 존재하지 않는 디렉토리입니다."; exit 1; fi
	$(call VALIDATE_COMPOSE_NAME)
	$(call VALIDATE_ROS_ENV)

# 빌드 (Build)
# =============================================================================
build-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,Build ROS,,"빌드가 완료되었습니다! 'make ros'를 실행하여 컨테이너를 시작하세요.")

build-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Build 순수 개발,,"빌드가 완료되었습니다! 'make dev'를 실행하여 컨테이너를 시작하세요.")

rebuild-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,Rebuild 캐시 없이 ROS,--no-cache,"빌드가 완료되었습니다! 'make ros'를 실행하여 컨테이너를 시작하세요.")

rebuild-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Rebuild 캐시 없이 순수 개발,--no-cache,"빌드가 완료되었습니다! 'make dev'를 실행하여 컨테이너를 시작하세요.")

build-ros-prod: check
	@echo -e "  $(INFO) [Notice] 최상의 빌드 품질을 위해 'make clean'을 먼저 수행하는 것이 권장됩니다 (현재 빌드 시작...)"
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Bake 배포용 ROS,,"배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make ros-prod'로 실행하세요.")

build-dev-prod: check
	@echo -e "  $(INFO) [Notice] 최상의 빌드 품질을 위해 'make clean'을 먼저 수행하는 것이 권장됩니다 (현재 빌드 시작...)"
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Bake 배포용 순수 개발,,"배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make dev-prod'로 실행하세요.")

rebuild-ros-prod: check
	@echo -e "  $(INFO) [Notice] 최상의 빌드 품질을 위해 'make clean'을 먼저 수행하는 것이 권장됩니다 (현재 빌드 시작...)"
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Rebuild 캐시 없이 배포용 ROS,--no-cache,"배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make ros-prod'로 실행하세요.")

rebuild-dev-prod: check
	@echo -e "  $(INFO) [Notice] 최상의 빌드 품질을 위해 'make clean'을 먼저 수행하는 것이 권장됩니다 (현재 빌드 시작...)"
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Rebuild 캐시 없이 배포용 순수 개발,--no-cache,"배포용 이미지가 빌드되었습니다! 'docker save'로 추출하거나 'make dev-prod'로 실행하세요.")

# =============================================================================
# 실행 및 셸 진입 (Dev) - 자동 GPU 감지
# =============================================================================
ros: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),ros,ROS 개발)
	@echo -e "\n  $(INFO) [Hint] 컨테이너가 시작되었습니다! 컨테이너 접속을 위해 'make ros-shell' 또는 'make ros-term'을 사용하세요."

dev: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),basic,순수 개발)
	@echo -e "\n  $(INFO) [Hint] 컨테이너가 시작되었습니다! 컨테이너 접속을 위해 'make dev-shell' 또는 'make dev-term'을 사용하세요."

# 서비스 개별 재시작
ros-restart: down ros
dev-restart: down dev

# 필터 정의
ROS_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]ros-(cpu|igpu|nvidia)
DEV_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]basic-(cpu|igpu|nvidia)

ros-shell: check
	$(call EXEC_CONTAINER,$(ROS_FILTER),bash,ROS)

ros-term: check xauth
	$(call EXEC_DETACHED,$(ROS_FILTER),terminator,ROS)

dev-shell: check
	$(call EXEC_CONTAINER,$(DEV_FILTER),bash,개발)

dev-term: check xauth
	$(call EXEC_DETACHED,$(DEV_FILTER),terminator,개발)

# 수평 확장 (Scaling)
scale-basic: check
	@if [ -z "$(N)" ]; then echo -e "  $(ERROR) 확장할 개수 N을 지정하세요. (예: make scale-basic N=2)"; exit 1; fi
	$(call SCALE_SERVICE,$(COMPOSE_DEV),basic,개발)

scale-ros: check
	@if [ -z "$(N)" ]; then echo -e "  $(ERROR) 확장할 개수 N을 지정하세요. (예: make scale-ros N=2)"; exit 1; fi
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

# 이미지 추출 및 복원 전략
IMAGE_SUFFIX := $(if $(filter humble,$(ROS_DISTRO)),humble,$(if $(filter noetic,$(ROS_DISTRO)),noetic,latest))
SAVE_NAME_ROS := $(COMPOSE_PROJECT_NAME)-ros-$(IMAGE_SUFFIX).tar.gz
SAVE_NAME_DEV := $(COMPOSE_PROJECT_NAME)-dev-$(IMAGE_SUFFIX).tar.gz

save-ros:
	@echo -e "  $(INFO) ROS 배포용 이미지를 추출합니다: $(SAVE_NAME_ROS)..."
	@docker save $(COMPOSE_PROJECT_NAME)/ros-runtime:latest | gzip > $(SAVE_NAME_ROS)
	@echo -e "  $(OK) 완료: $$(du -h $(SAVE_NAME_ROS)) (Path: ./${SAVE_NAME_ROS})"

save-dev:
	@echo -e "  $(INFO) 순수 개발 배포용 이미지를 추출합니다: $(SAVE_NAME_DEV)..."
	@docker save $(COMPOSE_PROJECT_NAME)/dev-runtime:latest | gzip > $(SAVE_NAME_DEV)
	@echo -e "  $(OK) 완료: $$(du -h $(SAVE_NAME_DEV)) (Path: ./${SAVE_NAME_DEV})"

load-ros:
	@if [ ! -f $(SAVE_NAME_ROS) ]; then echo -e "  $(ERROR) 파일이 없습니다: $(SAVE_NAME_ROS)"; exit 1; fi
	@echo -e "  $(INFO) ROS 이미지를 복원합니다..."
	@docker load < $(SAVE_NAME_ROS)

load-dev:
	@if [ ! -f $(SAVE_NAME_DEV) ]; then echo -e "  $(ERROR) 파일이 없습니다: $(SAVE_NAME_DEV)"; exit 1; fi
	@echo -e "  $(INFO) 순수 개발 이미지를 복원합니다..."
	@docker load < $(SAVE_NAME_DEV)

# =============================================================================
# 유지보수
# =============================================================================
# 실시간 모니터링 (CPU, MEM, NVIDIA/Intel/AMD GPU)
stats:
	@echo -e "  $(INFO) 가용 자원 및 모든 컨테이너 모니터링을 시작합니다 (Ctrl+C로 종료)..."
	@watch -t -n 1 "bash -c ' \
		echo -e \"--- [모든 컨테이너 상태 (CPU/Mem/PIDs)] ---\n\"; \
		docker stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.PIDs}}\"; \
		if [ \"$(HAS_NVIDIA)\" = \"true\" ]; then \
			echo -e \"\n--- [NVIDIA GPU 상세 상태] ---\n\"; \
			nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits | sed \"s/^/  GPU /\"; \
		fi; \
		if [ \"$(HAS_DRI)\" = \"true\" ]; then \
			echo -e \"\n--- [Intel/AMD (DRI) 부하 상태] ---\n\"; \
			for dev in /sys/class/drm/renderD*; do \
				[ -d \"\$$dev\" ] || continue; \
				idx=\$${dev##*renderD}; \
				vendor=\$$(cat \"\$$dev/device/vendor\" 2>/dev/null); \
				if [ \"\$$vendor\" = \"0x8086\" ]; then vname=\"Intel\"; \
				elif [ \"\$$vendor\" = \"0x1002\" ] || [ \"\$$vendor\" = \"0x1022\" ]; then vname=\"AMD\"; \
				else vname=\"DRI\"; fi; \
				echo -n \"  GPU \$$idx (\$$vname) Status: \"; \
				if [ -e \"\$$dev/device/gpu_busy_percent\" ]; then \
					usage=\$$(cat \"\$$dev/device/gpu_busy_percent\"); \
					echo \"\$$usage%\"; \
				else \
					echo \"Active (Use make top for detail)\"; \
				fi; \
			done; \
		fi; \
	'" || [ $$? -eq 130 ]

# 전문가용 상세 모니터링 (CPU 코어별 + GPU 프로세스별)
top:
	@CONTAINER=$$(docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo -e "  $(INFO) 컨테이너($$CONTAINER) 내부 상세 모니터링을 시작합니다..."; \
		docker exec -it $$CONTAINER bash -c " \
			FOUND=0; \
			if command -v nvtop >/dev/null 2>&1; then \
				if ! nvtop 2>&1 | head -n 1 | grep -q 'No GPU'; then \
					nvtop; FOUND=1; \
				fi; \
			fi; \
			if [ \"\$$FOUND\" = \"0\" ] && command -v intel_gpu_top >/dev/null 2>&1; then \
				intel_gpu_top; FOUND=1; \
			elif [ \"\$$FOUND\" = \"0\" ] && command -v radeontop >/dev/null 2>&1; then \
				radeontop; FOUND=1; \
			fi; \
			if [ \"\$$FOUND\" = \"0\" ]; then htop; fi; \
		" || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) 실행 중인 프로젝트 컨테이너가 없습니다. 호스트 도구를 시도합니다..."; \
		FOUND=0; \
		if command -v nvtop >/dev/null 2>&1; then \
			if nvtop 2>&1 | head -n 1 | grep -q "No GPU"; then \
				echo -e "  $(WARN) 호스트 nvtop이 GPU를 감지하지 못했습니다. 대안을 시도합니다..."; \
			else \
				nvtop || [ $$? -eq 130 ]; FOUND=1; \
			fi; \
		fi; \
		if [ "$$FOUND" = "0" ] && [ "$(HAS_DRI)" = "true" ]; then \
			for dev in /sys/class/drm/renderD*; do \
				[ -e "$$dev/device/vendor" ] || continue; \
				vendor=$$(cat "$$dev/device/vendor" 2>/dev/null); \
				if [ "$$vendor" = "0x8086" ] && command -v intel_gpu_top >/dev/null 2>&1; then \
					echo -e "  $(INFO) Intel GPU 감지됨. intel_gpu_top을 실행합니다..."; \
					sudo intel_gpu_top || [ $$? -eq 130 ]; FOUND=1; break; \
				elif ([ "$$vendor" = "0x1002" ] || [ "$$vendor" = "0x1022" ]) && command -v radeontop >/dev/null 2>&1; then \
					echo -e "  $(INFO) AMD GPU 감지됨. radeontop을 실행합니다..."; \
					radeontop || [ $$? -eq 130 ]; FOUND=1; break; \
				fi; \
			done; \
		fi; \
		if [ "$$FOUND" = "0" ] && command -v htop >/dev/null 2>&1; then \
			htop || [ $$? -eq 130 ]; FOUND=1; \
		fi; \
		if [ "$$FOUND" = "0" ]; then \
			echo -e "  $(ERROR) 적절한 모니터링 도구(nvtop, intel_gpu_top, htop)를 찾을 수 없습니다."; exit 1; \
		fi; \
	fi

logs:
	@if [ -n "$$($(COMPOSE) $(COMPOSE_DEV) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Dev] 개발 환경 로그를 스트리밍합니다..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
	elif [ -f docker-compose.prod.yml ] && [ -n "$$($(COMPOSE) $(COMPOSE_PROD) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Prod] 배포 환경 로그를 스트리밍합니다..."; \
		$(COMPOSE) $(COMPOSE_PROD) logs -f --tail 100; \
	fi

down:
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down --remove-orphans
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down --remove-orphans 2>/dev/null || true; \
	fi

clean:
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down -v --remove-orphans
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down -v --remove-orphans 2>/dev/null || true; \
	fi
	@echo -e "  $(INFO) $(COMPOSE_PROJECT_NAME) 관련 모든 네임드 볼륨을 삭제합니다..."
	@VOLUMES=$$(docker volume ls -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$VOLUMES" ]; then \
		docker volume rm $$VOLUMES 2>/dev/null || true; \
	fi

clean-cache:
	@CACHE_DIR=$(HOST_CACHE_DIR); \
	if [ -z "$$CACHE_DIR" ] || [ "$$CACHE_DIR" = "/" ] || ! (echo "$$CACHE_DIR" | grep -q "$(COMPOSE_PROJECT_NAME)" || echo "$$CACHE_DIR" | grep -q "$(WORKSPACE_PATH)"); then \
		echo -e "  $(ERROR) 캐시 경로($$CACHE_DIR)가 유효하지 않거나 안전하지 않습니다."; \
		exit 1; \
	fi; \
	if [ -d "$$CACHE_DIR" ]; then \
		echo -e "  $(WARN) 호스트 측 도커 캐시 폴더($$CACHE_DIR)를 정말 삭제하시겠습니까? [y/N]"; \
		read ans && if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) 삭제를 취소합니다."; exit 1; fi; \
		echo -e "  $(INFO) 호스트 측 도커 캐시 폴더($$CACHE_DIR)를 삭제합니다..."; \
		sudo rm -rf "$$CACHE_DIR"; \
	fi

# 프로젝트 관련 모든 리소스(이미지 포함) 초기화
clean-all: clean clean-cache
	@echo -e "  $(INFO) $(COMPOSE_PROJECT_NAME) 프로젝트 관련 모든 이미지를 정리합니다..."
	@IMAGES=$$(docker images -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$IMAGES" ]; then \
		docker rmi -f $$IMAGES 2>/dev/null || true; \
		echo -e "  $(OK) 프로젝트 관련 이미지가 삭제되었습니다."; \
	else \
		echo -e "  $(INFO) 삭제할 프로젝트 관련 이미지가 없습니다."; \
	fi

# 도커 시스템 전역 정리 (주의: 모든 프로젝트의 빌드 캐시에 영향을 줌)
docker-clean:
	@echo -e "  $(WARN) 도커 시스템 전역을 정리하시겠습니까? (빌드 캐시 및 미사용 이미지 삭제) [y/N]"
	@read ans && if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) 작업을 취소합니다."; exit 1; fi
	@echo -e "  $(INFO) 도커 빌드 캐시(BuildKit)를 정리합니다..."
	@docker builder prune -a -f
	@echo -e "  $(INFO) 미사용 이미지를 정리합니다..."
	@docker image prune -f
	@echo -e "  $(OK) 도커 시스템 전역 정리가 완료되었습니다."

# 환경 변수 동기화 확인
env-check:
	@echo -e "  $(INFO) .env와 .env.example의 설정을 대조합니다..."
	@MISSING=$$(comm -23 <(grep -E "^[^#]+=" .env.example | cut -d= -f1 | sort) <(grep -E "^[^#]+=" .env | cut -d= -f1 | sort)); \
	if [ -n "$$MISSING" ]; then \
		echo -e "  $(WARN) 다음 환경 변수가 .env에 누락되었습니다:\n$$MISSING"; \
	else \
		echo -e "  $(OK) 모든 필수 환경 변수가 정상 설정되었습니다."; \
	fi

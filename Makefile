# =============================================================================
# Makefile
# Unified Workflow Orchestration (KISS-based Command Integration)
# =============================================================================

SHELL := /bin/bash

# Colors and Logging Definitions
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

# Load Environment Variables
-include .env

# Environment Detection Engine (Auto-detection — triggered by relevant targets)
# Applied to Docker-related operations to ensure hardware and display compatibility
NEEDS_DETECTOR := $(filter-out help setup env-check%,$(MAKECMDGOALS))
ifneq ($(NEEDS_DETECTOR),)
$(foreach line,$(shell bash scripts/env_detector.sh),$(eval $(line)))
endif

# Auto-match TARGETARCH
TARGETARCH ?= $(HOST_ARCH)
WORKSPACE_PATH ?= $(CURDIR)
export

COMPOSE := docker compose
COMPOSE_DEV := -f docker-compose.dev.yml
COMPOSE_PROD := -f docker-compose.prod.yml
TERMINAL ?= terminator

# Macros (Deduplication & SSOT)
# Integrated GPU Mode Detection Logic
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
	echo -e "  $(INFO) [$$CHOSEN_MODE] Starting $3 environment (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC up -d $$TARGET_SVC
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG
define STOP_SERVICE
	@$(DETECT_MODE) \
	PROF=$$CHOSEN_MODE; \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) [$$CHOSEN_MODE] Stopping $3 environment (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 --profile $$TARGET_SVC stop $$TARGET_SVC
endef

# $1: ENV_VAR_NAME
define CHECK_ENV
	@if [ -z "$($1)" ]; then \
		echo -e "  $(ERROR) Variable $1 is not set in .env. It is strictly required for production."; \
		exit 1; \
	fi
endef

define VALIDATE_ROS_ENV
	@if [ -n "$(ROS_DOMAIN_ID)" ]; then \
		if ! [ "$(ROS_DOMAIN_ID)" -eq "$(ROS_DOMAIN_ID)" ] 2>/dev/null || [ "$(ROS_DOMAIN_ID)" -lt 0 ] || [ "$(ROS_DOMAIN_ID)" -gt 101 ]; then \
			echo -e "  $(ERROR) ROS_DOMAIN_ID must be a number between 0 and 101 (Current: $(ROS_DOMAIN_ID))"; \
			exit 1; \
		fi \
	fi
	@if [ -n "$(RMW_IMPLEMENTATION)" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_cyclonedds_cpp" ] && [ "$(RMW_IMPLEMENTATION)" != "rmw_fastrtps_cpp" ]; then \
		echo -e "  $(WARN) Non-standard RMW_IMPLEMENTATION detected: $(RMW_IMPLEMENTATION)"; \
	fi
endef

define VALIDATE_COMPOSE_NAME
	@if echo "$(COMPOSE_PROJECT_NAME)" | grep -q '[^a-z0-9_-]'; then \
		echo -e "  $(ERROR) COMPOSE_PROJECT_NAME must contain only lowercase letters, dashes (-), or underscores (_)."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_CONTAINER
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -it $$CONTAINER $2 || [ $$? -eq 130 ]; \
	else \
		echo -e "  $(ERROR) No running container found for $3."; \
		exit 1; \
	fi
endef

# $1: FILTER, $2: COMMAND, $3: MSG (For error display)
define EXEC_DETACHED
	@CONTAINER=$$(docker ps --filter "name=$1" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		docker exec -d $$CONTAINER $2; \
	else \
		echo "  [ERROR] No running container found for $3."; \
		exit 1; \
	fi
endef

# $1: COMPOSE_FILES, $2: SERVICE_PREFIX, $3: MSG, $4: EXTRA_ARGS, $5: HINT_MSG
define BUILD_SERVICE
	@$(DETECT_MODE) \
	TARGET_SVC=$2-$$CHOSEN_MODE; \
	echo -e "  $(INFO) Building image for [$3] (Service: $$TARGET_SVC)..."; \
	$(COMPOSE) $1 build $4 $$TARGET_SVC
	@echo -e "\n  $(INFO) [Hint] $5"
endef

# $1: EXTRA_ARGS (e.g. -v for volumes)
define TEARDOWN_SERVICES
	$(COMPOSE) $(COMPOSE_DEV) --profile "*" down $1 --remove-orphans
	@if [ -f docker-compose.prod.yml ]; then \
		$(COMPOSE) $(COMPOSE_PROD) --profile "*" down $1 --remove-orphans 2>/dev/null || true; \
	fi
endef

# $1: MOUNT_DIR (Absolute Path), $2: Targets to delete
define SUDO_FREE_RM
	echo -e "  $(INFO) Performing sudo-free deletion: $2"; \
	docker run --rm -v "$1:/mnt" alpine sh -c "cd /mnt && rm -rf $2" 2>/dev/null || true; \
	if [ "$(SKIP_ALPINE_RM)" != "1" ]; then \
		echo -e "  $(INFO) Cleaning up the temporary alpine image used for sudo-free deletion..."; \
		docker rmi alpine:latest 2>/dev/null || true; \
	fi
endef

# Core Infrastructure Variables Export
export HAS_NVIDIA HAS_TOOLKIT HAS_DRI HOST_ARCH TARGETARCH DISPLAY_TYPE HOST_XDG_RUNTIME_DIR HOST_WAYLAND_DISPLAY HOST_XAUTHORITY HOST_HOME NVIDIA_VISIBLE_DEVICES NVIDIA_DRIVER_CAPABILITIES NVIDIA_GPU_COUNT HOST_CACHE_DIR HOST_X11_DIR HOST_GITCONFIG HOST_SSH_DIR

# Centralized UI Sub-Header Macro
define PRINT_SECTION
	@bash -c "source scripts/utils_logging.sh && print_section \"$1\""
endef

.PHONY: help setup check check-host xauth status \
        build-ros build-dev rebuild-ros rebuild-dev \
        ros ros-stop ros-restart dev dev-stop dev-restart ros-shell dev-shell ros-term dev-term \
		build-ros-prod build-dev-prod rebuild-ros-prod rebuild-dev-prod \
        ros-prod ros-prod-stop dev-prod dev-prod-stop \
		save-ros save-dev load-ros load-dev \
        stats top logs down clean clean-cache clean-all docker-clean env-check

# =============================================================================
# Default & Help
# =============================================================================
help:
	@bash -c "source scripts/utils_logging.sh && print_banner WELCOME"
	@echo ""
	@echo "  [ Initial Setup & Status Check ]"
	@echo "    make setup          : Initialize .env and configure host prerequisites"
	@echo "    make status         : Diagnose project settings, GPU acceleration, and display state"
	@echo ""
	@echo "  [ Development Environment (ROS) ]"
	@echo "    make ros            : Run ROS dev container (CPU/iGPU/NVIDIA auto-detected)"
	@echo "    make ros-stop       : Stop ROS dev container"
	@echo "    make ros-restart    : Safely restart ROS service"
	@echo "    make ros-shell      : Enter shell of the running ROS container"
	@echo "    make ros-term       : Execute ROS shell in a new Terminator window"
	@echo "    make build-ros      : Build Docker image for ROS"
	@echo "    make rebuild-ros    : Rebuild ROS image completely without cache"
	@echo "    make build-ros-prod : Build production image for ROS"
	@echo "    make rebuild-ros-prod : Rebuild production ROS image without cache"
	@echo ""
	@echo "  [ Development Environment (Pure Dev) ]"
	@echo "    make dev            : Run pure dev container (CPU/iGPU/NVIDIA auto-detected)"
	@echo "    make dev-stop       : Stop pure dev container"
	@echo "    make dev-restart    : Safely restart pure dev service"
	@echo "    make dev-shell      : Enter shell of the running pure dev container"
	@echo "    make dev-term       : Execute pure dev shell in a new Terminator window"
	@echo "    make build-dev      : Build Docker image for pure dev"
	@echo "    make rebuild-dev    : Rebuild pure dev Docker image from scratch without cache"
	@echo "    make build-dev-prod : Build production image for pure dev"
	@echo "    make rebuild-dev-prod : Rebuild production pure dev image without cache"
	@echo ""
	@echo "  [ Production Deployment ] — Bake & Switch Strategy"
	@echo "    make ros-prod       : Run the ROS production service"
	@echo "    make ros-prod-stop  : Stop the ROS production service"
	@echo "    make save-ros       : Extract the ROS production image to a compressed file"
	@echo "    make load-ros       : Restore the ROS image from the compressed file"
	@echo "    make dev-prod       : Run the pure dev production service"
	@echo "    make dev-prod-stop  : Stop the pure dev production service"
	@echo "    make save-dev       : Extract the pure dev production image to a compressed file"
	@echo "    make load-dev       : Restore the pure dev image from the compressed file"
	@echo ""
	@echo "  [ Maintenance & Tools ]"
	@echo "    make stats          : Monitor system overall resources (CPU/Mem/GPU) in real time"
	@echo "    make top            : Detailed monitoring based on project containers (CPU Cores / GPU Processes)"
	@echo "    make logs           : Stream real-time logs of running containers (Ctrl+C to stop)"
	@echo "    make down           : Stop and remove all running containers safely"
	@echo "    make clean          : Delete Docker volumes for build outputs (build, install, log)"
	@echo "    make clean-cache    : Completely wipe .docker_cache (ccache, uv, apt) on the host"
	@echo "    make clean-all      : Completely reset all Docker resources (images/volumes/cache) for the project"
	@echo "    make docker-clean   : Global Docker system cleanup (wipe overall build caches and dangling images)"
	@echo "    make env-check      : Automatically check for missing settings in .env compared to .env.example"

# =============================================================================
# Initial Setup and Status Check
# =============================================================================
setup:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo -e "  $(OK) Created .env file. Please edit settings to your needs."; \
	else \
		echo -e "  $(INFO) .env file already exists."; \
	fi
	@$(MAKE) xauth

status: check
	$(call PRINT_SECTION,Project Configuration Summary)
	@echo "  Project Name:      $(COMPOSE_PROJECT_NAME)"
	@echo "  ROS Version:       $(ROS_DISTRO)"
	@echo "  Architecture:      $(HOST_ARCH) (Target: $(TARGETARCH))"
	@echo "  Display:           $(DISPLAY) ($(DISPLAY_TYPE))"
	@echo "  GPU Mode (Set):    $(GPU_MODE)"
	$(call PRINT_SECTION,Running Containers)
	@docker ps --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | sed 's/^/  /'
	$(call PRINT_SECTION,Created Docker Volumes)
	@docker volume ls --filter "name=$(COMPOSE_PROJECT_NAME)" --format "table {{.Name}}\t{{.Driver}}" | sed 's/^/  /'
	@if [ "$(HAS_NVIDIA)" = "true" ]; then \
		bash -c "source scripts/utils_logging.sh && print_section 'NVIDIA GPU Details'"; \
		nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | sed 's/^/  /'; \
	fi

check-host:
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "false" ]; then \
		echo -e "  $(WARN) NVIDIA GPU detected but NVIDIA Container Toolkit is not installed."; \
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
	@if [ ! -f .env ]; then echo -e "  $(ERROR) .env not found. Please run 'make setup' first."; exit 1; fi
	@if [ ! -d "$(WORKSPACE_PATH)" ]; then echo -e "  $(ERROR) WORKSPACE_PATH ($(WORKSPACE_PATH)) does not exist."; exit 1; fi
	$(call VALIDATE_COMPOSE_NAME)
	$(call VALIDATE_ROS_ENV)

# Build
# =============================================================================
build-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,ROS Development,,"Build finished! Please run 'make ros' to start the container.")

build-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Pure Development,,"Build finished! Please run 'make dev' to start the container.")

rebuild-ros: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),ros,Rebuild ROS without cache,--no-cache,"Build finished! Please run 'make ros' to start the container.")

rebuild-dev: check
	$(call BUILD_SERVICE,$(COMPOSE_DEV),basic,Rebuild Pure Dev without cache,--no-cache,"Build finished! Please run 'make dev' to start the container.")

build-ros-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Bake Production ROS,,"Production image baked! Extract with 'make save-ros' or run with 'make ros-prod'.")

build-dev-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Bake Production Pure Dev,,"Production image baked! Extract with 'make save-dev' or run with 'make dev-prod'.")

rebuild-ros-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),ros,Rebuild Production ROS without cache,--no-cache,"Production image baked! Extract with 'make save-ros' or run with 'make ros-prod'.")

rebuild-dev-prod: check
	@echo -e "  $(INFO) [Notice] A clean build (make clean) is recommended for production-grade artifacts."
	$(call BUILD_SERVICE,$(COMPOSE_PROD),basic,Rebuild Production Pure Dev without cache,--no-cache,"Production image baked! Extract with 'make save-dev' or run with 'make dev-prod'.")

# =============================================================================
# Execution and Shell Access (Dev) - Auto GPU Detection
# =============================================================================
ros: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),ros,ROS Development)
	@echo -e "\n  $(INFO) [Hint] Container started! Use 'make ros-shell' or 'make ros-term' to attach to the container."

dev: check xauth
	$(call RUN_SERVICE,$(COMPOSE_DEV),basic,Pure Development)
	@echo -e "\n  $(INFO) [Hint] Container started! Use 'make dev-shell' or 'make dev-term' to attach to the container."

# Stop and Restart Services Individually
ros-stop:
	$(call STOP_SERVICE,$(COMPOSE_DEV),ros,ROS Development)

dev-stop:
	$(call STOP_SERVICE,$(COMPOSE_DEV),basic,Pure Development)

ros-restart: ros-stop ros
dev-restart: dev-stop dev

# Filter Definitions
ROS_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]ros-(cpu|igpu|nvidia)
DEV_FILTER := ^$(COMPOSE_PROJECT_NAME)[-_]basic-(cpu|igpu|nvidia)

ros-shell: check
	$(call EXEC_CONTAINER,$(ROS_FILTER),bash,ROS)

ros-term: check xauth
	$(call EXEC_DETACHED,$(ROS_FILTER),$(TERMINAL),ROS)

dev-shell: check
	$(call EXEC_CONTAINER,$(DEV_FILTER),bash,Development)

dev-term: check xauth
	$(call EXEC_DETACHED,$(DEV_FILTER),$(TERMINAL),Development)


# =============================================================================
# Production Execution (Prod) - Auto GPU Detection
# =============================================================================
ros-prod: check xauth
	$(call CHECK_ENV,ROS_LAUNCH_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),ros,ROS Production)
	@$(MAKE) logs

ros-prod-stop:
	$(call STOP_SERVICE,$(COMPOSE_PROD),ros,ROS Production)

dev-prod: check xauth
	$(call CHECK_ENV,APP_COMMAND)
	$(call RUN_SERVICE,$(COMPOSE_PROD),basic,Pure Development Production)
	@$(MAKE) logs

dev-prod-stop:
	$(call STOP_SERVICE,$(COMPOSE_PROD),basic,Pure Development Production)

# Image Extraction and Restoration Strategy
IMAGE_SUFFIX := $(if $(filter humble,$(ROS_DISTRO)),humble,$(if $(filter noetic,$(ROS_DISTRO)),noetic,latest))
SAVE_NAME_ROS := $(COMPOSE_PROJECT_NAME)-ros-$(IMAGE_SUFFIX).tar.gz
SAVE_NAME_DEV := $(COMPOSE_PROJECT_NAME)-dev-$(IMAGE_SUFFIX).tar.gz

# $1: TARGET_ENV (ros-runtime or dev-runtime), $2: SAVE_FILE_NAME, $3: MSG
define SAVE_IMAGE
	@echo -e "  $(INFO) Extracting production image for $3: $2..."
	@docker save $(COMPOSE_PROJECT_NAME)/$1:latest | gzip > $2
	@echo -e "  $(OK) Image extraction completed: $$(du -h $2) (Path: ./$2)"
endef

# $1: SAVE_FILE_NAME, $2: MSG
define LOAD_IMAGE
	@if [ ! -f $1 ]; then echo -e "  $(ERROR) File not found: $1"; exit 1; fi
	@echo -e "  $(INFO) Restoring $2 image..."
	@docker load < $1
	@echo -e "  $(OK) $2 image restored successfully."
endef

save-ros:
	$(call SAVE_IMAGE,ros-runtime,$(SAVE_NAME_ROS),ROS)

save-dev:
	$(call SAVE_IMAGE,dev-runtime,$(SAVE_NAME_DEV),Pure Development)

load-ros:
	$(call LOAD_IMAGE,$(SAVE_NAME_ROS),ROS)

load-dev:
	$(call LOAD_IMAGE,$(SAVE_NAME_DEV),Pure Development)

# =============================================================================
# Maintenance
# =============================================================================
# Real-time Monitoring (CPU, MEM, NVIDIA/Intel/AMD GPU)
stats:
	@echo -e "  $(INFO) Initiating real-time resource monitoring (Ctrl+C to terminate)..."
	@watch -t -n 1 "bash -c ' \
		source scripts/utils_logging.sh; \
		print_section \"All Containers Status (CPU/Mem/PIDs)\"; echo \"\"; \
		docker stats --no-stream --format \"table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.PIDs}}\" | sed \"s/^/  /\"; \
		if [ \"$(HAS_NVIDIA)\" = \"true\" ]; then \
			echo \"\"; print_section \"NVIDIA GPU Details\"; echo \"\"; \
			nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits | sed \"s/^/  GPU /\"; \
		fi; \
		if [ \"$(HAS_DRI)\" = \"true\" ]; then \
			echo \"\"; print_section \"Intel/AMD (DRI) Load Status\"; echo \"\"; \
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
					echo \"Active (Use make top for details)\"; \
				fi; \
			done; \
		fi; \
	'" || [ $$? -eq 130 ]

# Detailed Expert Monitoring (Per CPU Core + Per GPU Process)
top:
	@CONTAINER=$$(docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" --format "{{.Names}}" | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo -e "  $(INFO) Initiating granular container-level monitoring ($$CONTAINER)..."; \
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
		echo -e "  $(ERROR) No running project container found. Trying host tools instead..."; \
		FOUND=0; \
		if command -v nvtop >/dev/null 2>&1; then \
			if nvtop 2>&1 | head -n 1 | grep -q "No GPU"; then \
				echo -e "  $(WARN) Host nvtop failed to detect a GPU. Trying an alternative..."; \
			else \
				nvtop || [ $$? -eq 130 ]; FOUND=1; \
			fi; \
		fi; \
		if [ "$$FOUND" = "0" ] && [ "$(HAS_DRI)" = "true" ]; then \
			for dev in /sys/class/drm/renderD*; do \
				[ -e "$$dev/device/vendor" ] || continue; \
				vendor=$$(cat "$$dev/device/vendor" 2>/dev/null); \
				if [ "$$vendor" = "0x8086" ] && command -v intel_gpu_top >/dev/null 2>&1; then \
					echo -e "  $(INFO) Intel GPU detected. Running intel_gpu_top..."; \
					sudo intel_gpu_top || [ $$? -eq 130 ]; FOUND=1; break; \
				elif ([ "$$vendor" = "0x1002" ] || [ "$$vendor" = "0x1022" ]) && command -v radeontop >/dev/null 2>&1; then \
					echo -e "  $(INFO) AMD GPU detected. Running radeontop..."; \
					radeontop || [ $$? -eq 130 ]; FOUND=1; break; \
				fi; \
			done; \
		fi; \
		if [ "$$FOUND" = "0" ] && command -v htop >/dev/null 2>&1; then \
			htop || [ $$? -eq 130 ]; FOUND=1; \
		fi; \
		if [ "$$FOUND" = "0" ]; then \
			echo -e "  $(ERROR) Appropriate monitoring tools (nvtop, intel_gpu_top, htop) could not be found."; exit 1; \
		fi; \
	fi

logs:
	@if [ -n "$$($(COMPOSE) $(COMPOSE_DEV) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Dev] Streaming development logs..."; \
		$(COMPOSE) $(COMPOSE_DEV) logs -f --tail 100; \
	elif [ -f docker-compose.prod.yml ] && [ -n "$$($(COMPOSE) $(COMPOSE_PROD) ps --status running -q 2>/dev/null)" ]; then \
		echo -e "  $(INFO) [Prod] Streaming production logs..."; \
		$(COMPOSE) $(COMPOSE_PROD) logs -f --tail 100; \
	fi

down:
	$(call TEARDOWN_SERVICES)
	@echo -e "  $(OK) All containers have successfully been stopped and removed."

clean:
	$(call TEARDOWN_SERVICES,-v)
	@echo -e "  $(INFO) Removing all named volumes related to $(COMPOSE_PROJECT_NAME)..."
	@VOLUMES=$$(docker volume ls -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$VOLUMES" ]; then \
		docker volume rm $$VOLUMES 2>/dev/null || true; \
	fi
	@if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
		echo -e "  $(WARN) CI/FORCE mode: Forcibly deleting host folders without prompting."; ans="y"; \
	else \
		echo -e "  $(WARN) Do you want to delete the build, install, log, and .venv host folders?"; \
		echo -n "  (WARNING: If you used bind mounts in .env, actual data will be lost!) [Y/N]: "; \
		read ans || true; \
	fi; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		$(call SUDO_FREE_RM,$(WORKSPACE_PATH),build install log .venv); \
	else \
		echo -e "  $(INFO) Safely skipped deleting host folders."; \
	fi
	@echo -e "  $(OK) General project clean up completed."

clean-cache:
	@CACHE_DIR=$(HOST_CACHE_DIR); \
	if [ -z "$$CACHE_DIR" ] || [ "$$CACHE_DIR" = "/" ]; then \
		echo -e "  $(ERROR) Cache directory ($$CACHE_DIR) is invalid or unsafe."; \
		exit 1; \
	fi; \
	if ! (echo "$$CACHE_DIR" | grep -q "$(COMPOSE_PROJECT_NAME)" || echo "$$CACHE_DIR" | grep -q "$(WORKSPACE_PATH)"); then \
		echo -e "  $(WARN) This cache string ($$CACHE_DIR) points to a shared global cache. Proceeding here affects all projects."; \
	fi; \
	if [ -d "$$CACHE_DIR" ]; then \
		if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
			ans="y"; \
		else \
			echo -e "  $(WARN) Are you sure you want to delete the host cache directory ($$CACHE_DIR)? [Y/N]"; \
			read ans || true; \
		fi; \
		if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) Deletion cancelled."; exit 1; fi; \
		$(call SUDO_FREE_RM,$$(dirname "$$CACHE_DIR"),$$(basename "$$CACHE_DIR")); \
	fi
	@echo -e "  $(OK) Docker local cache clean up (clean-cache) completed."

# Reset all project-related resources (including images)
clean-all:
	@$(MAKE) clean SKIP_ALPINE_RM=1
	@$(MAKE) clean-cache SKIP_ALPINE_RM=1
	@echo -e "  $(INFO) Cleaning up the temporary alpine image used for sudo-free deletion..."
	@docker rmi alpine:latest 2>/dev/null || true
	@echo -e "  $(INFO) Cleaning up all images related to project $(COMPOSE_PROJECT_NAME)..."
	@IMAGES=$$(docker images -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"); \
	if [ -n "$$IMAGES" ]; then \
		docker rmi -f $$IMAGES 2>/dev/null || true; \
		echo -e "  $(OK) Project-related images removed."; \
	else \
		echo -e "  $(INFO) No project-related images to delete."; \
	fi
	@echo -e "  $(OK) Full project reset (clean-all) completed."

# Global Docker cleanup (Warning: affects build caches across all projects on the system)
docker-clean:
	@if [ "$(FORCE)" = "1" ] || [ "$(CI)" = "true" ]; then \
		ans="y"; \
	else \
		echo -e "  $(WARN) Do you want to globally clean Docker on this host? (Deletes all build cache and unused images) [Y/N]"; \
		read ans || true; \
	fi; \
	if [ "$$ans" != "y" ] && [ "$$ans" != "Y" ]; then echo -e "  $(INFO) Operation cancelled."; exit 1; fi
	@echo -e "  $(INFO) Cleaning up Docker BuildKit caches..."
	@docker builder prune -a -f
	@echo -e "  $(INFO) Cleaning up unused images..."
	@docker image prune -f
	@echo -e "  $(OK) Global Docker cleanup completed."

# Verify environment variables synchronization
env-check:
	@echo -e "  $(INFO) Comparing .env settings against .env.example..."
	@MISSING=$$(comm -23 <(grep -E "^[^#]+=" .env.example | cut -d= -f1 | sort) <(grep -E "^[^#]+=" .env | cut -d= -f1 | sort)); \
	if [ -n "$$MISSING" ]; then \
		echo -e "  $(WARN) The following environment variables are missing in your .env:\n$$MISSING"; \
	else \
		echo -e "  $(OK) All required environment variables are properly set."; \
	fi

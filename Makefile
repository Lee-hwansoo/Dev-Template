# =============================================================================
# DevKit Makefile — the host-side entry points. `make help` is the index.
# The literal "DevKit Makefile" above is a marker: tab completion walks up from
# $PWD looking for it, so a DevKit tree is recognised from any subdirectory.
# =============================================================================

SHELL := /bin/bash

# Color definitions.
# MAKE_TERMOUT is set by GNU make only when stdout is a terminal, so redirecting
# `make ... > log` (or NO_COLOR=1) yields clean, greppable output automatically.
DEVKIT_COLOR := $(if $(MAKE_TERMOUT),$(if $(NO_COLOR),,yes),)
ifeq ($(DEVKIT_COLOR),)
BLUE   :=
GREEN  :=
RED    :=
YELLOW :=
CYAN   :=
BCYAN  :=
TEAL   :=
NC     :=
else
BLUE   := \033[0;34m
GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
BCYAN  := \033[1;36m
TEAL   := \033[38;2;45;212;191m
NC     := \033[0m
endif

INFO   := $(CYAN)[INFO]$(NC)
OK     := $(GREEN)[OK]$(NC)
WARN   := $(YELLOW)[WARN]$(NC)
ERROR  := $(RED)[ERROR]$(NC)

# Load environment configuration.
# A `GPU_MODE=nvidia make start` style override must beat .env, but make gives
# file assignments priority over inherited environment variables — so snapshot
# the environment value and restore it after the include.
ifeq ($(origin GPU_MODE),environment)
USER_GPU_MODE := $(GPU_MODE)
endif
-include .env
ifdef USER_GPU_MODE
GPU_MODE := $(USER_GPU_MODE)
endif

# Template revision. VERSION is committed, so it travels with a fork even when
# the project was created from the GitHub template button and carries none of
# DevKit's history; the short commit is best-effort on top of it.
DEVKIT_VERSION := $(shell cat VERSION 2>/dev/null || echo unknown)
DEVKIT_COMMIT  := $(shell git -C $(CURDIR) rev-parse --short HEAD 2>/dev/null)

# `make adopt` inputs, honoured ONLY from the command line: NAME and DESC are
# ordinary environment variables (WSL exports NAME=<hostname>) and make imports
# the environment, so an inherited value would silently adopt the wrong name.
ADOPT_NAME := $(if $(filter command line,$(origin NAME)),$(NAME),)
ADOPT_DESC := $(if $(filter command line,$(origin DESC)),$(DESC),)

HOST_WORKSPACE_PATH ?= $(CURDIR)
WORKSPACE_PATH      ?= /workspace
COMPOSE_PROJECT_NAME?= devkit
ENV                 ?= ros
SIF_MODE            ?= dev
IMAGE_TAG           ?= latest

export

# =============================================================================
# Host Environment Detection (cached, atomic, fail-fast)
# =============================================================================
# Help/teardown/validation targets skip detection and never pay the
# nvidia-smi / docker-info probe.
DETECTOR_EXEMPT := help setup adopt verify stop down logs clean clean-cache clean-all docker-clean slurm-status slurm-cancel completion completion-install check-host env-check
# A bare `make` runs the default target (help), so it must not pay for
# detection either — substitute 'help' before filtering.
NEEDS_DETECTOR  := $(filter-out $(DETECTOR_EXEMPT),$(or $(MAKECMDGOALS),help))

DETECTED_ENV_FILE := .docker_cache/detected-env.mk
ifneq ($(NEEDS_DETECTOR),)
# The cache is included AFTER .env, so its `:=` assignments win: a cache built
# before .env existed (or before it was edited) silently overrides ROS_DISTRO /
# BASE_IMAGE forever. Treat it as stale whenever .env is newer. `shell test`
# instead of `wildcard`: make caches directory listings within a run.
DETECTED_ENV_FRESH := $(shell [ -f "$(DETECTED_ENV_FILE)" ] && [ ! .env -nt "$(DETECTED_ENV_FILE)" ] && echo yes)
ifeq ($(DETECTED_ENV_FRESH),)
# Write via temp + mv: a failed or interrupted probe must never leave a partial
# cache behind, because the freshness guard above would then reuse it forever and
# every host mount would silently degrade to its placeholder default.
DETECT_STATUS := $(shell mkdir -p .docker_cache && tmp=$$(mktemp "$(DETECTED_ENV_FILE).XXXXXX") && \
	{ bash scripts/check_env.sh --makefile > "$$tmp" && mv "$$tmp" "$(DETECTED_ENV_FILE)" && echo ok; } || \
	{ rm -f "$$tmp"; echo fail; })
ifeq ($(DETECT_STATUS),fail)
$(error Host environment detection failed. Run 'bash scripts/check_env.sh' to see the error)
endif
endif
-include $(DETECTED_ENV_FILE)
endif

# Fail fast on input that would silently pick the wrong compose profile.
# Scoped to every target consuming ENV — including down/clean-all, where
# `make down ENV=ros2` would volume-delete the wrong profile without a word.
ENV_EXEMPT := help h setup adopt verify clean clean-cache docker-clean update-gpg xauth gpus slurm-status slurm-cancel completion completion-install
ifneq ($(filter-out $(ENV_EXEMPT),$(or $(MAKECMDGOALS),help)),)
ifeq ($(filter ros dev,$(ENV)),)
$(error ENV must be 'ros' or 'dev' (got: '$(ENV)'))
endif
GPU_MODE ?= auto
# intel/amd are aliases for the shared iGPU profile (same vocabulary as the
# in-container `gpu` helper). `override` so the mapping also applies to
# command-line assignments (make GPU_MODE=intel ...).
override GPU_MODE := $(if $(filter intel amd,$(GPU_MODE)),igpu,$(GPU_MODE))
ifeq ($(filter auto nvidia igpu cpu,$(GPU_MODE)),)
$(error GPU_MODE must be auto, nvidia, igpu or cpu (got: '$(GPU_MODE)'))
endif
ifeq ($(filter dev prod slurm,$(SIF_MODE)),)
$(error SIF_MODE must be 'dev', 'prod' or 'slurm' (got: '$(SIF_MODE)'))
endif
endif
ifneq ($(NEEDS_DETECTOR),)
# Build for the host architecture by default (Apple Silicon / Jetson would
# otherwise silently emulate amd64 via compose's linux/amd64 fallback).
TARGETARCH ?= $(HOST_ARCH)
endif

COMPOSE := docker compose -f docker-compose.dev.yml
SERVICE_PREFIX := $(if $(filter ros,$(ENV)),ros,basic)
# Every GPU variant of the selected ENV. Naming them explicitly keeps stop/down
# scoped to this ENV without paying for hardware detection: whichever variant is
# actually up gets hit, and the other ENV's containers are left alone.
ENV_SERVICES := $(SERVICE_PREFIX)-cpu $(SERVICE_PREFIX)-igpu $(SERVICE_PREFIX)-nvidia

IS_CONTAINER := $(shell [ -f /.dockerenv ] && echo true || echo false)
define GUARD_HOST_ONLY
	@if [ "$(IS_CONTAINER)" = "true" ]; then \
		echo -e "  $(ERROR) Run this command on the HOST machine."; \
		exit 1; \
	fi
endef

# CHECK_GPU_RUNTIME: warn when the NVIDIA runtime is present-but-unusable, with
# the exact remediation. Without this, `make build` picks the nvidia profile and
# fails deep inside docker with "could not select device driver".
define CHECK_GPU_RUNTIME
	@if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" != "true" ]; then \
		echo -e "  $(WARN) NVIDIA GPU detected, but Docker has no NVIDIA runtime configured."; \
		echo -e "  $(INFO) Fix: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"; \
		echo -e "  $(INFO) Until then DevKit falls back to the iGPU/CPU profile."; \
	fi
endef

# RESOLVE_SVC_MODE: shell snippet resolving GPU_MODE=auto against detected hardware.
# NVIDIA is only chosen when the container toolkit is actually usable.
define RESOLVE_SVC_MODE
SVC_MODE=$${GPU_MODE:-auto}; \
	if [ "$$SVC_MODE" = "auto" ]; then \
		if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then SVC_MODE=nvidia; \
		elif [ "$(HAS_DRI)" = "true" ]; then SVC_MODE=igpu; \
		else SVC_MODE=cpu; fi; \
	fi; \
	TARGET_SVC="$(SERVICE_PREFIX)-$$SVC_MODE"
endef

# FIND_CONTAINER: the running container of the SELECTED ENV. Scoped like
# stop/down: an unfiltered `docker ps ... | head -1` attached to whichever of a
# ros/basic pair started first, so `make exec ENV=ros` could land in the non-ROS
# container. Docker ANDs repeated `--filter label=`, so the service is matched
# here instead of with a second filter.
define FIND_CONTAINER
CONTAINER=$$(docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" \
		--format '{{.Label "com.docker.compose.service"}} {{.Names}}' \
		| awk '$$1 ~ /^$(SERVICE_PREFIX)-/ { print $$2; exit }')
endef

# REQUIRE_CONTAINER: FIND_CONTAINER plus the ONE message for "nothing is up",
# with a non-zero exit — six targets need exactly this and no other wording.
define REQUIRE_CONTAINER
$(FIND_CONTAINER); \
	if [ -z "$$CONTAINER" ]; then \
		echo -e "  $(ERROR) No running $(ENV) container for '$(COMPOSE_PROJECT_NAME)'. Run 'make start ENV=$(ENV)' first." >&2; \
		exit 1; \
	fi
endef

# EXEC_USER_FLAG: run as CONTAINER_USER when the image has that user.
# `shell` and `exec` must agree, or one of them writes root-owned files
# into the bind-mounted workspace.
define EXEC_USER_FLAG
: "$${CONTAINER_USER:=user}"; \
	USER_FLAG=""; \
	if [ "$$CONTAINER_USER" != "root" ] && docker exec $$CONTAINER id -u "$$CONTAINER_USER" >/dev/null 2>&1; then \
		USER_FLAG="-u $$CONTAINER_USER"; \
	fi
endef

# HINT_ROOT_OWNED: remediation for a path Docker re-created as root.
# $(1) = host path. Both `clean` and `clean-cache` need the same words.
define HINT_ROOT_OWNED
	echo -e "  $(INFO) Docker creates a missing mount source as root at container start."; \
	echo -e "  $(INFO) Remove it from inside a container (no sudo needed):"; \
	echo -e "  $(INFO)   docker run --rm -v \"$(HOST_WORKSPACE_PATH):/w\" alpine rm -rf /w/$(1)"
endef

# CONFIRM: interactive guard for irreversible targets. Skipped off-TTY or with
# FORCE=1 / CI=true, so scripts keep working; a human always gets the ask.
define CONFIRM
	@if [ -z "$$FORCE$$CI" ] && [ -t 0 ]; then \
		printf "  $(YELLOW)[CONFIRM]$(NC) %s [y/N]: " "$(1)"; \
		read -r REPLY; \
		case "$$REPLY" in y|Y|yes|YES) ;; *) echo -e "  $(INFO) Aborted."; exit 1 ;; esac; \
	elif [ -z "$$FORCE$$CI" ]; then \
		echo -e "  $(INFO) Non-interactive shell: proceeding (set FORCE=1 to silence this notice)."; \
	fi
endef

.PHONY: help h setup adopt status check verify xauth gpus build start stop restart shell exec test lint term bake-dev bake-prod run-sif slurm-status slurm-cancel stats top logs update-gpg down clean clean-cache clean-all docker-clean

# =============================================================================
# Help & Setup
# =============================================================================

## @target help : Show this command guide
help:
	@echo -e "\n$(TEAL)DevKit Makefile Targets & Arguments$(NC)"
	@echo -e "$(BCYAN)Start here — five commands is the whole loop$(NC)"
	@echo -e "  $(GREEN)make setup$(NC) → $(GREEN)make build$(NC) → $(GREEN)make start$(NC) → $(GREEN)make shell$(NC), then $(GREEN)mksync$(NC) inside the container"
	@echo -e "  Add $(CYAN)ENV=ros$(NC) (default) or $(CYAN)ENV=dev$(NC) to pick the environment. In-container help: $(GREEN)h$(NC)\n"
	@echo -e "$(CYAN)[ Host Workflows & Setup ] ==========================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "setup" "Initialize .env and host prerequisites"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "adopt NAME=my-robot" "Make this checkout your project (identity files)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "status / check" "Diagnose project, container & host status"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "gpus" "Monitor host-side GPU (NVIDIA/iGPU) status"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "verify" "Run fast repository validation checks"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "xauth" "Refresh X11 GUI authentication"
	@echo -e "\n$(CYAN)[ Docker Container Workflows ] ======================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "build / start / stop" "Build image, launch containers, stop"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "restart / down" "Restart containers / stop & remove containers"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "shell / term" "Interactive container shell / new window"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "exec CMD='...'" "Run command"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "test / lint" "Run project tests / check style (FIX=1 applies)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "logs / stats / top" "Stream logs, real-time stats, process monitor"
	@echo -e "\n$(CYAN)[ Apptainer SIF & SLURM ] ===========================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "bake-dev / bake-prod" "Bake development / production SIF artifacts"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "run-sif" "Run SIF artifact locally or submit to SLURM"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "slurm-status / cancel" "Query active SLURM jobs or cancel jobs"
	@echo -e "\n$(CYAN)[ Cleanup & Maintenance ] ===========================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "clean / clean-cache" "Delete build outputs / wipe .docker_cache"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "clean-all / docker-clean" "Reset containers & volumes / prune docker cache"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "update-gpg" "Update ROS GPG keys in build scripts"
	@echo ""

## @target h : Alias for help (muscle memory from earlier versions)
h: help

## @target setup : Initialize .env and host prerequisites
setup:
	$(call GUARD_HOST_ONLY)
	@# Per-user project name on FRESH setup only: on a shared host everyone
	@# using the stock 'myproject' would own each other's containers/volumes.
	@# Never rewrite an existing .env — renaming the project would orphan the
	@# volumes (including the built .venv) already created under the old name.
	@# The username is sanitized to compose's [a-z0-9][a-z0-9_-]* rule (LDAP/AD
	@# names like 'John.Doe' or 'LAB\user' would otherwise break every target).
	@# Atomic: .env appears only via mv, fully rewritten — an interrupt can
	@# never leave the un-scoped 'myproject' behind. The \r? tolerates CRLF.
	@if [ ! -f .env ]; then \
		U="$$(whoami 2>/dev/null || id -un 2>/dev/null || echo user)"; \
		U="$$(printf '%s' "$$U" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"; U="$${U%-}"; U="$${U:-user}"; \
		awk -v u="$$U" '/^COMPOSE_PROJECT_NAME=myproject\r?$$/{print "COMPOSE_PROJECT_NAME=myproject-" u; next} {print}' \
			.env.example > .env.tmp && mv .env.tmp .env; \
		echo -e "  $(OK) Created .env (project: myproject-$$U)"; \
	fi
	@bash config/devkit_make_completion.bash --install
	@$(MAKE) xauth

## @target adopt : Make this checkout YOUR project (NAME=my-robot [DESC='...'])
# The identity a fork owns, in one step: the Python package name, the compose
# project name, and the two files only you can decide. Idempotent, and every
# edit is a normal working-tree change you can review with `git diff`.
adopt:
	$(call GUARD_HOST_ONLY)
	@if [ -z "$(ADOPT_NAME)" ]; then \
		echo -e "  $(ERROR) Usage: make adopt NAME=my-robot [DESC='One line about it']" >&2; exit 2; \
	fi
	@# compose and PEP 508 both want [a-z0-9][a-z0-9_-]*; refuse rather than
	@# silently mangle a name that would break `docker compose` later.
	@printf '%s' "$(ADOPT_NAME)" | grep -qE '^[a-z0-9][a-z0-9_-]*$$' || { \
		echo -e "  $(ERROR) NAME must match [a-z0-9][a-z0-9_-]* (got: '$(ADOPT_NAME)')" >&2; exit 2; }
	@if [ -n "$$(git status --porcelain 2>/dev/null)" ]; then \
		echo -e "  $(ERROR) Working tree is not clean; commit or stash first." >&2; \
		echo -e "  $(INFO) Adoption rewrites tracked files — keep the diff reviewable." >&2; exit 1; \
	fi
	@# Scoped to the [project] table: a bare `sed s/^name = /` also renamed the
	@# [[tool.uv.index]] entries, and [tool.uv.sources] then pointed at indexes
	@# that no longer existed. Atomic via mv, like setup's .env write.
	@awk -v n='$(ADOPT_NAME)' -v d='$(ADOPT_DESC)' ' \
		/^\[/            { inproj = ($$0 == "[project]") } \
		inproj && /^name = /                  { print "name = \"" n "\""; next } \
		inproj && d != "" && /^description = / { print "description = \"" d "\""; next } \
		{ print }' src/pyproject.toml > src/pyproject.toml.tmp \
		&& mv src/pyproject.toml.tmp src/pyproject.toml
	@if [ -f .env ]; then \
		sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$(ADOPT_NAME)/' .env; \
	fi
	@sed -i 's/^COMPOSE_PROJECT_NAME=myproject$$/COMPOSE_PROJECT_NAME=$(ADOPT_NAME)/' .env.example
	@echo -e "  $(OK) Adopted as '$(ADOPT_NAME)': src/pyproject.toml, .env, .env.example"
	@echo -e "  $(INFO) Two files are yours to decide — DevKit cannot guess them:"
	@echo -e "  $(INFO)   README.md   this front page still describes DevKit"
	@echo -e "  $(INFO)   LICENSE     MIT-0 lets you relicense (docs/DEVELOPMENT.md)"
	@echo -e "  $(INFO) The kit's own guides stay in docs/ — keep or delete them."
	@echo -e "  $(INFO) Review with: git diff"

## @target status : Diagnose project and container status
status: check
	$(call GUARD_HOST_ONLY)
	@echo -e "\n$(BCYAN)[Project Configuration Summary]$(NC)"
	@printf "  %-19s %s\n" "Host User:"          "$$(whoami)"
	@printf "  %-19s %s\n" "Host OS:"            "$(if $(filter true,$(IS_MACOS)),macOS Darwin ($(HOST_ARCH)),$(if $(filter true,$(IS_WSL)),Windows WSL2,Linux Native))"
	@printf "  %-19s %s\n" "Project Name:"       "$(COMPOSE_PROJECT_NAME)"
	@printf "  %-19s %s\n" "DevKit Version:"     "$(DEVKIT_VERSION)$(if $(DEVKIT_COMMIT), ($(DEVKIT_COMMIT)),)"
	@printf "  %-19s %s\n" "Workspace Path:"     "$(HOST_WORKSPACE_PATH)"
	@printf "  %-19s %s\n" "ROS Version:"        "$(ROS_DISTRO)"
	@$(RESOLVE_SVC_MODE); \
	printf "  %-19s %s\n" "GPU Mode:" "$${GPU_MODE:-auto} → $$TARGET_SVC"
	@echo -e "\n$(BCYAN)[Detected Host Wiring]$(NC)  (refresh: make clean-cache)"
	@printf "  %-19s %s\n" "GPU devices:"  "$(HOST_DRI_MOUNT) | $(HOST_DXG_MOUNT)"
	@printf "  %-19s %s\n" "WSL libs:"     "$(WSL_LIB_DIR_MOUNT)"
	@printf "  %-19s %s\n" "Display:"      "$(DISPLAY_TYPE) | X11=$(HOST_X11_DIR) | WAYLAND=$(if $(HOST_WAYLAND_DISPLAY),$(HOST_WAYLAND_DISPLAY),-)"
	@printf "  %-19s %s\n" "XDG runtime:"  "$(HOST_XDG_RUNTIME_DIR)"
	@printf "  %-19s %s\n" "Xauthority:"   "$(HOST_XAUTHORITY)"
	@printf "  %-19s %s\n" "ssh-agent:"    "$(if $(HOST_SSH_AUTH_SOCK),$(HOST_SSH_AUTH_SOCK),- (not forwarded))"
	@printf "  %-19s %s\n" "git identity:" "$(HOST_GITCONFIG)"
	@printf "  %-19s %s\n" "Container user:" "$(CONTAINER_USER) ($(HOST_UID):$(HOST_GID))"
	@echo -e "\n$(BCYAN)[Running Containers]$(NC)  (project-wide; other targets act on ENV=$(ENV))"
	@docker ps --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" || true

## @target check : Validate host environment
check:
	$(call GUARD_HOST_ONLY)
	@if [ ! -f .env ]; then echo -e "  $(ERROR) .env file missing. Run 'make setup' first."; exit 1; fi
	@MISSING=$$(awk -F= 'FNR==NR { if ($$0 ~ /^[^#][^=]*=/) want[$$1]=1; next } $$0 ~ /^[^#][^=]*=/ { delete want[$$1] } END { for (k in want) print "    - " k }' .env.example .env); \
	if [ -n "$$MISSING" ]; then \
		echo -e "  $(WARN) .env is missing keys present in .env.example:"; echo "$$MISSING"; \
		echo -e "  $(INFO) They fall back to built-in defaults; copy them over if you need to override."; \
	fi
	@bash scripts/check_preflight.sh
	@if [ "$(IS_WSL)" = "true" ]; then bash scripts/check_wsl.sh; fi
	$(call CHECK_GPU_RUNTIME)

## @target xauth : Refresh X11 GUI authentication
xauth:
	$(call GUARD_HOST_ONLY)
	@if [ -z "$$DISPLAY" ]; then \
		echo -e "  $(INFO) DISPLAY is not set — nothing to authorise."; exit 0; \
	fi
	@# Merge a wildcard-host cookie into HOST_XAUTHORITY. Without this the file
	@# stays empty, check_env.sh falls back to a dummy and every container start
	@# warns "Xauthority missing" — granting xhost alone does not fix that.
	@if command -v xauth >/dev/null 2>&1 && [ -n "$(HOST_XAUTHORITY)" ]; then \
		ERR=$$(mktemp "$${TMPDIR:-/tmp}/devkit-xauth.XXXXXX"); \
		if [ ! -f "$(HOST_XAUTHORITY)" ] && ! touch "$(HOST_XAUTHORITY)" 2>"$$ERR"; then \
			echo -e "  $(WARN) Cannot create $(HOST_XAUTHORITY)"; sed 's/^/    /' "$$ERR"; \
		elif ! xauth nlist "$$DISPLAY" > "$$ERR.list" 2>"$$ERR"; then \
			echo -e "  $(WARN) Could not read X11 authentication for DISPLAY=$$DISPLAY."; \
			sed 's/^/    /' "$$ERR"; \
		elif [ ! -s "$$ERR.list" ]; then \
			echo -e "  $(INFO) No X11 cookie exists for DISPLAY=$$DISPLAY."; \
			echo -e "  $(INFO) Normal on WSLg/XWayland, which authorises local clients via xhost instead."; \
		elif sed -e 's/^..../ffff/' "$$ERR.list" | xauth -f "$(HOST_XAUTHORITY)" nmerge - 2>>"$$ERR"; then \
			echo -e "  $(OK) X11 cookie merged into $(HOST_XAUTHORITY)"; \
		else \
			echo -e "  $(WARN) Could not merge the X11 cookie; GUI apps may not open."; \
			sed 's/^/    /' "$$ERR"; \
		fi; \
		rm -f "$$ERR.list"; \
		rm -f "$$ERR"; \
	fi
	@if command -v xhost >/dev/null 2>&1; then \
		for E in "si:localuser:root" "si:localuser:$$(whoami)"; do \
			xhost +$$E >/dev/null 2>&1 || echo -e "  $(WARN) xhost +$$E failed."; \
		done; \
	fi

## @target verify : Run fast repository validation checks
verify:
	$(call GUARD_HOST_ONLY)
	@echo -e "\n$(BCYAN)[Repository Validation]$(NC)"
	@bash scripts/verify_repo.sh

# =============================================================================
# Docker Workflows
# =============================================================================

## @target build : Build development Docker image
build: check
	$(call GUARD_HOST_ONLY)
	@$(RESOLVE_SVC_MODE); \
	echo -e "  $(INFO) Building image for $$TARGET_SVC..."; \
	$(COMPOSE) --profile $$TARGET_SVC build $$TARGET_SVC $(if $(filter 1 true,$(NO_CACHE)),--no-cache,)

## @target start : Run container environment in background
start: check
	$(call GUARD_HOST_ONLY)
	@$(RESOLVE_SVC_MODE); \
	echo -e "  $(INFO) Starting $$TARGET_SVC environment..."; \
	$(COMPOSE) --profile $$TARGET_SVC up -d $$TARGET_SVC

## @target stop : Stop environment containers
stop:
	$(call GUARD_HOST_ONLY)
	$(COMPOSE) --profile "*" stop $(ENV_SERVICES)
	@echo -e "  $(OK) Stopped $(ENV) containers (other ENV untouched)."

## @target restart : Restart environment containers
restart: stop start

## @target shell : Enter container interactive shell
shell:
	$(call GUARD_HOST_ONLY)
	@$(REQUIRE_CONTAINER); \
	$(EXEC_USER_FLAG); \
	docker exec -it $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER bash

## @target exec : Run a command inside the container with the full DevKit environment
# The paved path for automation, independent of ENV, language and shell.
# Runs through the entrypoint's --env mode, which loads the environment the boot
# sequence resolved and execs the target directly — so a bare binary, `sh -c` or
# a Python process gets exactly what an interactive session has. Shell rc hooks
# (BASH_ENV, /etc/bash.bashrc) only ever reach bash; this does not depend on a
# shell at all. Falls back to bash on images predating the --env mode.
#   make exec CMD='python3 -m pytest'      make exec CMD='cmake --build build'
#   make exec CMD='ros2 topic list'        make exec CMD='./install/bin/app'
# A '$' inside CMD belongs to make first, so double it to reach the container
# shell:  make exec CMD='echo $$ROS_DISTRO'   (a single $ROS_DISTRO expands to
# nothing here and the command silently sees a truncated string).
exec:
	$(call GUARD_HOST_ONLY)
	@if [ -z "$$CMD" ]; then \
		echo -e "  $(ERROR) Usage: make exec CMD='<command>'   e.g. CMD='python3 -m pytest'"; \
		echo -e "  $(INFO) Double any '$$' so it survives make: CMD='echo \$$\$$ROS_DISTRO'"; \
		exit 2; fi
	@$(REQUIRE_CONTAINER); \
	$(EXEC_USER_FLAG); \
	if docker exec $$CONTAINER test -x /entrypoint.sh 2>/dev/null && \
	   docker exec $$CONTAINER grep -q '"--env"' /entrypoint.sh 2>/dev/null; then \
		docker exec $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER /entrypoint.sh --env bash -c "$$CMD"; \
	else \
		docker exec $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER bash -c "$$CMD"; \
	fi

## @target test : Run the project's tests inside the container
# Both go through `make exec` to inherit its entrypoint routing, user
# resolution and container guard. mtest/mlint pick the runner by layout.
test:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) --no-print-directory exec CMD='mtest'

## @target lint : Check style and lint rules inside the container (FIX=1 applies them)
lint:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) --no-print-directory exec CMD='mlint $(if $(filter 1 true,$(FIX)),--fix,)'

## @target term : Launch in-container Terminator GUI window (2x2 grid layout)
# The display probe uses xdpyinfo (x11-utils), not xset (x11-xserver-utils, which
# the image does not install) — with xset the target reported "no display" even
# on a working WSLg/X11 host, so the GUI never launched.
term:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) xauth >/dev/null 2>&1 || true
	@$(REQUIRE_CONTAINER); \
	if docker exec $$CONTAINER xdpyinfo >/dev/null 2>&1; then \
		echo -e "  $(INFO) Launching in-container Terminator GUI ($$CONTAINER)..."; \
		TERM_BIN="$${TERMINAL:-terminator}"; \
		if [ "$$TERM_BIN" = "terminator" ]; then \
			docker exec -d $$CONTAINER terminator -u $(WORKSPACE_PATH)/config/terminator_config 2>/dev/null \
				|| docker exec -d $$CONTAINER terminator; \
		else \
			docker exec -d $$CONTAINER "$$TERM_BIN"; \
		fi; \
	else \
		echo -e "  $(WARN) In-container Terminator GUI requires an active X11 display server."; \
		if [ "$(IS_MACOS)" = "true" ]; then \
			echo -e "  $(CYAN)[Hint]$(NC) On macOS, start XQuartz (X11 server) first, or run '$(GREEN)make shell$(NC)'."; \
		else \
			echo -e "  $(CYAN)[Hint]$(NC) Start your X11 display server, or run '$(GREEN)make shell$(NC)'."; \
		fi; \
	fi

# =============================================================================
# Apptainer & SLURM Artifact Workflows
# =============================================================================

## @target bake-dev : Bake development SIF snapshot (SHARE=1 for system site-packages)
bake-dev:
	$(call GUARD_HOST_ONLY)
	@bash scripts/apptainer_bake.sh --mode dev --env $(ENV) $(if $(filter 1 true,$(SHARE)),--share,)

## @target bake-prod : Bake production SIF artifact
bake-prod:
	$(call GUARD_HOST_ONLY)
	@bash scripts/apptainer_bake.sh --mode prod --env $(ENV)

## @target run-sif : Run or submit SIF artifact
run-sif:
	$(call GUARD_HOST_ONLY)
	@# RUN_ARGS travels through the ENVIRONMENT, like `make exec` does with CMD:
	@# passing it as a quoted argument put its inner quotes through a second round
	@# of shell parsing, so the documented RUN_ARGS='python3 -c "print(1)"' died
	@# with a syntax error. Precedence (RUN_ARGS over APP_COMMAND) is preserved.
	@# A '$' still belongs to make first — double it: RUN_ARGS='echo $$HOME'.
	@APP_COMMAND="$${RUN_ARGS:-$$APP_COMMAND}" bash scripts/apptainer_run.sh --mode $(SIF_MODE) --env $(ENV)

## @target slurm-status : Query active SLURM jobs
slurm-status:
	$(call GUARD_HOST_ONLY)
	@if command -v squeue >/dev/null 2>&1; then squeue -u $$(whoami); else echo "squeue unavailable."; fi

## @target slurm-cancel : Cancel active SLURM jobs
slurm-cancel:
	$(call GUARD_HOST_ONLY)
	@# Cancel ONE job, asked for by id. `scancel -u $$USER` would kill every job
	@# the user has queued, including ones this project never submitted.
	@if ! command -v scancel >/dev/null 2>&1; then \
		echo -e "  $(ERROR) SLURM binary 'scancel' not found."; exit 1; \
	fi
	@if [ -n "$(JOB)" ]; then \
		scancel "$(JOB)" && echo -e "  $(OK) Cancelled job $(JOB)."; \
	elif [ -t 0 ]; then \
		printf "  $(YELLOW)[CONFIRM]$(NC) Job ID to cancel (blank aborts): "; \
		read -r JOBID; \
		if [ -z "$$JOBID" ]; then echo -e "  $(INFO) Aborted."; exit 1; fi; \
		scancel "$$JOBID" && echo -e "  $(OK) Cancelled job $$JOBID."; \
	else \
		echo -e "  $(ERROR) Non-interactive: pass the id explicitly, e.g. 'make slurm-cancel JOB=12345'."; \
		exit 2; \
	fi

# =============================================================================
# Resource Monitoring & Diagnostics
# =============================================================================

## @target gpus : Monitor NVIDIA / DRI GPU usage on host
gpus:
	$(call GUARD_HOST_ONLY)
	@if command -v nvidia-smi >/dev/null 2>&1; then \
		nvidia-smi; \
	elif [ -d /dev/dri ] && compgen -G "/dev/dri/renderD*" >/dev/null; then \
		echo -e "  $(INFO) Intel/AMD iGPU (DRI) active: $$(ls /dev/dri/renderD* 2>/dev/null)"; \
	else \
		echo -e "  $(WARN) No dedicated NVIDIA GPU or DRI iGPU detected on host."; \
	fi

## @target stats : Real-time container resource monitor
stats:
	$(call GUARD_HOST_ONLY)
	@$(REQUIRE_CONTAINER); \
	echo -e "  $(INFO) Streaming container resource stats (Ctrl+C to stop)..."; \
	docker stats $$CONTAINER

## @target top : Detailed process monitor
top:
	$(call GUARD_HOST_ONLY)
	@$(FIND_CONTAINER); \
	if [ -n "$$CONTAINER" ]; then \
		docker top $$CONTAINER; \
	else \
		echo -e "  $(INFO) No running container found. Host process monitor:"; \
		if command -v nvtop >/dev/null 2>&1; then nvtop; elif command -v htop >/dev/null 2>&1; then htop; else top; fi; \
	fi

## @target logs : Stream real-time container logs
logs:
	$(call GUARD_HOST_ONLY)
	@$(REQUIRE_CONTAINER)
	$(COMPOSE) --profile "*" logs -f --tail 100 $(ENV_SERVICES)

## @target update-gpg : Update ROS GPG keys in build scripts
update-gpg:
	$(call GUARD_HOST_ONLY)
	@bash scripts/setup_ros_gpg.sh

## @target down : Stop and remove all project containers
down:
	$(call GUARD_HOST_ONLY)
	$(COMPOSE) --profile "*" down --remove-orphans $(ENV_SERVICES)
	@echo -e "  $(OK) Removed $(ENV) containers (other ENV untouched)."

## @target clean : Delete build and install output directories
clean:
	@# devel/ is the ROS 1 (catkin_make) counterpart of install/: it lives next to
	@# build/ on the workspace root and goes stale exactly the same way.
	@rm -rf build devel log
	@# Workspace convenience links point INTO build/ and install/ using the
	@# container path (/workspace/...), so they are dangling on the host and
	@# certainly dead once the targets are gone. util_setup_links.sh recreates
	@# them on the next interactive shell, so removing them here is free.
	@for l in compile_commands.json .venv colcon.meta; do \
		[ -L "$$l" ] && rm -f "$$l"; \
	done; true
	@if [ -d install ]; then \
		find install -mindepth 1 -maxdepth 1 ! -name '.venv' -exec rm -rf {} + 2>/dev/null || true; \
	fi
	$(if $(filter 0 false no,$(KEEP_VENV)),$(call CONFIRM,This also deletes install/.venv — recreating it needs a full 'mksync'))
	@if [ -n "$(filter 0 false no,$(KEEP_VENV))" ]; then \
		rm -rf install/.venv 2>/dev/null || true; \
		echo -e "  $(OK) Build artifacts and virtualenv removed."; \
	elif [ -d install/.venv ]; then \
		echo -e "  $(OK) Build artifacts cleaned (install/.venv preserved)."; \
		echo -e "  $(INFO) Add KEEP_VENV=0 to remove the virtualenv as well."; \
	else \
		echo -e "  $(OK) Build artifacts cleaned."; \
	fi
	@# Drop install/ itself once nothing is left in it. The entrypoint recreates
	@# it as root inside the container, so a leftover empty dir is both useless
	@# and (being root-owned) un-removable by a later plain `rm`.
	@if [ -d install ] && [ -z "$$(ls -A install 2>/dev/null)" ]; then \
		rmdir install 2>/dev/null || { \
			echo -e "  $(WARN) install/ is root-owned and cannot be removed from the host."; \
			$(call HINT_ROOT_OWNED,install); \
		}; \
	fi
	@if [ -z "$(ROS_INSTALL_VOL)$(DEV_INSTALL_VOL)" ]; then \
		echo -e "  $(INFO) build/install/log are named Docker volumes in this configuration;"; \
		echo -e "  $(INFO) container-side artifacts are removed by 'make clean-all'."; \
	fi

## @target clean-cache : Wipe .docker_cache (host detection cache & placeholders)
clean-cache:
	@RUNNING=$$(docker ps -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" 2>/dev/null | wc -l); \
	if [ "$$RUNNING" -gt 0 ]; then \
		echo -e "  $(ERROR) $$RUNNING container(s) still running with .docker_cache bind-mounted."; \
		echo -e "  $(INFO) Deleting it now makes Docker re-create the mount source as root,"; \
		echo -e "  $(INFO) which locks you out of your own cache. Run 'make down' first."; \
		exit 1; \
	fi
	@# DOCKER_DEV_CACHE_DIR relocates ccache/uv caches (see .env.example).
	@# Guards: refuse '/', relative paths and the workspace root outright, and
	@# require any other absolute path to LOOK like a cache dir ('cache' in the
	@# name) unless FORCE=1 — this is an rm -rf aimed by a config variable.
	@CACHE_DIR="$(or $(DOCKER_DEV_CACHE_DIR),.docker_cache)"; \
	case "$$CACHE_DIR" in \
		.docker_cache) ;; \
		/|"$(HOST_WORKSPACE_PATH)"|"$(HOST_WORKSPACE_PATH)/") \
			echo -e "  $(ERROR) Refusing to delete '$$CACHE_DIR'."; exit 1 ;; \
		/*cache*) ;; \
		/*) if [ -z "$$FORCE" ]; then \
				echo -e "  $(ERROR) '$$CACHE_DIR' does not look like a cache directory (no 'cache' in the path)."; \
				echo -e "  $(INFO) Re-run with FORCE=1 if this really is your relocated cache."; exit 1; \
			fi ;; \
		*)  echo -e "  $(ERROR) DOCKER_DEV_CACHE_DIR must be an absolute path (got: $$CACHE_DIR)"; exit 1 ;; \
	esac; \
	if ! rm -rf "$$CACHE_DIR" .docker_cache 2>/dev/null; then \
		echo -e "  $(ERROR) $$CACHE_DIR contains root-owned entries and cannot be removed."; \
		$(call HINT_ROOT_OWNED,.docker_cache); \
		exit 1; \
	fi
	@echo -e "  $(OK) Cache directory cleaned."

## @target clean-all : Reset containers, named volumes, output & cache
# Order matters: containers must come down BEFORE the cache is wiped, or
# clean-cache's running-container guard aborts the whole target. Named volumes
# hold build artifacts, so this asks first unless FORCE=1 / CI=true.
# KEEP_VENV=1 keeps the virtualenv AND the install volume that holds it, so a
# rebuild reconnects to a ready environment instead of re-running mksync.
clean-all: KEEP_VENV := $(if $(filter 1 true yes,$(KEEP_VENV)),1,0)
clean-all:
	$(call GUARD_HOST_ONLY)
	$(call CONFIRM,This removes '$(COMPOSE_PROJECT_NAME)' containers / named volumes (build/install/log) / compose-built images and host build artifacts$(if $(filter 0,$(KEEP_VENV)), — including install/.venv))
	@# `clean` runs as a sub-make (not a prerequisite) so this single [y/N]
	@# covers everything — FORCE=1 suppresses clean's own venv prompt.
	@$(MAKE) --no-print-directory clean KEEP_VENV=$(KEEP_VENV) FORCE=1
	@# --rmi local drops the images compose built for THIS project only; other
	@# projects' images on the host are never touched.
	@if [ "$(KEEP_VENV)" = "1" ]; then \
		$(COMPOSE) --profile "*" down --remove-orphans --rmi local; \
		for v in $$(docker volume ls -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" 2>/dev/null); do \
			case "$$v" in *install*) echo -e "  $(INFO) Kept volume $$v (holds the virtualenv)." ;; \
			                      *) docker volume rm "$$v" >/dev/null 2>&1 || true ;; esac; \
		done; \
	else \
		$(COMPOSE) --profile "*" down --volumes --remove-orphans --rmi local; \
	fi
	@$(MAKE) --no-print-directory clean-cache
	@echo -e "  $(OK) Full project reset complete (containers, volumes & cache)."

## @target docker-clean : Remove dangling Docker images, build cache & unused volumes
# HOST-WIDE and not limited to this project: an unused volume belonging to a
# different, merely-stopped project is fair game for `prune --volumes`. Always
# show what is at stake and ask, unless FORCE=1 / CI=true.
docker-clean:
	@echo -e "  $(WARN) This prunes Docker data for EVERY project on this host, not just $(COMPOSE_PROJECT_NAME)."
	@docker system df 2>/dev/null | sed 's/^/    /' || true
	@ORPHANS=$$(docker volume ls -qf dangling=true 2>/dev/null); \
	if [ -n "$$ORPHANS" ]; then \
		echo -e "  $(WARN) Unused volumes that WILL be deleted (data is unrecoverable):"; \
		echo "$$ORPHANS" | sed 's/^/    - /'; \
	fi
	$(call CONFIRM,This deletes every unused Docker volume and the whole build cache on this host)
	@docker system prune -f --volumes
	@docker builder prune -a -f
	@echo -e "  $(OK) Global Docker build cache, volumes & dangling images pruned."

# =============================================================================
# Deprecated target names (pre-streamline spellings)
# =============================================================================
# DevKit is a base kit: renaming an entry point breaks the CI of every project
# built on it. These forward to the current target and say where to go — once.
# Deliberately absent from .PHONY and `make help`, so tab completion and the
# guide only ever advertise the current name.
DEPRECATED = @echo -e "  $(WARN) 'make $(1)' is deprecated — use 'make $(2)'." >&2

## deprecated: check-host, env-check → check
check-host env-check:
	$(call DEPRECATED,$@,check)
	@$(MAKE) --no-print-directory check

## deprecated: completion, completion-install → setup
completion completion-install:
	$(call DEPRECATED,$@,setup)
	@bash config/devkit_make_completion.bash --install

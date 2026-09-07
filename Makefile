# =============================================================================
# DevKit Makefile — the host-side entry points. `make help` is the index.
# The literal "DevKit Makefile" above is a marker: tab completion walks up from
# $PWD looking for it, so a DevKit tree is recognised from any subdirectory.
# =============================================================================

SHELL := /bin/bash

# MAKE_TERMOUT is set only when stdout is a terminal, so `make … > log`
# (or NO_COLOR=1) comes out plain.
DEVKIT_COLOR := $(if $(MAKE_TERMOUT),$(if $(NO_COLOR),,yes),)
ifeq ($(DEVKIT_COLOR),)
GREEN  :=
RED    :=
YELLOW :=
CYAN   :=
BCYAN  :=
TEAL   :=
NC     :=
else
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

# Every recipe path here is relative (bash scripts/…, docker/Dockerfile), so a
# `make -f ../Makefile` from a subdirectory failed on the first one with a raw
# "No such file". `make -C <root>` is the supported form. The test is the
# makefile's own NAME, not its directory: make's $(dir)/$(abspath) are
# word-list functions, so a path with a space ('/Users/John Doe/…', which the
# README advertises) came apart and the guard rejected every target.
ifneq ($(firstword $(MAKEFILE_LIST)),Makefile)
$(error Run make from the DevKit root, or 'make -C <root> <target>': this Makefile resolves its script paths relative to the working directory)
endif

# The .env files are DEFAULTS, read the way compose reads them: the command
# line beats the environment, the environment beats .env, .env beats
# .env.example, and a value's surrounding quotes are dropped. Rendered to `?=`
# through the one .env parser (config/util_paths.sh): included as make syntax,
# the file beat an explicit `APT_SNAPSHOT_DATE=… make bake-prod` and a quoted
# UV_SYNC_FLAGS reached compose with its quotes. ENV_AMBIENT names every shell
# exports; for those the file still wins, or the host locale lands in the image.
ENV_AMBIENT := LANG|TZ|DEBIAN_FRONTEND
ENV_MK      := .docker_cache/env.mk
# Temp + mv, and fatal on failure: writing in place was read empty by a
# concurrent make (a `make down` then targeted the project 'devkit'), and a
# .docker_cache left root-owned by an in-container run dropped every .env
# setting without a word.
ENV_MK_STATUS := $(shell mkdir -p .docker_cache 2>/dev/null && tmp=$$(mktemp "$(ENV_MK).XXXXXX" 2>/dev/null) && \
	{ bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_env_render "$$@"' \
		_ '$(ENV_AMBIENT)' $(wildcard .env) .env.example > "$$tmp" && mv "$$tmp" "$(ENV_MK)" && echo ok; } || \
	{ rm -f "$$tmp" 2>/dev/null; echo fail; })
ifeq ($(ENV_MK_STATUS),fail)
$(error Cannot write $(ENV_MK), so .env would be ignored entirely. Check that $(CURDIR) is writable, that .docker_cache is not root-owned from an in-container run ('sudo rm -rf .docker_cache'), and that config/util_paths.sh parses (a CRLF checkout breaks it))
endif
-include $(ENV_MK)
shell_quote = '$(subst ','"'"',$(1))'
# Detector inputs the user set explicitly on the COMMAND LINE or in the
# environment are handed to the probe and key its cache. A value from .env
# arrives as origin `file`, so it is not here — check_env.sh reads those files
# itself, which is what keeps the two answers the same.
DETECT_INPUTS := ROS_DISTRO BASE_IMAGE UV_PYTHON WORKSPACE_PATH DOCKER_DEV_CACHE_DIR HOST_UID HOST_GID
DETECT_OVERRIDES := $(strip $(foreach v,$(DETECT_INPUTS),\
	$(if $(filter command line environment override,$(origin $(v))),$(call shell_quote,$(v)=$($(v))))))

# Template revision. VERSION is committed, so it travels with a fork even when
# the project was created from the GitHub template button and carries none of
# DevKit's history; the short commit is best-effort on top of it.
DEVKIT_VERSION := $(shell cat VERSION 2>/dev/null || echo unknown)
# Only when the repository IS this tree: an extracted template inside another
# git repo reported the enclosing project's commit as the template revision.
DEVKIT_COMMIT  := $(shell [ "$$(git -C $(call shell_quote,$(CURDIR)) rev-parse --show-toplevel 2>/dev/null)" = $(call shell_quote,$(CURDIR)) ] \
	&& git -C $(call shell_quote,$(CURDIR)) rev-parse --short HEAD 2>/dev/null)

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
# Bakes require detection to derive BASE_IMAGE and UV_PYTHON from ROS_DISTRO.
DETECTOR_EXEMPT := help h setup adopt verify ci ci-on ci-off stop down logs clean clean-cache clean-all docker-clean slurm-status slurm-cancel run-sif update-gpg stats top gpus shell exec test lint
# A bare `make` runs the default target (help), so it must not pay for
# detection either — substitute 'help' before filtering.
NEEDS_DETECTOR  := $(filter-out $(DETECTOR_EXEMPT),$(or $(MAKECMDGOALS),help))

# Explicit distro/interpreter overrides must not reuse another pairing's cache.
# The parent hands its path down: `export` gives every sub-make the detector
# inputs in its ENVIRONMENT, so $(origin) said "environment" there and each
# sub-make keyed a hashed file of its own — `make setup` probed the host twice
# and its ide-config child could resolve a different GPU profile than the
# parent's `make status`.
DETECTED_ENV_FILE := $(or $(DEVKIT_DETECT_FILE),.docker_cache/detected-env$(if $(DETECT_OVERRIDES),-$(shell printf '%s' $(call shell_quote,$(DETECT_OVERRIDES)) | cksum | cut -d' ' -f1)).mk)
export DEVKIT_DETECT_FILE := $(DETECTED_ENV_FILE)
ifneq ($(NEEDS_DETECTOR),)
# Included AFTER .env, so its `:=` wins — stale whenever .env is newer, or a
# cache built before an edit overrides ROS_DISTRO forever. `shell test`, not
# `wildcard`: make caches directory listings within a run.
# Beyond mtimes the cache must still DESCRIBE this host: it records the
# workspace it was written for (a copied checkout kept mounting the original)
# and session-scoped paths (the X cookie and the ssh-agent socket change at
# every login; compose then created root-owned directories at the dead paths
# and agent forwarding was silently gone).
DETECTED_ENV_FRESH := $(shell [ -f "$(DETECTED_ENV_FILE)" ] \
	&& [ ! .env -nt "$(DETECTED_ENV_FILE)" ] \
	&& [ ! .env.example -nt "$(DETECTED_ENV_FILE)" ] \
	&& [ ! scripts/check_env.sh -nt "$(DETECTED_ENV_FILE)" ] \
	&& [ ! config/util_paths.sh -nt "$(DETECTED_ENV_FILE)" ] \
	&& grep -qxF 'HOST_WORKSPACE_PATH := $(CURDIR)' "$(DETECTED_ENV_FILE)" \
	&& ! grep -q '^DEVKIT_DETECT_INCOMPLETE :=' "$(DETECTED_ENV_FILE)" \
	&& SESSION_PATHS=$$(sed -n -e 's/^HOST_XAUTHORITY := //p' -e 's/^HOST_SSH_AUTH_SOCK := //p' "$(DETECTED_ENV_FILE)") \
	&& { printf '%s\n' "$$SESSION_PATHS" \
		| { while IFS= read -r p; do [ -z "$$p" ] || [ -e "$$p" ] || exit 1; done; }; } && echo yes)
ifeq ($(DETECTED_ENV_FRESH),)
# Write via temp + mv: a failed or interrupted probe must never leave a partial
# cache behind, because the freshness guard above would then reuse it forever and
# every host mount would silently degrade to its placeholder default.
DETECT_STATUS := $(shell mkdir -p .docker_cache && tmp=$$(mktemp "$(DETECTED_ENV_FILE).XXXXXX") && \
	{ env $(DETECT_OVERRIDES) bash scripts/check_env.sh --makefile > "$$tmp" && mv "$$tmp" "$(DETECTED_ENV_FILE)" && echo ok; } || \
	{ rm -f "$$tmp"; echo fail; })
ifeq ($(DETECT_STATUS),fail)
$(error Host environment detection failed. Run 'bash scripts/check_env.sh' to see the error)
endif
endif
-include $(DETECTED_ENV_FILE)
endif

# One truthiness rule for every switch: FIX/NO_CACHE/SHARE took only 1|true
# while KEEP_VENV and the in-container devkit_is_true also accept yes/on, so
# `make lint FIX=yes` quietly linted without fixing.
is_true  = $(filter 1 true TRUE True yes YES Yes on ON On,$(1))
# The negative is its own list, not "not truthy": `clean` KEEPS the venv unless
# asked otherwise, so an UNSET KEEP_VENV must not read as "delete it".
is_false = $(filter 0 false FALSE False no NO No off OFF Off,$(1))

# Fail fast on input that would silently pick the wrong compose profile.
# Scoped to every target consuming ENV — including down, where `make down
# ENV=ros2` would stop the wrong profile without a word. (clean-all removes
# EVERY ENV's volumes and images by design; its confirmation says so.)
ENV_EXEMPT := help h adopt verify ci ci-on ci-off clean clean-cache docker-clean update-gpg xauth gpus slurm-status slurm-cancel
ifneq ($(filter-out $(ENV_EXEMPT),$(or $(MAKECMDGOALS),help)),)
ifeq ($(filter ros dev,$(ENV)),)
$(error ENV must be 'ros' or 'dev' (got: '$(ENV)'))
endif
GPU_MODE ?= auto
# intel/amd share the iGPU COMPOSE PROFILE but stay distinct vocabulary for the
# in-container `gpu` helper (iris vs radeonsi). Rewriting the variable itself to
# 'igpu' replaced the user's answer before it was exported, so the container ran
# the generic mesa path; the profile mapping lives in RESOLVE_SVC_MODE alone.
ifeq ($(filter auto nvidia igpu intel amd cpu,$(GPU_MODE)),)
$(error GPU_MODE must be auto, nvidia, igpu, intel, amd or cpu (got: '$(GPU_MODE)'))
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

# RESOLVE_SVC_MODE: shell snippet resolving GPU_MODE=auto against detected hardware.
# NVIDIA is only chosen when the container toolkit is actually usable.
define RESOLVE_SVC_MODE
SVC_MODE=$${GPU_MODE:-auto}; \
	case "$$SVC_MODE" in intel|amd) SVC_MODE=igpu ;; esac; \
	if [ "$$SVC_MODE" = "auto" ]; then \
		if [ "$(HAS_NVIDIA)" = "true" ] && [ "$(HAS_TOOLKIT)" = "true" ]; then SVC_MODE=nvidia; \
		elif [ "$(HAS_DRI)" = "true" ]; then SVC_MODE=igpu; \
		else SVC_MODE=cpu; fi; \
	fi; \
	TARGET_SVC="$(SERVICE_PREFIX)-$$SVC_MODE"
endef

# FIND_CONTAINER: the running container of the SELECTED ENV. An unfiltered
# `docker ps | head -1` landed `make exec ENV=ros` in the non-ROS container.
# Docker ANDs repeated `--filter label=`, so the service is matched in awk.
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

# HINT_ROOT_OWNED: remediation for paths Docker re-created as root.
# $(1) = host paths. `clean` and `clean-cache` need the same words.
define HINT_ROOT_OWNED
	echo -e "  $(INFO) Docker creates a missing mount source as root at container start."; \
	echo -e "  $(INFO) Remove it from inside a container (no sudo needed):"; \
	echo -e "  $(INFO)   docker run --rm -v \"$(HOST_WORKSPACE_PATH):/w\" alpine rm -rf $(addprefix /w/,$(1))"
endef

# CONFIRM: cleanup requires interactive consent or an exact true FORCE/CI value.
define CONFIRM
	@SKIP=; \
	for flag in "$$FORCE" "$$CI"; do \
		case "$$flag" in 1|true|TRUE|True|yes|YES|Yes|on|ON|On) SKIP=1 ;; esac; \
	done; \
	if [ -z "$$SKIP" ] && [ -t 0 ]; then \
		printf "  $(YELLOW)[CONFIRM]$(NC) %s [y/N]: " "$(1)"; \
		read -r REPLY; \
		case "$$REPLY" in y|Y|yes|YES) ;; *) echo -e "  $(INFO) Aborted."; exit 1 ;; esac; \
	elif [ -z "$$SKIP" ]; then \
		echo -e "  $(ERROR) Non-interactive cleanup requires FORCE=1." >&2; exit 2; \
	fi
endef

.PHONY: help h setup adopt status check verify ci ci-on ci-off xauth gpus build start stop restart shell exec test lint term bake-dev bake-prod run-sif slurm-status slurm-cancel stats top logs update-gpg down clean clean-cache clean-all docker-clean ide-config

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
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "ci / ci-on / ci-off" "Show GitHub Actions state / switch every workflow on or off"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "xauth" "Refresh X11 GUI authentication"
	@echo -e "\n$(CYAN)[ Docker Container Workflows ] ======================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "build / start / stop" "Build image, launch containers, stop"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "restart / down" "Restart containers / stop & remove containers"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "shell / term" "Interactive container shell / new window"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "ide-config" "Prepare VS Code for the selected ENV and GPU profile"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "exec CMD='...'" "Run command"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "test / lint" "Run project tests / check style (FIX=1 applies)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "logs / stats / top" "Stream logs, real-time stats, process monitor"
	@echo -e "\n$(CYAN)[ Apptainer SIF & SLURM ] ===========================$(NC)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "bake-dev / bake-prod" "Bake development / production SIF artifacts (SHARE=1, PROD_FULL_CUDA=1)"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "run-sif" "Run SIF artifact locally or submit to SLURM"
	@printf "  $(GREEN)%-24s$(NC) : %s\n" "slurm-status / slurm-cancel" "Query active SLURM jobs or cancel one"
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
		echo -e "  $(OK) Created .env (project: $$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1))"; \
	fi
	@bash config/devkit_make_completion.bash --install
	@$(MAKE) xauth
	@# COMPOSE_PROJECT_NAME with the name .env now holds: make read the env
	@# files BEFORE this recipe created .env, and the bare `export` then gave the
	@# child the stale value, so setup's ide.compose.json named a different
	@# compose project than a later standalone `make ide-config`.
	@$(MAKE) ide-config COMPOSE_PROJECT_NAME="$$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1)"

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
	@# .devcontainer/devcontainer.json is excluded: `make setup` rewrites it to
	@# the host's own compose service (ide-config), so the documented order
	@# setup → adopt refused on every host that is not the committed default.
	@if [ -n "$$(git status --porcelain 2>/dev/null | grep -v ' .devcontainer/devcontainer.json$$')" ]; then \
		echo -e "  $(ERROR) Working tree is not clean; commit or stash first." >&2; \
		echo -e "  $(INFO) Adoption rewrites tracked files — keep the diff reviewable." >&2; exit 1; \
	fi
	@# Scoped to the [project] table: a bare `sed s/^name = /` also renamed the
	@# [[tool.uv.index]] entries, and [tool.uv.sources] then pointed at indexes
	@# that no longer existed. Atomic via mv, like setup's .env write.
	@# The description is USER text: read it from the environment (never spliced
	@# into the command) and escape it for a TOML basic string. A DESC carrying a
	@# quote produced description = "Robot "A"" and adopt still reported success.
	@awk ' \
		BEGIN { n = ENVIRON["ADOPT_NAME"]; d = ENVIRON["ADOPT_DESC"]; \
		        gsub(/\\/, "\\\\", d); gsub(/"/, "\\\"", d) } \
		/^\[/            { inproj = ($$0 == "[project]") } \
		inproj && /^name = /                  { print "name = \"" n "\""; next } \
		inproj && d != "" && /^description = / { print "description = \"" d "\""; next } \
		{ print }' src/pyproject.toml > src/pyproject.toml.tmp
	@# Publish only what parses: a half-written identity file is worse than none.
	@# tomllib is 3.11+ (22.04 ships 3.10, macOS CLT 3.9): an older interpreter
	@# skips the check rather than reporting the file as broken TOML.
	@python3 -c 'import sys; exec("try:\n    import tomllib\nexcept ImportError:\n    sys.exit(0)"); tomllib.load(open(sys.argv[1],"rb"))' src/pyproject.toml.tmp \
		|| { rm -f src/pyproject.toml.tmp; \
		     echo -e "  $(ERROR) The generated src/pyproject.toml is not valid TOML; nothing was changed." >&2; exit 1; }
	@mv src/pyproject.toml.tmp src/pyproject.toml
	@# The lock records the project's own name, and `uv sync --locked` (every
	@# production build) refuses a lock that names another project. Rewriting
	@# the one virtual entry is what a relock would do to it; the resolution
	@# itself does not depend on the name.
	@if [ -f src/uv.lock ]; then \
		awk -v n="$(ADOPT_NAME)" ' \
			/^\[\[package\]\]$$/ { flush(); block = $$0 "\n"; inblock = 1; next } \
			inblock { block = block $$0 "\n"; if ($$0 ~ /^source = \{ virtual/) virtual = 1; next } \
			{ flush(); print } \
			END { flush() } \
			function flush() { \
				if (!inblock) return; \
				if (virtual) sub(/\nname = "[^"]*"\n/, "\nname = \"" n "\"\n", block); \
				printf "%s", block; block = ""; inblock = 0; virtual = 0; \
			}' src/uv.lock > src/uv.lock.tmp && mv src/uv.lock.tmp src/uv.lock; \
	fi
	@# Renaming the project makes every container and named volume created under
	@# the old name unreachable — `make status` shows nothing running while they
	@# are, and clean-all cannot see them either. setup refuses for this reason;
	@# adopt says it and asks.
	@OLD="$$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env 2>/dev/null | tail -n 1)"; \
	if [ -n "$$OLD" ] && [ "$$OLD" != "$(ADOPT_NAME)" ]; then \
		LEFT="$$(docker ps -aq --filter "label=com.docker.compose.project=$$OLD" 2>/dev/null | wc -l)"; \
		VOLS="$$(docker volume ls -q --filter "label=com.docker.compose.project=$$OLD" 2>/dev/null | wc -l)"; \
		if [ "$$LEFT" -gt 0 ] || [ "$$VOLS" -gt 0 ]; then \
			echo -e "  $(WARN) '$$OLD' still owns $$LEFT container(s) and $$VOLS volume(s), including the built venv." >&2; \
			echo -e "  $(INFO) They become unreachable under the new name. Run 'make clean-all' first, or re-run with FORCE=1." >&2; \
			bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_is_true "$$1"' _ "$(FORCE)" || exit 1; \
		fi; \
	fi
	@if [ -f .env ]; then \
		sed 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$(ADOPT_NAME)/' .env > .env.tmp && mv .env.tmp .env; \
	fi
	@# Whatever name it carries now, not the literal 'myproject': a second adopt
	@# left the committed default pointing at the first adoption.
	@sed 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$(ADOPT_NAME)/' .env.example > .env.example.tmp && mv .env.example.tmp .env.example
	@echo -e "  $(OK) Adopted as '$(ADOPT_NAME)': src/pyproject.toml, .env.example$$([ -f .env ] && printf ', .env')"
	@echo -e "  $(INFO) Run mksync in the container and commit the updated src/uv.lock."
	@echo -e "  $(INFO) Two files are yours to decide — DevKit cannot guess them:"
	@echo -e "  $(INFO)   README.md   this front page still describes DevKit"
	@echo -e "  $(INFO)   LICENSE     MIT-0 lets you relicense (docs/DEVELOPMENT.md)"
	@echo -e "  $(INFO) The kit's own guides stay in docs/ — keep or delete them."
	@echo -e "  $(INFO) The rest of the checklist: docs/GETTING_STARTED.md"
	@echo -e "  $(INFO) Review with: git diff"

## @target status : Diagnose project and container status
status:
	@# NOT a prerequisite: `make status` is what you run WHEN docker is the
	@# broken thing, and a failing preflight used to abort before printing a
	@# single line of the wiring it exists to show. The gate still stops
	@# build/start, which is where it matters.
	-@$(MAKE) --no-print-directory check
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
	@# Live, not cached: it reads GitHub, so it belongs here rather than under the wiring header.
	@$(CI_STATE); printf "  %-19s %s\n" "GitHub CI:" "$$CI_SUMMARY"
	@echo -e "\n$(BCYAN)[Detected Host Wiring]$(NC)  (refresh: make clean-cache)"
	@printf "  %-19s %s\n" "GPU devices:"  "$(HOST_DRI_MOUNT) | $(HOST_DXG_MOUNT)"
	@printf "  %-19s %s\n" "WSL libs:"     "$(WSL_LIB_DIR_MOUNT)"
	@printf "  %-19s %s\n" "Display:"      "$(DISPLAY_TYPE) | X11=$(HOST_X11_DIR) | WAYLAND=$(if $(HOST_WAYLAND_DISPLAY),$(HOST_WAYLAND_DISPLAY),-)"
	@printf "  %-19s %s\n" "XDG runtime:"  "$(HOST_XDG_RUNTIME_DIR)"
	@printf "  %-19s %s\n" "Xauthority:"   "$(HOST_XAUTHORITY)"
	@printf "  %-19s %s\n" "ssh-agent:"    "$(if $(HOST_SSH_AUTH_SOCK),$(HOST_SSH_AUTH_SOCK),- (not forwarded))"
	@printf "  %-19s %s\n" "git identity:" "$(or $(GIT_CONFIG_PATH),$(HOST_GITCONFIG))"
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
	@# HAS_NVIDIA reaches preflight through make's export: the "GPU but no
	@# NVIDIA runtime" notice lives there, next to the GPU_MODE=nvidia refusal.
	@bash scripts/check_preflight.sh
	@if [ "$(IS_WSL)" = "true" ]; then bash scripts/check_wsl.sh; fi

## @target xauth : Refresh X11 GUI authentication
xauth:
	$(call GUARD_HOST_ONLY)
	@# `exit 0` ends this recipe LINE, not the recipe, so the two blocks below
	@# used to run anyway and a headless host saw "bad display name" plus two
	@# xhost warnings during its very first `make setup`.
	@if [ -z "$$DISPLAY" ]; then \
		echo -e "  $(INFO) DISPLAY is not set — nothing to authorise."; \
	fi
	@# Merge a wildcard-host cookie into HOST_XAUTHORITY. Without this the file
	@# stays empty, check_env.sh falls back to a dummy and every container start
	@# warns "Xauthority missing" — granting xhost alone does not fix that.
	@if [ -n "$$DISPLAY" ] && command -v xauth >/dev/null 2>&1 && [ -n "$(HOST_XAUTHORITY)" ]; then \
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
	@if [ -n "$$DISPLAY" ] && command -v xhost >/dev/null 2>&1; then \
		for E in "si:localuser:root" "si:localuser:$$(whoami)"; do \
			xhost +$$E >/dev/null 2>&1 || echo -e "  $(WARN) xhost +$$E failed."; \
		done; \
	fi

## @target verify : Run fast repository validation checks
verify:
	$(call GUARD_HOST_ONLY)
	@echo -e "\n$(BCYAN)[Repository Validation]$(NC)"
	@bash scripts/verify_repo.sh

# CI_STATE: read the GitHub Actions switch ONCE into CI_LIST (gh's table) and
# CI_SUMMARY (one line). The truth lives on GitHub, never in a local file.
define CI_STATE
CI_LIST=""; \
if ! command -v gh >/dev/null 2>&1; then CI_SUMMARY="unknown — GitHub CLI 'gh' not installed (https://cli.github.com)"; \
elif ! CI_LIST="$$(gh workflow list --all 2>/dev/null)"; then CI_SUMMARY="unknown — gh cannot reach GitHub (gh auth login?)"; \
else \
	CI_TOTAL=$$(grep -c . <<< "$$CI_LIST"); CI_ACTIVE=$$(awk -F'\t' '$$2 == "active"' <<< "$$CI_LIST" | grep -c .); \
	if [ "$$CI_ACTIVE" -eq "$$CI_TOTAL" ]; then CI_SUMMARY="on  ($$CI_ACTIVE/$$CI_TOTAL workflows active)"; \
	elif [ "$$CI_ACTIVE" -eq 0 ]; then CI_SUMMARY="off (0/$$CI_TOTAL workflows active)"; \
	else CI_SUMMARY="mixed ($$CI_ACTIVE/$$CI_TOTAL active)"; fi; \
fi
endef

## @target ci : Show the GitHub Actions switch (per workflow); ci-on / ci-off flip it
# A switch, not a setting: the state is read from and written to GitHub through
# gh, so a copy in .env could only drift. Every workflow FILE is switched, so a
# fork's own one is covered; disabling stops push, cron and dispatch alike.
ci:
	$(call GUARD_HOST_ONLY)
	@$(CI_STATE); \
	printf "  %-19s %s\n" "GitHub CI:" "$$CI_SUMMARY"; \
	[ -z "$$CI_LIST" ] || sed 's/^/    /' <<< "$$CI_LIST"

# Switch only what differs. GitHub answers 403 for a workflow that is already
# in the requested state ("Unable to disable a workflow that is not active"),
# and iterating the FILES meant the first such answer aborted the loop: the
# remaining workflows stayed as they were and make reported failure for work
# that was already done. The list gh returns is both the truth and the plan.
ci-on ci-off:
	$(call GUARD_HOST_ONLY)
	@command -v gh >/dev/null 2>&1 || { \
		echo -e "  $(ERROR) GitHub CLI 'gh' is required (https://cli.github.com); log in once with 'gh auth login'." >&2; exit 1; }
	@ACTION=$(if $(filter ci-on,$@),enable,disable); \
	WANT=$(if $(filter ci-on,$@),active,disabled); \
	$(CI_STATE); \
	[ -n "$$CI_LIST" ] || { echo -e "  $(ERROR) GitHub CI: $$CI_SUMMARY" >&2; exit 1; }; \
	CHANGED=0; KEPT=0; FAILED=0; \
	while IFS="$$(printf '\t')" read -r WF_NAME WF_STATE WF_ID; do \
		[ -n "$$WF_ID" ] || continue; \
		case "$$WF_STATE" in $$WANT*) KEPT=$$((KEPT+1)); continue ;; esac; \
		if gh workflow "$$ACTION" "$$WF_ID" >/dev/null 2>&1; then CHANGED=$$((CHANGED+1)); \
		else echo -e "  $(WARN) Could not $$ACTION '$$WF_NAME' (id $$WF_ID)." >&2; FAILED=$$((FAILED+1)); fi; \
	done <<< "$$CI_LIST"; \
	WF_LOCAL=$$(ls .github/workflows/*.yml 2>/dev/null | grep -c .); WF_LISTED=$$(grep -c . <<< "$$CI_LIST"); \
	[ "$$WF_LOCAL" -le "$$WF_LISTED" ] || echo -e "  $(INFO) $$((WF_LOCAL - WF_LISTED)) workflow file(s) not on GitHub yet — push them, then run this again."; \
	$(CI_STATE); \
	echo -e "  $(OK) GitHub CI: $$CI_SUMMARY ($$CHANGED changed, $$KEPT already there)"; \
	[ "$$FAILED" -eq 0 ]

# =============================================================================
# Docker Workflows
# =============================================================================

## @target build : Build development Docker image
build: check
	$(call GUARD_HOST_ONLY)
	@$(RESOLVE_SVC_MODE); \
	echo -e "  $(INFO) Building image for $$TARGET_SVC..."; \
	$(COMPOSE) --profile $$TARGET_SVC build $$TARGET_SVC $(if $(call is_true,$(NO_CACHE)),--no-cache,)

## @target start : Run container environment in background
start: check
	$(call GUARD_HOST_ONLY)
	@$(RESOLVE_SVC_MODE); \
	echo -e "  $(INFO) Starting $$TARGET_SVC environment..."; \
	for s in $(ENV_SERVICES); do \
		[ "$$s" = "$$TARGET_SVC" ] && continue; \
		docker ps -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" \
			--filter "label=com.docker.compose.service=$$s" | grep -q . || continue; \
		echo -e "  $(INFO) Removing the other $(ENV) variant still up ($$s): one container per ENV, or exec/shell pick whichever docker lists first."; \
		$(COMPOSE) --profile "*" rm -sf "$$s" >/dev/null 2>&1 || true; \
	done; \
	$(COMPOSE) --profile $$TARGET_SVC up -d $$TARGET_SVC

## @target ide-config : Point VS Code at the compose service this host resolves to
# Rewrites one key — which service — because no devcontainer variable can
# express a profile chosen from detected hardware. A line edit, not a JSON
# round-trip: this file is JSONC like every other IDE config here.
# Run by `make setup`; re-run after changing ENV or GPU_MODE. A host without
# compose (a SLURM submit node) has no container to attach to: skip, so that
# `make setup` still finishes its .env / completion / xauth work there.
# `docker compose config` KEEPS the profiles key, and 'abstract' rides in from
# the base-common anchor because `extends` appends: the rendered file then had
# ZERO services enabled and Dev Containers failed with "no service selected".
# The rendered file describes one service — the profiles have done their job, so
# they are stripped.
ide-config:
	$(call GUARD_HOST_ONLY)
	@if ! docker compose version >/dev/null 2>&1; then \
		echo -e "  $(INFO) docker compose is not available here — VS Code attach config skipped."; exit 0; fi; \
	if [ -n "$(DEVKIT_DETECT_INCOMPLETE)" ]; then \
		echo -e "  $(INFO) Host detection was incomplete ($(DEVKIT_DETECT_INCOMPLETE)) — VS Code attach config left as it was."; \
		echo -e "  $(INFO) Re-run 'make ide-config' once docker is up."; exit 0; fi; \
	$(RESOLVE_SVC_MODE); \
	DC=.devcontainer/devcontainer.json; \
	if [ ! -f "$$DC" ]; then \
		echo -e "  $(INFO) $$DC is absent — VS Code attach config skipped."; exit 0; fi; \
	mkdir -p .docker_cache && \
	TMP=$$(mktemp .docker_cache/ide.XXXXXX) && \
	trap 'rm -f "$$TMP" "$$DC.tmp"' EXIT && \
	$(COMPOSE) --profile "$$TARGET_SVC" config --format json > "$$TMP" && \
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s.pop("profiles",None) for s in d.get("services",{}).values()]; json.dump(d,open(sys.argv[1],"w"),indent=2)' "$$TMP" && \
	mv "$$TMP" .docker_cache/ide.compose.json && \
	sed -E -e 's|("service"[[:space:]]*:[[:space:]]*)"[^"]*"|\1"'"$$TARGET_SVC"'"|' \
	       -e 's|("remoteUser"[[:space:]]*:[[:space:]]*)"[^"]*"|\1"'"$(CONTAINER_USER)"'"|' "$$DC" > "$$DC.tmp" && \
	mv "$$DC.tmp" "$$DC" && \
	echo -e "  $(OK) VS Code attaches to $$TARGET_SVC (Reopen in Container)"

## @target stop : Stop environment containers
stop:
	$(call GUARD_HOST_ONLY)
	$(COMPOSE) --profile "*" stop $(ENV_SERVICES)
	@echo -e "  $(OK) Stopped $(ENV) containers (other ENV untouched)."

## @target restart : Restart environment containers
restart:
	$(call GUARD_HOST_ONLY)
	@# Sequential sub-makes: as prerequisites, `make -j restart` started the new
	@# containers before the old ones had stopped.
	@$(MAKE) --no-print-directory stop && $(MAKE) --no-print-directory start

## @target shell : Enter container interactive shell
shell:
	$(call GUARD_HOST_ONLY)
	@$(REQUIRE_CONTAINER); \
	$(EXEC_USER_FLAG); \
	docker exec -it $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER bash

## @target exec : Run a command inside the container with the full DevKit environment
# The paved path for automation. Goes through the entrypoint's --env mode, so a
# bare binary, `sh -c` or a Python process gets what an interactive session has
# (rc hooks only ever reach bash). Falls back to bash on older images.
#   make exec CMD='ros2 topic list'    make exec CMD='./install/bin/app'
# Double any '$' — it belongs to make first: CMD='echo $$ROS_DISTRO'.
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
# DEVKIT_SKIP_CLANG_FORMAT travels WITH the command: `docker exec` forwards none
# of the caller's environment, so the escape hatch mlint's own message names had
# no effect when set on the host — the advertised way out of a fail-closed lint.
lint:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) --no-print-directory exec CMD='$(if $(DEVKIT_SKIP_CLANG_FORMAT),DEVKIT_SKIP_CLANG_FORMAT="$(DEVKIT_SKIP_CLANG_FORMAT)" ,)mlint $(if $(call is_true,$(FIX)),--fix,)'

## @target term : Launch in-container Terminator GUI window (2x2 grid layout)
# terminator is opt-in (dependencies/apt.txt), so the binary is probed first:
# `docker exec -d` would report success for a launch that never happened.
# Probes with xdpyinfo (x11-utils), not xset: the image ships no
# x11-xserver-utils, and xset reported "no display" on a working WSLg host.
# Same user as `shell`/`exec`, or every pane is a root shell writing root-owned
# files into the bind mount. terminator's config flag is -g; -u is --no-dbus,
# and a stray positional argument makes it exit before drawing — silently,
# because `docker exec -d` returns 0 whatever the detached process does.
term:
	$(call GUARD_HOST_ONLY)
	@$(MAKE) xauth >/dev/null 2>&1 || true
	@$(REQUIRE_CONTAINER); \
	$(EXEC_USER_FLAG); \
	TERM_BIN="$${TERMINAL:-terminator}"; \
	if ! docker exec $$CONTAINER sh -c 'command -v "$$1"' _ "$$TERM_BIN" >/dev/null 2>&1; then \
		echo -e "  $(ERROR) '$$TERM_BIN' is not installed in this image." >&2; \
		echo -e "  $(INFO) Uncomment 'terminator # gui' in dependencies/apt.txt and run 'make build' (or set TERMINAL= in .env)."; \
		exit 1; \
	elif docker exec $$CONTAINER xdpyinfo >/dev/null 2>&1; then \
		echo -e "  $(INFO) Launching in-container Terminator GUI ($$CONTAINER)..."; \
		if [ "$$TERM_BIN" = "terminator" ]; then \
			docker exec -d $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER terminator -g "$(WORKSPACE_PATH)/config/terminator_config"; \
		else \
			docker exec -d $$USER_FLAG -w "$(WORKSPACE_PATH)" $$CONTAINER "$$TERM_BIN"; \
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
	@bash scripts/apptainer_bake.sh --mode dev --env $(ENV) $(if $(call is_true,$(SHARE)),--share,)

## @target bake-prod : Bake production SIF artifact
bake-prod:
	$(call GUARD_HOST_ONLY)
	@bash scripts/apptainer_bake.sh --mode prod --env $(ENV)

## @target run-sif : Run or submit SIF artifact
run-sif:
	$(call GUARD_HOST_ONLY)
	@# RUN_ARGS travels through the ENVIRONMENT (make exports it), like `make exec`
	@# does with CMD: as a quoted argument its inner quotes went through a second
	@# round of shell parsing. apptainer_run.sh owns the precedence.
	@# A '$' still belongs to make first — double it: RUN_ARGS='echo $$HOME'.
	@bash scripts/apptainer_run.sh --mode $(SIF_MODE) --env $(ENV)

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
	elif [ -e /dev/dxg ]; then \
		echo -e "  $(INFO) WSL2 D3D12 GPU (/dev/dxg) active — the host GPU is reached through the Mesa bridge."; \
		echo -e "  $(INFO) Run nvidia-smi.exe or Task Manager on Windows for utilisation."; \
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
	$(call GUARD_HOST_ONLY)
	@# The same guard clean-cache has, for the same reason: build/ and install/
	@# are the live container's mount points. Removing them from the host left
	@# the container writing into an unreachable path, and the next start
	@# remounted the volume over it — a build that reported success and a
	@# binary that was the pre-clean one.
	@if [ -z "$(ROS_INSTALL_VOL)$(DEV_INSTALL_VOL)" ]; then \
		RUNNING=$$(docker ps -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" 2>/dev/null | wc -l); \
		if [ "$$RUNNING" -gt 0 ]; then \
			echo -e "  $(ERROR) $$RUNNING container(s) still running with build/ and install/ mounted."; \
			echo -e "  $(INFO) Deleting them now splits the workspace in two: the container keeps writing"; \
			echo -e "  $(INFO) to an unreachable path and a later start remounts the old volume. Run 'make down' first."; \
			exit 1; \
		fi; \
	fi
	@# Ask BEFORE deleting anything: the confirmation used to sit after the rm,
	@# so a non-interactive `make clean KEEP_VENV=0` removed build/, devel/, log/
	@# and install/* and only then refused with 'requires FORCE=1'.
	$(if $(call is_false,$(KEEP_VENV)),$(call CONFIRM,This also deletes install/.venv — recreating it needs a full 'mksync'))
	@# devel/ is the ROS 1 (catkin_make) counterpart of install/: it lives next to
	@# build/ on the workspace root and goes stale exactly the same way. With a
	@# bind-mounted build/ (ROS_BUILD_VOL=./build) Docker created it as root,
	@# and a raw rm failure here gave no way out while install/ got a hint.
	@rm -rf build devel log 2>/dev/null || { \
		echo -e "  $(WARN) build/, devel/ or log/ holds root-owned entries and cannot be removed from the host."; \
		$(call HINT_ROOT_OWNED,build devel log); }
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
	@if [ -n "$(call is_false,$(KEEP_VENV))" ]; then \
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
	$(call GUARD_HOST_ONLY)
	@RUNNING=$$(docker ps -q --filter "label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)" 2>/dev/null | wc -l); \
	if [ "$$RUNNING" -gt 0 ]; then \
		echo -e "  $(ERROR) $$RUNNING container(s) still running with .docker_cache bind-mounted."; \
		echo -e "  $(INFO) Deleting it now makes Docker re-create the mount source as root,"; \
		echo -e "  $(INFO) which locks you out of your own cache. Run 'make down' first."; \
		exit 1; \
	fi
	@# DOCKER_DEV_CACHE_DIR relocates ccache/uv caches (see .env.example).
	@# Guards run on the RESOLVED path: '<ws>/cache/../../<ws>' carries the word
	@# 'cache' and used to pass, aiming this rm -rf at the workspace itself; so
	@# did a parent directory of the workspace. Anything containing it is refused.
	@CACHE_DIR="$(or $(DOCKER_DEV_CACHE_DIR),.docker_cache)"; \
	if [ "$$CACHE_DIR" != .docker_cache ]; then \
		case "$$CACHE_DIR" in \
			/*) ;; \
			*)  echo -e "  $(ERROR) DOCKER_DEV_CACHE_DIR must be an absolute path (got: $$CACHE_DIR)"; exit 1 ;; \
		esac; \
		REAL_CACHE="$$(bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_resolve_path "$$1"' _ "$$CACHE_DIR")"; \
		REAL_WS="$$(bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_resolve_path "$$1"' _ "$(HOST_WORKSPACE_PATH)")"; \
		case "$$REAL_WS/" in \
			"$${REAL_CACHE%/}/"*) echo -e "  $(ERROR) '$$CACHE_DIR' resolves to '$$REAL_CACHE', which contains this workspace; refusing to delete it."; exit 1 ;; \
		esac; \
		case "$$REAL_CACHE" in \
			*cache*) ;; \
			*)  if ! bash -c 'source config/util_paths.sh >/dev/null 2>&1; devkit_is_true "$$1"' _ "$$FORCE"; then \
					echo -e "  $(ERROR) '$$REAL_CACHE' does not look like a cache directory (no 'cache' in the resolved path)."; \
					echo -e "  $(INFO) Re-run with FORCE=1 if this really is your relocated cache."; exit 1; \
				fi ;; \
		esac; \
		CACHE_DIR="$$REAL_CACHE"; \
	fi; \
	if ! rm -rf "$$CACHE_DIR" .docker_cache 2>/dev/null; then \
		echo -e "  $(ERROR) $$CACHE_DIR contains root-owned entries and cannot be removed."; \
		$(call HINT_ROOT_OWNED,.docker_cache); \
		exit 1; \
	fi
	@echo -e "  $(OK) Cache directory cleaned."

## @target clean-all : Reset containers, named volumes, output & cache
# Containers first, cache second — clean-cache aborts while one is running.
# Asks unless FORCE=1/CI=true. KEEP_VENV=1 keeps the venv and its volume, so a
# rebuild reconnects instead of re-running mksync.
clean-all: KEEP_VENV := $(if $(call is_true,$(KEEP_VENV)),1,0)
clean-all:
	$(call GUARD_HOST_ONLY)
	$(call CONFIRM,This removes EVERY ENV of '$(COMPOSE_PROJECT_NAME)' — ros and dev alike: containers, all six named volumes (build/install/log), compose-built images, host build artifacts and baked SIF/OCI artifacts$(if $(filter 0,$(KEEP_VENV)), — including install/.venv))
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
	@# The bake artifacts live in the workspace root and DEVELOPMENT.md calls
	@# this a full reset; leaving a 100 MB *.oci.tar behind is not one. The
	@# image `bake-prod` tags locally goes with them.
	@BAKED=$$(ls -1 *-prod*.sif *-dev*.sif *.oci.tar *.oci.tar.provenance *.sif.provenance *.sif.sha256 2>/dev/null || true); 	if [ -n "$$BAKED" ]; then 		rm -f $$BAKED && echo -e "  $(OK) Removed baked artifacts: $$(echo $$BAKED | tr '\n' ' ')"; 	fi
	@for img in $$(docker images -q "$(COMPOSE_PROJECT_NAME)_*_prod" 2>/dev/null); do 		docker rmi -f "$$img" >/dev/null 2>&1 || true; 	done
	@echo -e "  $(OK) Full project reset complete (containers, volumes, cache & baked artifacts)."

## @target docker-clean : Remove dangling Docker images, build cache & unused volumes
# HOST-WIDE: `prune --volumes` also takes volumes of other, merely-stopped
# projects. Shows what is at stake and asks, unless FORCE=1 / CI=true.
docker-clean:
	$(call GUARD_HOST_ONLY)
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

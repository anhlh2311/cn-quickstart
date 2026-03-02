.DEFAULT_GOAL := help

KERNEL_NAME := $(shell uname -s)

# ── Load environment ─────────────────────────────────────────────────────────
ifneq (,$(wildcard .env))
    include .env
endif

# export SPLICE_VERSION as IMAGE_TAG (required by Splice LocalNet images)
export IMAGE_TAG=$(SPLICE_VERSION)

ifneq (,$(wildcard .env.local))
    include .env.local
endif

# ── Paths ────────────────────────────────────────────────────────────────────
# Local infrastructure modules (copied from Quickstart)
ifndef MODULES_DIR
  export MODULES_DIR=$(shell pwd)/docker/modules
endif

ifndef LOCALNET_DIR
  export LOCALNET_DIR=$(MODULES_DIR)/localnet
endif

# Default: no resource constraints (lighter for dev)
RESOURCE_CONSTRAINTS_ENABLED ?= false

############################################################################
####  Splice LocalNet (Canton, PostgreSQL, Splice)
############################################################################
DOCKER_COMPOSE_FILES := -f $(LOCALNET_DIR)/compose.yaml
DOCKER_COMPOSE_PROFILES := --profile app-provider --profile sv
DOCKER_COMPOSE_ENVFILE := --env-file .env --env-file $(LOCALNET_DIR)/compose.env --env-file $(LOCALNET_DIR)/env/common.env

ifneq (,$(wildcard .env.local))
    DOCKER_COMPOSE_ENVFILE += --env-file .env.local
endif

ifeq ($(RESOURCE_CONSTRAINTS_ENABLED),true)
  RESOURCE_CONSTRAINT_CONFIG := -f $(LOCALNET_DIR)/resource-constraints.yaml
endif

############################################################################
####  Splice Onboarding
############################################################################
DOCKER_COMPOSE_FILES += -f $(MODULES_DIR)/splice-onboarding/compose.yaml
ifeq ($(RESOURCE_CONSTRAINTS_ENABLED),true)
  RESOURCE_CONSTRAINT_CONFIG += -f $(MODULES_DIR)/splice-onboarding/resource-constraints.yaml
endif

############################################################################
####  PQS (app-provider only) — disabled for now, not needed by dapp-core
############################################################################
# DOCKER_COMPOSE_FILES += -f $(MODULES_DIR)/pqs/compose.yaml
# DOCKER_COMPOSE_PROFILES += --profile pqs-app-provider
# DOCKER_COMPOSE_ENVFILE += --env-file $(MODULES_DIR)/pqs/compose.env
# ifeq ($(RESOURCE_CONSTRAINTS_ENABLED),true)
#   RESOURCE_CONSTRAINT_CONFIG += -f $(MODULES_DIR)/pqs/resource-constraints.yaml
# endif

############################################################################
####  Observability (optional — requires modules from Quickstart)
############################################################################
ifeq ($(OBSERVABILITY_ENABLED),true)
  DOCKER_COMPOSE_OBSERVABILITY_FILES = -f $(MODULES_DIR)/observability/compose.yaml -f $(MODULES_DIR)/observability/observability.yaml
  DOCKER_COMPOSE_PROFILES += --profile observability
  DOCKER_COMPOSE_ENVFILE += --env-file $(MODULES_DIR)/observability/compose.env
  ifeq ($(KERNEL_NAME), Darwin)
    DOCKER_COMPOSE_OBSERVABILITY_FILES += -f $(MODULES_DIR)/observability/cadvisor-darwin.yaml
  else ifeq ($(KERNEL_NAME), Linux)
    DOCKER_COMPOSE_OBSERVABILITY_FILES += -f $(MODULES_DIR)/observability/cadvisor-linux.yaml
  endif
endif

############################################################################
####  dapp-core services (wallet-gateway + dapp-core)
############################################################################
DOCKER_COMPOSE_FILES += -f compose.yaml

############################################################################
####  Extra PostgreSQL databases for our services
############################################################################
DOCKER_COMPOSE_FILES += -f compose.postgres-init.yaml

# ── Compose runner ───────────────────────────────────────────────────────────
define docker-compose
	docker compose --project-directory . $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_ENVFILE) $(DOCKER_COMPOSE_PROFILES) $(1)
endef

# ── Checks ───────────────────────────────────────────────────────────────────

.PHONY: docker-available
docker-available:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "Docker CLI not found. See: https://docs.docker.com/engine/install/"; \
		exit 1; \
	fi
	@if ! docker info >/dev/null 2>&1; then \
		echo "Docker is not running. Please start Docker."; \
		exit 1; \
	fi

# ── Full stack (Canton + Splice + PQS + Gateway + dapp-core) ────────────────

.PHONY: build
build: docker-available ## Build dapp-core + wallet-gateway Docker images
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) build)

.PHONY: start
start: docker-available ## Start full stack (Canton + Splice + PQS + Gateway + dapp-core)
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) up -d --no-recreate)

.PHONY: stop
stop: docker-available ## Stop full stack
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) down)

.PHONY: restart
restart: stop start ## Restart full stack

.PHONY: rebuild
rebuild: docker-available ## Rebuild all images and restart full stack
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) down)
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) up -d --build)

# ── App-only targets (assumes infrastructure is already running) ─────────────

.PHONY: start-app
start-app: docker-available ## Start only wallet-gateway + dapp-core
	$(call docker-compose, up -d --no-recreate wallet-gateway dapp-core)

.PHONY: stop-app
stop-app: docker-available ## Stop only wallet-gateway + dapp-core
	$(call docker-compose, rm -s -f dapp-core wallet-gateway)

.PHONY: restart-app
restart-app: stop-app start-app ## Restart only wallet-gateway + dapp-core

.PHONY: restart-dapp-core
restart-dapp-core: docker-available ## Rebuild and restart dapp-core
	$(call docker-compose, rm -s -f dapp-core)
	$(call docker-compose, up -d --build --no-recreate dapp-core)

.PHONY: restart-gateway
restart-gateway: docker-available ## Rebuild and restart wallet-gateway
	$(call docker-compose, rm -s -f wallet-gateway)
	$(call docker-compose, up -d --build --no-recreate wallet-gateway)

# ── Local development ───────────────────────────────────────────────────────

.PHONY: install
install: ## Install dapp-core dependencies
	yarn install

.PHONY: build-local
build-local: ## Build dapp-core TypeScript locally
	yarn build

.PHONY: dev
dev: ## Run dapp-core in dev mode (start infra first with 'make start')
	yarn dev

.PHONY: typecheck
typecheck: ## Run TypeScript type checking
	yarn typecheck

# ── Logs & Status ───────────────────────────────────────────────────────────

.PHONY: logs
logs: docker-available ## Follow all logs
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) logs -f)

.PHONY: logs-app
logs-app: docker-available ## Follow dapp-core + wallet-gateway logs
	$(call docker-compose, logs -f dapp-core wallet-gateway)

.PHONY: logs-canton
logs-canton: docker-available ## Follow Canton logs
	$(call docker-compose, logs -f canton)

.PHONY: logs-splice
logs-splice: docker-available ## Follow Splice logs
	$(call docker-compose, logs -f splice)

.PHONY: status
status: docker-available ## Show status of all containers
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) ps)

.PHONY: compose-config
compose-config: docker-available ## Show resolved compose config
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) config)

# ── Clean ───────────────────────────────────────────────────────────────────

.PHONY: clean
clean: docker-available ## Stop all containers and remove volumes
	$(call docker-compose, $(DOCKER_COMPOSE_OBSERVABILITY_FILES) $(RESOURCE_CONSTRAINT_CONFIG) down -v)

.PHONY: clean-app
clean-app: docker-available ## Stop and remove only app containers (keep infrastructure)
	$(call docker-compose, rm -s -f dapp-core wallet-gateway)

# ── Sync modules from Quickstart ────────────────────────────────────────────

.PHONY: sync-modules
sync-modules: ## Sync infrastructure modules from Quickstart (run after Quickstart updates)
	@QUICKSTART_DIR=$${QUICKSTART_DIR:-../quickstart}; \
	if [ ! -d "$$QUICKSTART_DIR/docker/modules/localnet" ]; then \
		echo "ERROR: Quickstart not found at $$QUICKSTART_DIR"; \
		echo "Set QUICKSTART_DIR env var to point to your Quickstart directory."; \
		exit 1; \
	fi; \
	echo "Syncing modules from $$QUICKSTART_DIR/docker/modules/ ..."; \
	rm -rf docker/modules/localnet docker/modules/splice-onboarding docker/modules/pqs; \
	cp -r "$$QUICKSTART_DIR/docker/modules/localnet" docker/modules/; \
	cp -r "$$QUICKSTART_DIR/docker/modules/splice-onboarding" docker/modules/; \
	cp -r "$$QUICKSTART_DIR/docker/modules/pqs" docker/modules/; \
	echo "Done. Synced localnet, splice-onboarding, pqs modules."

# ── Token Issuer (separate sidekick service) ─────────────────────────────────

.PHONY: start-token-issuer
start-token-issuer: docker-available ## Start token-issuer container (requires infra to be running)
	$(call docker-compose, up -d --build --no-recreate token-issuer)

.PHONY: stop-token-issuer
stop-token-issuer: docker-available ## Stop token-issuer container
	$(call docker-compose, rm -s -f token-issuer)

.PHONY: restart-token-issuer
restart-token-issuer: docker-available ## Rebuild and restart token-issuer
	$(call docker-compose, rm -s -f token-issuer)
	$(call docker-compose, up -d --build --no-recreate token-issuer)

.PHONY: logs-token-issuer
logs-token-issuer: docker-available ## Follow token-issuer logs
	$(call docker-compose, logs -f token-issuer)

# ── Setup contracts ─────────────────────────────────────────────────────────

.PHONY: setup-featured-app
setup-featured-app: ## Create FeaturedAppRight + BatchedMarkersProxy for app-provider
	@bash docker/scripts/setup-featured-app.sh

# ── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@printf "Usage: make [target]\n"
	@printf "\n"
	@printf "\033[1mFull Stack\033[0m (Canton + Splice + Wallet Gateway + dapp-core):\n"
	@printf "  \033[36mbuild\033[0m                     Build dapp-core + wallet-gateway Docker images\n"
	@printf "  \033[36mstart\033[0m                     Start full stack (Canton + Splice + Gateway + dapp-core)\n"
	@printf "  \033[36mstop\033[0m                      Stop full stack\n"
	@printf "  \033[36mrestart\033[0m                   Restart full stack\n"
	@printf "  \033[36mrebuild\033[0m                   Rebuild all images and restart full stack\n"
	@printf "\n"
	@printf "\033[1mApp Only\033[0m (assumes Canton + Splice already running):\n"
	@printf "  \033[36mstart-app\033[0m                 Start only wallet-gateway + dapp-core\n"
	@printf "  \033[36mstop-app\033[0m                  Stop only wallet-gateway + dapp-core\n"
	@printf "  \033[36mrestart-app\033[0m               Restart only wallet-gateway + dapp-core\n"
	@printf "  \033[36mrestart-dapp-core\033[0m         Rebuild and restart dapp-core\n"
	@printf "  \033[36mrestart-gateway\033[0m           Rebuild and restart wallet-gateway\n"
	@printf "\n"
	@printf "\033[1mLocal Development\033[0m:\n"
	@printf "  \033[36minstall\033[0m                   Install dapp-core dependencies\n"
	@printf "  \033[36mbuild-local\033[0m               Build dapp-core TypeScript locally\n"
	@printf "  \033[36mdev\033[0m                       Run dapp-core in dev mode (start infra first)\n"
	@printf "  \033[36mtypecheck\033[0m                 Run TypeScript type checking\n"
	@printf "\n"
	@printf "\033[1mLogs & Status\033[0m:\n"
	@printf "  \033[36mstatus\033[0m                    Show status of all containers\n"
	@printf "  \033[36mlogs\033[0m                      Follow all logs\n"
	@printf "  \033[36mlogs-app\033[0m                  Follow dapp-core + wallet-gateway logs\n"
	@printf "  \033[36mlogs-canton\033[0m               Follow Canton logs\n"
	@printf "  \033[36mlogs-splice\033[0m               Follow Splice logs\n"
	@printf "  \033[36mcompose-config\033[0m            Show resolved compose config\n"
	@printf "\n"
	@printf "\033[1mClean\033[0m:\n"
	@printf "  \033[36mclean\033[0m                     Stop all containers and remove volumes\n"
	@printf "  \033[36mclean-app\033[0m                 Stop and remove only app containers (keep infra)\n"
	@printf "\n"
	@printf "\033[1mToken Issuer\033[0m (sidekick service for testing):\n"
	@printf "  \033[36mstart-token-issuer\033[0m        Start token-issuer container\n"
	@printf "  \033[36mstop-token-issuer\033[0m         Stop token-issuer container\n"
	@printf "  \033[36mrestart-token-issuer\033[0m      Rebuild and restart token-issuer\n"
	@printf "  \033[36mlogs-token-issuer\033[0m         Follow token-issuer logs\n"
	@printf "\n"
	@printf "\033[1mMaintenance\033[0m:\n"
	@printf "  \033[36msync-modules\033[0m              Sync infrastructure modules from Quickstart\n"
	@printf "  \033[36msetup-featured-app\033[0m        Create FeaturedAppRight + BatchedMarkersProxy for app-provider\n"

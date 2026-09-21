.DEFAULT_GOAL := help
SHELL := /bin/bash

# --- Deployment target -------------------------------------------------------
# `local` (default) runs the stack under docker compose on this machine.
# `gcp`   runs it on Google Cloud: Cloud SQL + Cloud Run + Agent Runtime.
# Persisted in .env as TARGET so every command agrees on where it is pointing.
TARGET := $(shell [ -f .env ] && sed -n 's/^TARGET=//p' .env | head -1)
TARGET := $(if $(TARGET),$(TARGET),local)

# Each verb dispatches to the backend for the active target.
define dispatch
	@if [ "$(TARGET)" = "gcp" ]; then ./deploy/gcp/$(1).sh $(ARGS); \
	else ./deploy/local/$(1).sh $(ARGS); fi
endef

help: ## Show available targets
	@printf '  \033[1mtarget: %s\033[0m  (make target-local | make target-gcp)\n\n' "$(TARGET)"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Target switching --------------------------------------------------------
target-local: ## Point every command at docker compose (default)
	@./scripts/set-target.sh local

target-gcp: ## Point every command at Google Cloud
	@./scripts/set-target.sh gcp

target: ## Show the active deployment target
	@./scripts/set-target.sh --show

# --- Lifecycle (dispatched per target) ---------------------------------------
bootstrap: ## Generate .env with fresh random secrets
	@./scripts/bootstrap.sh

up: ## Bring the stack up on the active target and provision it
	$(call dispatch,up)

down: ## Stop the stack (keeps data)
	$(call dispatch,down)

logs: ## Tail logs
	$(call dispatch,logs)

ps: ## Show service status
	$(call dispatch,ps)

urls: ## Print the URLs for the active target
	$(call dispatch,urls)

nuke: ## Stop and DELETE all data
	$(call dispatch,nuke)

# --- Target-independent ------------------------------------------------------
provision: ## Re-apply keys, agent bindings and OpenWebUI settings (idempotent)
	@./scripts/provision.sh

preflight: ## (gcp) Read-only check of credentials, APIs and existing resources
	@./deploy/gcp/preflight.sh

smoke: ## End-to-end verification against the active target
	@./scripts/smoke-test.sh

creds: ## Print admin credentials
	@./scripts/creds.sh

use-vertex: ## Switch the model provider to Vertex AI (EU residency)
	@./scripts/vertex-setup.sh $(ARGS)

use-aistudio: ## Switch the model provider back to Google AI Studio
	@sed -i '' 's|^LITELLM_CONFIG=.*|LITELLM_CONFIG=./litellm/config.aistudio.yaml|' .env
	@$(MAKE) --no-print-directory up

google-login: ## Configure "Sign in with Google" for Open WebUI
	@./scripts/google-oauth.sh $(ARGS)

provider: ## Show which model provider is active
	@grep -E '^LITELLM_CONFIG=' .env | sed 's|.*/config\.|  provider: |; s|\.yaml||'
	@grep -E '^VERTEX_LOCATION=' .env | sed 's|^|  |'

.PHONY: help target target-local target-gcp bootstrap up down logs ps urls nuke \
        provision preflight smoke creds google-login use-vertex use-aistudio provider

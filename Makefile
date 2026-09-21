.DEFAULT_GOAL := help
SHELL := /bin/bash

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Generate .env with fresh random secrets
	@./scripts/bootstrap.sh

up: ## Start the stack and provision it
	docker compose up -d
	@./scripts/provision.sh
	@echo "Open http://localhost:3000"

provision: ## Re-apply keys and OpenWebUI settings (idempotent)
	@./scripts/provision.sh

use-vertex: ## Switch to Vertex AI (region-pinned, EU residency)
	@./scripts/vertex-setup.sh $(ARGS)

use-aistudio: ## Switch back to Google AI Studio
	@sed -i '' 's|^LITELLM_CONFIG=.*|LITELLM_CONFIG=./litellm/config.aistudio.yaml|' .env
	@docker compose up -d litellm && $(MAKE) provision
	@echo "Provider: Google AI Studio"

provider: ## Show which provider is active
	@grep -E '^LITELLM_CONFIG=' .env | sed 's|.*/config\.|  provider: |; s|\.yaml||'
	@grep -E '^VERTEX_LOCATION=' .env | sed 's|^|  |'

down: ## Stop the stack (keeps data)
	docker compose down

logs: ## Tail logs
	docker compose logs -f --tail=100

ps: ## Show service status
	docker compose ps

smoke: ## End-to-end check: gateway auth, model list, chat, embeddings
	@./scripts/smoke-test.sh

creds: ## Print admin credentials for both UIs
	@echo "Secure GPT  http://localhost:3000"
	@grep -E '^ADMIN_EMAIL=' .env | cut -d= -f2- | sed 's/^/  email     /'
	@grep -E '^ADMIN_PASSWORD=' .env | cut -d= -f2- | sed 's/^/  password  /'
	@echo "LiteLLM UI  http://localhost:4000/ui"
	@echo "  username  admin"
	@grep -E '^LITELLM_UI_PASSWORD=' .env | cut -d= -f2- | sed 's/^/  password  /'

nuke: ## Stop and DELETE all data (postgres + chat history)
	docker compose down -v

.PHONY: help bootstrap up provision use-vertex use-aistudio provider down logs ps smoke creds nuke

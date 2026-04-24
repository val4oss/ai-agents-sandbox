# List of supported agents — add new agents here to extend all targets
AGENTS := claude copilot gemini
AGENT  := $(filter $(AGENTS),$(MAKECMDGOALS))

.PHONY: build run clean clean-all help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image — all agents (or: make build <agent>)
	sh scripts/build.sh $(AGENT)

run: ## Start (or resume) the container — all agents (or: make run <agent>)
	sh scripts/run.sh $(AGENT)

clean: ## Remove the container (auth and workspace preserved) (or: make clean <agent>)
	sh scripts/clean.sh $(AGENT)

clean-all: ## Remove the container and all auth tokens (workspace preserved) (or: make clean-all <agent>)
	sh scripts/clean.sh --all $(AGENT)

# no-op targets — enable: make build|run|clean[‑all] <agent>
$(AGENTS):
	@true

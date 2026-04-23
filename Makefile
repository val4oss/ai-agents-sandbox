.PHONY: build run clean clean-all help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image
	sh scripts/build.sh

run: ## Start (or resume) the container
	sh scripts/run.sh

clean: ## Remove the container (auth and workspace preserved)
	sh scripts/clean.sh

clean-all: ## Remove the container and all auth tokens (workspace preserved)
	sh scripts/clean.sh --all

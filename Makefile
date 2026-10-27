# nebula-manager - developer tasks
.PHONY: test lint build release help

help:
	@echo "Targets:"
	@echo "  make test    Run the test suite (./run_tests.sh)"
	@echo "  make lint    Syntax-check the entrypoint and all modules"
	@echo "  make build   Build dist/nebula-manager (single self-contained file)"
	@echo "  make release Alias for build (release artifact)"

test:
	@./run_tests.sh

build:
	@./build_single.sh

release: build

lint:
	@bash -n nebula-manager
	@for f in lib/*.sh lib/bundle/install.sh tests/*.sh run_tests.sh nebula-manager.sh build_single.sh; do bash -n "$$f" || exit 1; done
	@if shellcheck --version >/dev/null 2>&1; then \
		echo "running shellcheck (errors only)..."; \
		shellcheck -x -S error nebula-manager lib/*.sh lib/bundle/install.sh build_single.sh; \
	 else \
		echo "shellcheck unavailable (skipping)"; \
	 fi
	@echo "syntax OK"

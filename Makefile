# Development Makefile for webdav-autosync.koplugin.
#
# Targets:
#   make lint   - selene static analysis (semantic checks)
#   make parse  - LuaJIT parse-check every .lua file (grammar check)
#   make check  - lint + parse (run before committing)
#   make help   - this listing

LUA_FILES := $(wildcard *.lua)

.DEFAULT_GOAL := help
.PHONY: help lint parse check

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Run selene against all Lua sources
	selene .

parse: ## Parse-check every .lua file with LuaJIT
	@set -e; for f in $(LUA_FILES); do \
		if ! luajit -bl "$$f" >/dev/null 2>&1; then \
			echo "FAIL $$f"; \
			luajit -bl "$$f"; \
			exit 1; \
		fi; \
		echo "ok   $$f"; \
	done

check: lint parse ## Run lint and parse together

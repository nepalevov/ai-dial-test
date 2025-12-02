# Path to store test artifacts
ARTIFACT_ROOT ?= /tmp/reports
TESTS_DIR = /tmp/tests.huh
KEEP_TESTS_DIR = 1

.ONESHELL:
.EXPORT_ALL_VARIABLES:

.PHONY: build run lint test test_chat test_overlay help

all: lint build

build:
	docker build -t dial-chat-themes .

run: build
	docker run -p 127.0.0.1:8080:8080/tcp dial-chat-themes

lint:
	docker run --rm -i hadolint/hadolint < Dockerfile

# Run all tests
test: test_chat test_overlay

# Run chat tests
test_chat:
	./scripts/run-e2e-tests.sh --suite chat

# Run overlay tests
test_overlay:
	./scripts/run-e2e-tests.sh --suite overlay

help:
	@echo '===================='
	@echo "  make lint					Lint the Dockerfile"
	@echo "  make build					Build container image"
	@echo "  make run					Run container image"
	@echo "  make test_install			Install dependencies and tooling needed by the tests"
	@echo "  make test        			Run all tests"
	@echo "  make test_chat   			Run chat tests"
	@echo "  make test_overlay			Run overlay tests"
	@echo "  make help        			Display this help message"

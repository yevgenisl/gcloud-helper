SHELL := /usr/bin/env bash
PROJECT_ID ?= canaverse
REGION ?= europe-west1
ZONE ?= europe-west1-b
ENVIRONMENT ?= local
RUN_ID ?= local
TF_STATE_BUCKET ?= $(PROJECT_ID)-tofu-state
TF_DIR := infra/gcp-demo-vm

export PROJECT_ID REGION ZONE ENVIRONMENT RUN_ID TF_STATE_BUCKET

.PHONY: init demo-up demo-status demo-smoke deploy-compose demo-down demo-clean-stale fmt validate

init:
	./scripts/bootstrap-state-bucket.sh
	./scripts/tofu-init.sh

fmt:
	cd $(TF_DIR) && tofu fmt -recursive

validate: init
	cd $(TF_DIR) && tofu validate

demo-up: init
	./scripts/demo-up.sh

demo-status:
	./scripts/demo-status.sh

demo-smoke:
	./scripts/demo-smoke.sh

deploy-compose:
	./scripts/deploy-compose-on-vm.sh

demo-down:
	./scripts/demo-down.sh

demo-clean-stale:
	./scripts/janitor-cleanup.sh

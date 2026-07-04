SHELL := /usr/bin/env bash
PROJECT_ID ?= canaverse
REGION ?= europe-west1
ZONE ?= europe-west1-b
ENVIRONMENT ?= local
RUN_ID ?= local
TF_STATE_BUCKET ?= $(PROJECT_ID)-tofu-state
TF_DIR := infra/gcp-demo-vm

export PROJECT_ID REGION ZONE ENVIRONMENT RUN_ID TF_STATE_BUCKET

.PHONY: init demo-up demo-status demo-smoke deploy-compose demo-down tofu-state-snapshot demo-clean-stale fmt validate

init:
	./scripts/bootstrap-state-bucket.sh
	./scripts/tofu-init.sh

fmt:
	cd $(TF_DIR) && tofu fmt -recursive

validate: init
	cd $(TF_DIR) && tofu validate

demo-up: init
	./scripts/tofu-apply.sh

demo-status:
	./scripts/demo-status.sh

demo-smoke:
	./scripts/demo-smoke.sh

deploy-compose:
	./scripts/deploy-compose-on-vm.sh

demo-down:
	./scripts/tofu-destroy.sh

# Upload the on-disk state to GCS and emit a local backup. Safe to call any
# number of times. Used by the CI workflow on `if: always()` so a partial
# apply always leaves recoverable state behind.
tofu-state-snapshot:
	./scripts/tofu-state-snapshot.sh

demo-clean-stale:
	./scripts/janitor-cleanup.sh

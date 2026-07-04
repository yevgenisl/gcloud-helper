# GCloud Helper

OpenTofu + GCE startup bootstrap + Makefile wrapper for creating a disposable GCP demo/CI VM.

Default region decision: **`europe-west1` / Belgium**.

> Note: the original plan said "cloud-init". In the local end-to-end test, Fedora Cloud on GCE did not process `user-data`/cloud-init metadata by default. The working v1 uses the native GCE `metadata_startup_script`, which provides the same first-boot bootstrap role and is more reliable on Google Compute Engine. We can reintroduce cloud-init later if we standardize on an image that has it enabled.

## Prerequisites

- `gcloud` authenticated to project `canaverse`
- `tofu` installed
- GCS bucket for remote state
- `GOOGLE_APPLICATION_CREDENTIALS` pointing at the Hermes service-account JSON, or the default path used by scripts:

```text
~/.config/gcloud/service-accounts/hermess-sa.json
```

## Quick start

```bash
make init
make demo-up
make demo-status
make demo-smoke
make demo-down
```

## Defaults

```text
PROJECT_ID=canaverse
REGION=europe-west1
ZONE=europe-west1-b
MACHINE_TYPE=e2-standard-2
IMAGE_PROJECT=fedora-cloud
IMAGE_FAMILY=fedora-cloud-43-x86-64
BOOT_DISK_SIZE_GB=30
BOOT_DISK_TYPE=pd-balanced
DEMO_PORT=8080
CREATE_FIREWALL_RULES=false
ADD_SSH_KEY=true
SSH_USER=<local whoami>
SSH_PUBLIC_KEY_PATH=~/.ssh/id_rsa.pub
AUTO_DELETE_AFTER_DURATION=true
MAX_RUN_DURATION_SECONDS=10800 # 3 hours
```

State bucket defaults to:

```text
canaverse-tofu-state
```

Override any variable through environment variables, for example:

```bash
ZONE=europe-west1-c RUN_ID=local-test make demo-up
```

## Automatic VM deletion safety backstop

By default, the VM is configured with a GCP scheduling limit:

```text
AUTO_DELETE_AFTER_DURATION=true
MAX_RUN_DURATION_SECONDS=10800
```

That means GCP should automatically delete the VM after **3 hours** even if CI/local cleanup fails.

This is only a backstop. Always prefer normal cleanup:

```bash
make demo-down
```

Override the lifetime when needed:

```bash
MAX_RUN_DURATION_SECONDS=21600 make demo-up # 6 hours
```

Disable the backstop only for debugging:

```bash
AUTO_DELETE_AFTER_DURATION=false make demo-up
```

Note: GCP auto-deletes the VM, but OpenTofu-managed companion resources such as firewall rules may remain until `make demo-down` or janitor cleanup runs.

## SSH key behavior

By default, each VM gets an instance-level SSH metadata entry from:

```text
~/.ssh/id_rsa.pub
```

The wrapper passes:

```text
ADD_SSH_KEY=true
SSH_USER=$(whoami)
SSH_PUBLIC_KEY_PATH=$HOME/.ssh/id_rsa.pub
```

Override when needed:

```bash
SSH_USER=demo SSH_PUBLIC_KEY_PATH=~/.ssh/demo.pub make demo-up
```

Disable instance-level SSH key injection:

```bash
ADD_SSH_KEY=false make demo-up
```

Verified locally with raw SSH:

```bash
ssh -i ~/.ssh/id_rsa "$USER@<external-ip>" 'curl -fsS http://127.0.0.1:8080/health'
```

## Reusable GitHub Actions workflow

This repo exposes a reusable workflow:

```text
.github/workflows/demo-vm.yaml
```

Use it from another repo as a job:

```yaml
name: Demo VM smoke

on:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  demo-vm:
    uses: yevgenisl/gcloud-helper/.github/workflows/demo-vm.yaml@main
    with:
      mode: e2e
      environment: ci
      run_id: superapp-${{ github.run_id }}
      create_firewall_rules: false
      max_run_duration_seconds: "10800"
```

Auth uses the known-good Workload Identity Federation pattern:

```yaml
- uses: google-github-actions/auth@v2.1.7
  with:
    workload_identity_provider: projects/370364006392/locations/global/workloadIdentityPools/github-pool/providers/github-provider
    service_account: github-actions-sa@canaverse.iam.gserviceaccount.com
```

### Modes

| Mode | Behavior |
|---|---|
| `e2e` | `make init`, `make demo-up`, optional compose deploy, `make demo-smoke`, `make demo-down` in `always()` cleanup. Best default for CI. |
| `up` | Provisions the VM and exposes outputs for downstream jobs. |
| `smoke` | Runs smoke check against an existing `run_id` state. |
| `down` | Destroys resources for an existing `run_id` state. Use in `if: always()` cleanup jobs. |

### Optional Docker Compose app deployment

The workflow can deploy the caller/app repository to the VM after provisioning:

```yaml
with:
  mode: e2e
  app_deploy: true
  app_repo: yevgenisl/canabis-assistant-api
  app_ref: ${{ github.ref_name }}
  app_name: canabis-assistant-api
  app_port: "8080"
  create_firewall_rules: true
```

Deployment behavior:

1. checks out the app repo in the GitHub runner;
2. packages it without `.git`;
3. uploads it to the VM with `gcloud compute scp`;
4. extracts it under `/opt/<app_name>`;
5. writes a safe default `.env` when no `app_env` secret is provided;
6. runs `podman compose` / `podman-compose` with `postgres api`;
7. verifies `http://127.0.0.1:<app_port>/health` from inside the VM.

For real non-mock LLM mode, pass a workflow secret named `app_env` containing the desired `.env` content. Do not put API keys in workflow inputs.

### Outputs

The reusable workflow exposes:

```text
run_id
instance_name
zone
external_ip
demo_url
```

Example provision-only flow from a caller repo:

```yaml
jobs:
  demo-up:
    uses: yevgenisl/gcloud-helper/.github/workflows/demo-vm.yaml@main
    permissions:
      contents: read
      id-token: write
    with:
      mode: up
      run_id: superapp-${{ github.run_id }}
      create_firewall_rules: true

  use-demo:
    runs-on: ubuntu-latest
    needs: demo-up
    steps:
      - run: curl -fsS "${{ needs.demo-up.outputs.demo_url }}/health"

  demo-down:
    if: always()
    needs: [demo-up, use-demo]
    uses: yevgenisl/gcloud-helper/.github/workflows/demo-vm.yaml@main
    permissions:
      contents: read
      id-token: write
    with:
      mode: down
      run_id: superapp-${{ github.run_id }}
      create_firewall_rules: true
```

For private cross-repo checkout edge cases, pass a secret named `infra_repo_token` with `contents:read` on this infra repo.

A copy-pasteable caller template is also stored at:

```text
examples/caller-workflow.yaml
```

### WIF note

The workflow uses the same auth shape as `canabis-assistant-api/.github/workflows/auth_gcp.yaml`.
For a repo to call this workflow successfully, the GCP Workload Identity binding must allow that caller repository's OIDC subject to impersonate:

```text
github-actions-sa@canaverse.iam.gserviceaccount.com
```

A manual `workflow_dispatch` from this infra repo is a good syntax test, but it will fail at token refresh unless the WIF binding also allows `yevgenisl/gcloud-helper`.

## Permission notes

The Hermes service account has been verified for:

- VM create/delete;
- remote GCS state bucket bootstrap/use;
- optional temporary firewall rule create/delete.

Use the safer default for CI smoke checks:

```bash
CREATE_FIREWALL_RULES=false make demo-up
make demo-smoke
```

Use public demo access when needed:

```bash
CREATE_FIREWALL_RULES=true make demo-up
```

With `CREATE_FIREWALL_RULES=true`, OpenTofu creates temporary HTTP `8080` and SSH `22` firewall rules for the VM tag and removes them on `make demo-down`.

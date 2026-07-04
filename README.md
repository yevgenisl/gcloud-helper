# GCP Ephemeral Demo VM

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
```

State bucket defaults to:

```text
canaverse-tofu-state
```

Override any variable through environment variables, for example:

```bash
ZONE=europe-west1-c RUN_ID=local-test make demo-up
```

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

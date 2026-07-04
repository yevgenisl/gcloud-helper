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
```

State bucket defaults to:

```text
canaverse-tofu-state
```

Override any variable through environment variables, for example:

```bash
ZONE=europe-west1-c RUN_ID=local-test make demo-up
```

## Permission notes

The current Hermes service account can create/delete VMs, but remote GCS state bootstrap and firewall creation require extra permissions:

- state bucket bootstrap: `storage.buckets.create`, `storage.buckets.get`, `storage.buckets.update`, and object access on the state bucket;
- optional firewall creation: `compute.firewalls.create` and `compute.networks.updatePolicy`.

Until firewall permissions are granted, `CREATE_FIREWALL_RULES=false` and `make demo-smoke` checks the in-VM health endpoint through `gcloud compute ssh`.

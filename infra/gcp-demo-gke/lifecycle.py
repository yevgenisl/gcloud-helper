#!/usr/bin/env python3
"""Guarded GCS-state GKE lifecycle. Never guesses scope; gcloud is read-only status."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

MODULE = Path(__file__).resolve().parent
ROOT = MODULE / ".runs"
APIS = {"compute.googleapis.com", "container.googleapis.com", "iam.googleapis.com",
        "logging.googleapis.com", "monitoring.googleapis.com"}
RESOURCES = {"google_compute_network.demo", "google_compute_subnetwork.demo",
             "google_compute_router.demo", "google_compute_router_nat.demo",
             "google_service_account.node", "google_project_iam_member.node",
             "google_container_cluster.demo", "google_container_node_pool.demo"}
RESOURCES |= {f'google_project_service.required["{api}"]' for api in APIS}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(config):
    for key, pattern in {
        "app": r"[a-z][a-z0-9-]{0,10}",
        "environment": r"[a-z][a-z0-9-]{0,10}",
        "state_bucket": r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]",
        "project": r"[a-z][a-z0-9-]{4,28}[a-z0-9]",
        "zone": r"[a-z]+-[a-z]+[0-9]+-[a-z]",
        "owner": r"[a-z]([a-z0-9-]{0,9}[a-z0-9])?",
        "run": r"[a-z]([a-z0-9-]{0,9}[a-z0-9])?",
        "billing_owner": r"[a-z][a-z0-9_-]{0,62}",
    }.items():
        require(re.fullmatch(pattern, config[key]), f"Invalid {key}")
    require(len(resource_name(config)) <= 30, "Combined app/environment/owner/run name exceeds SA limit 30")
    net = ipaddress.IPv4Network(config["admin_cidr"], strict=True)
    allowed = [ipaddress.IPv4Network(c) for c in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    require(net.version == 4 and net.prefixlen >= 24 and any(net.subnet_of(c) for c in allowed),
            "admin_cidr must be canonical RFC1918 IPv4 /24 or narrower")
    require(type(config["spot"]) is bool, "spot must be boolean")


def resource_name(config):
    return "-".join(config[k] for k in ("app", "environment", "owner", "run"))


def backend_prefix(config):
    return "/".join([config["app"] + "-demo", "gke"] + [config[k] for k in ("environment", "project", "zone", "owner", "run")])


def identity(config):
    return "/".join(config[k] for k in ("app", "environment", "project", "zone", "owner", "run", "state_bucket"))


def check_resource(address, values, config):
    """Fail closed on foreign state/imports, including same-project resources."""
    require(address in RESOURCES, f"Unexpected resource in state/plan: {address}")
    if values is None:
        return
    name = resource_name(config)
    require(values.get("project") == config["project"], f"Foreign/unknown project: {address}")
    if address.startswith("google_project_service."):
        require(address == f'google_project_service.required["{values.get("service")}"]', "Foreign API")
        require(values.get("disable_on_destroy") is False, "API disabling is forbidden")
    elif address == "google_project_iam_member.node":
        require(values.get("role") == "roles/container.defaultNodeServiceAccount", "Unexpected IAM role")
        require(values.get("member") == f'serviceAccount:{name}@{config["project"]}.iam.gserviceaccount.com',
                "Foreign/unknown IAM member")
    elif address == "google_service_account.node":
        require(values.get("account_id") == name, "Foreign service account")
    else:
        require(values.get("name") == name, f"Foreign resource name: {address}")
        if address.startswith("google_container_"):
            require(values.get("location") == config["zone"], "Foreign cluster zone")
        elif address.startswith(("google_compute_subnetwork", "google_compute_router")):
            require(values.get("region") == config["zone"].rsplit("-", 1)[0], "Foreign region")


def check_state(state, config):
    root = state.get("values", {}).get("root_module", {})
    require(not root.get("child_modules"), "Unexpected modules in state")
    for resource in root.get("resources", []):
        check_resource(resource["address"], resource["values"], config)


def check_plan(plan, config, action):
    for change in plan.get("resource_changes", []):
        require(change.get("mode", "managed") == "managed", "Unexpected data source")
        data = change["change"]
        check_resource(change["address"], data.get("before"), config)
        check_resource(change["address"], data.get("after"), config)
        actions = data["actions"]
        require(action == "destroy" or "delete" not in actions,
                "Replacement/deletion requires separate review; runner refuses outside destroy")
        if action in ("pause", "resume") and actions != ["no-op"]:
            require(change["address"] == "google_container_node_pool.demo" and actions == ["update"],
                    "Pause/resume may only update the existing node pool")
            before, after = data["before"], data["after"]
            changed = {k for k in before.keys() | after.keys() if before.get(k) != after.get(k)}
            require(changed <= {"node_count"}, f"Unexpected pause/resume drift: {changed}")
            require(after["node_count"] == (0 if action == "pause" else 1), "Unexpected node count")


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["plan", "provision", "status", "pause", "resume", "destroy"])
    for key in ("app", "environment", "state-bucket", "project", "zone", "owner", "run", "billing-owner", "admin-cidr"):
        p.add_argument("--" + key, required=True)
    p.add_argument("--spot", action="store_true")
    p.add_argument("--authorize", help="Exact ACTION:PROJECT/ZONE/OWNER/RUN acknowledgment of a separately approved run")
    p.add_argument("--tofu", default="tofu", help="OpenTofu executable (must be 1.12.3)")
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    config = {key: getattr(args, key) for key in
              ("app", "environment", "state_bucket", "project", "zone", "owner", "run", "billing_owner", "admin_cidr", "spot")}
    validate(config)
    mutation = args.action not in ("plan", "status")
    if args.action != "status":
        require(args.authorize == f"{args.action}:{identity(config)}", "Missing exact --authorize acknowledgment")
    # Forbid injected CLI args/workspaces/variables/backend endpoints. Credentials via ADC are supported.
    require(not any(k.startswith(("TF_", "TOFU_")) for k in os.environ),
            "Unset TF_* / TOFU_* environment overrides before running")
    os.umask(0o077)
    folder = ROOT / backend_prefix(config) / config["state_bucket"]
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = folder / "identity.json"
        if manifest.exists():
            require(json.loads(manifest.read_text()) == config, "Run configuration is immutable; use the original inputs")
        else:
            manifest.write_text(json.dumps(config, indent=2) + "\n")
        # Dedicated root: no auto.tfvars or unrelated .tf/backend files can join the plan.
        expected = {"main.tf", "variables.tf", ".terraform.lock.hcl", "identity.json", "lock",
                    "inputs.json", "intent.json", "terraform.tfstate", "terraform.tfstate.backup",
                    ".terraform", "review.tfplan", "backend.hcl"}
        require(all(p.name in expected for p in folder.iterdir()), "Unexpected files in isolated run directory")
        for filename in ("main.tf", "variables.tf", ".terraform.lock.hcl"):
            shutil.copyfile(MODULE / filename, folder / filename)
        env = dict(os.environ, TF_IN_AUTOMATION="1")

        def tofu(*arguments, capture=False):
            return subprocess.run([args.tofu, f"-chdir={folder}", *arguments], env=env,
                                  check=True, text=True, capture_output=capture).stdout

        version = json.loads(tofu("version", "-json", capture=True))
        require(version["terraform_version"] == "1.12.3", "OpenTofu 1.12.3 required")
        (folder / "backend.hcl").write_text(
            'bucket = ' + json.dumps(config["state_bucket"]) + '\n' +
            'prefix = ' + json.dumps(backend_prefix(config)) + '\n')
        tofu("init", "-input=false", "-lockfile=readonly", "-reconfigure", "-backend-config=backend.hcl")
        metadata = json.loads((folder / ".terraform/terraform.tfstate").read_text())
        backend = metadata["backend"]
        require(backend["type"] == "gcs" and backend["config"]["bucket"] == config["state_bucket"]
                and backend["config"]["prefix"] == backend_prefix(config), "Effective backend mismatch")
        tofu("validate")
        state = json.loads(tofu("show", "-json", capture=True))
        check_state(state, config)
        state_exists = bool(state.get("values", {}).get("root_module", {}).get("resources", []))
        if state_exists:
            require(state.get("values", {}).get("outputs", {}).get("deployment_config", {}).get("value") == config,
                    "Remote run configuration differs; use original inputs")
        if args.action == "status":
            # API read only; no Kubernetes context changes, and explicit scope on every invocation.
            subprocess.run(["gcloud", "container", "clusters", "describe", resource_name(config),
                            "--project", args.project, "--zone", args.zone, "--format=json"], check=True)
            return
        if args.action in ("pause", "resume", "destroy"):
            require(state_exists, "Refuse lifecycle mutation without existing state")
        intent = folder / "intent.json"
        pools = [r for r in state.get("values", {}).get("root_module", {}).get("resources", [])
                 if r["address"] == "google_container_node_pool.demo"]
        paused = bool(pools and pools[0]["values"]["node_count"] == 0)
        if args.action in ("pause", "resume"):
            paused = args.action == "pause"
        inputs = folder / "inputs.json"
        inputs.write_text(json.dumps(dict(config, paused=paused)))
        plan = folder / "review.tfplan"
        try:
            command = ["plan", "-input=false", "-lock-timeout=30s", "-var-file=inputs.json", "-out=review.tfplan"]
            if args.action == "destroy":
                command.append("-destroy")
            tofu(*command)
            result = json.loads(tofu("show", "-json", "review.tfplan", capture=True))
            check_plan(result, config, args.action)
            if mutation:
                tofu("apply", "-input=false", "-lock-timeout=30s", "review.tfplan")
                intent.write_text(json.dumps({"paused": paused}))
            else:
                print("Read-only plan complete; nothing applied. Saved plan removed to prevent stale apply.")
        finally:
            plan.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

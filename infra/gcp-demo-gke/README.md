# Opt-in one-node GKE target (code-only / live acceptance pending)

Moved from wallaweed/ai-employee PR15, commit 60d0a68dc8e7331fe0c8fb530e31adaf195cc57a.
This is the single shared GKE infrastructure implementation, not a VM/Compose adapter.
VM entrypoints/defaults remain unchanged; `DEMO_TARGET=gke` dispatches demo-up/down/status
before VM common.sh (no workstation credentials/default projects inherited).
Other VM entrypoints reject non-VM targets. `scripts/demo-gke.sh ACTION` also supports
plan/provision/status/pause/resume/destroy with exactly the same explicit arguments.

Required CLI: --app --environment --state-bucket --project --zone --owner --run
--billing-owner --admin-cidr; optional --spot. Combined app-environment-owner-run must
fit the 30-character service-account limit. Choose distinct names for each application.
Every action except status requires --authorize ACTION:APP/ENVIRONMENT/PROJECT/ZONE/OWNER/RUN/BUCKET.
Acknowledgement is not permission: obtain human cloud authorization first. Plans read cloud
APIs and write state locks; they never apply. Provision creates/reviews a fresh saved plan and
applies only that checked plan. Pause/resume only permit node_count updates; destruction
only permits this module's explicitly named project/zone resources and additive IAM member.
No sweeps, API disabling, bucket creation, images, runtime transport, credentials or schedulers.

An existing GCS bucket with restricted operator access, versioning/retention and ADC is a
prerequisite. Prefix: APP-demo/gke/ENVIRONMENT/PROJECT/ZONE/OWNER/RUN; never the legacy VM
superapp-demo/ENV/RUN prefix. Init -reconfigure precedes every state read/plan/apply; effective
backend metadata is checked. The remote deployment_config output binds immutable inputs;
node_count in remote state preserves paused intent across disposable checkouts. Local .runs
is private staging/locking only, not canonical state. Never manually import unrelated resources.
Terraform state is sensitive infrastructure metadata, NOT a tenant artifact store. Do not
migrate earlier local state automatically. Existing local deployments require separate review.
GKE has no VM maximum-runtime expiry. Operator cleanup remains mandatory and pause costs money.

The stage copies only main.tf, variables.tf and the provider lockfile (never source trees,
.env, credentials or state); generated inputs contain only this explicit infrastructure contract.
Raw provider output/state must not be published as CI artifacts. No requested runtime hook is
implemented or silently skipped here: Kubernetes manifests/secret references/hooks belong to
caller downstream work. Private route, node readiness/logging/policy enforcement and live
pause/resume/teardown require separately authorized acceptance.

Offline validation:
```
python3 -m unittest discover -s infra/gcp-demo-gke/tests -v
tofu -chdir=infra/gcp-demo-gke init -backend=false -lockfile=readonly
tofu -chdir=infra/gcp-demo-gke fmt -check -recursive
tofu -chdir=infra/gcp-demo-gke validate
tofu -chdir=infra/gcp-demo-gke test -json -verbose > /tmp/gke-mock.jsonl
python3 infra/gcp-demo-gke/tests/check_mock_plans.py /tmp/gke-mock.jsonl
for t in tests/*.sh; do bash "$t"; done
```
Legacy .github/workflows/test_demo_vm_app_env_file.sh also passes. Two other historical static
workflow tests fail identically on origin/main 0e88de0 (they look for login/registry code in the
old local script after it moved to the remote script). These baseline failures are not claimed
green or silently weakened. The three executable tests under tests/ remain passing unchanged.

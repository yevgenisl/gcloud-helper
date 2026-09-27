"""Offline contract tests: no credentials, cloud calls or installed providers needed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("lifecycle", Path(__file__).parents[1] / "lifecycle.py")
assert SPEC is not None and SPEC.loader is not None
lc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lc)
CONFIG = dict(app="ai", environment="demo", state_bucket="test-state-bucket", project="test-project", zone="us-central1-a", owner="alice", run="demo",
              billing_owner="team", admin_cidr="10.40.0.5/32", spot=False, public_endpoint=False)
POOL = dict(project="test-project", name="ai-demo-alice-demo", location="us-central1-a", node_count=1)


def plan(address="google_container_node_pool.demo", before=None, after=None, actions=None):
    return {"resource_changes": [{"address": address, "mode": "managed", "change": {
        "before": before, "after": after, "actions": actions or ["create"]}}]}


class Guards(unittest.TestCase):
    def test_valid_inputs(self):
        lc.validate(CONFIG)
        lc.validate(dict(CONFIG, spot=True))

    def test_public_inputs_and_strict_boolean(self):
        import argparse
        lc.validate(dict(CONFIG, public_endpoint=True, admin_cidr="8.8.8.8/32"))  # fixture only
        for value in ("false", 0, 1, None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                lc.validate(dict(CONFIG, public_endpoint=value))
        for value in ("", "True", "1", "yes", " false"):
            with self.assertRaises(argparse.ArgumentTypeError):
                lc.strict_bool(value)
        self.assertIs(lc.strict_bool("false"), False)
        self.assertIs(lc.strict_bool("true"), True)
        for cidr in ("0.0.0.0/0", "8.8.8.0/24", "8.8.8.8/24", "8.8.8.8", "10.1.2.3/32",
                     "172.16.0.1/32", "192.168.0.1/32", "127.0.0.1/32", "169.254.1.1/32",
                     "100.64.0.1/32", "192.0.0.9/32", "192.88.99.1/32", "192.0.2.1/32",
                     "198.18.0.1/32", "198.51.100.1/32", "203.0.113.1/32", "224.0.0.1/32",
                     "240.0.0.1/32", "255.255.255.255/32", "::1/128"):
            with self.subTest(cidr=cidr), self.assertRaises(ValueError):
                lc.validate(dict(CONFIG, public_endpoint=True, admin_cidr=cidr))

    def test_invalid_inputs(self):
        for key, value in [("project", "../oops"), ("owner", "ALL"), ("run", "../../x"),
                           ("run", "demo-"), ("owner", "alice-"),
                           ("zone", "us-central1"), ("billing_owner", ""), ("spot", "false"),
                           ("admin_cidr", "0.0.0.0/0"), ("admin_cidr", "8.8.8.8/32"),
                           ("admin_cidr", "10.0.0.0/8"), ("admin_cidr", "10.0.0.1/24"),
                           ("admin_cidr", "::1/128")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                lc.validate(dict(CONFIG, **{key: value}))

    def test_pause_and_resume(self):
        for action, before, after in [("pause", 1, 0), ("resume", 0, 1)]:
            lc.check_plan(plan(before=dict(POOL, node_count=before), after=dict(POOL, node_count=after),
                               actions=["update"]), CONFIG, action)

    def test_pause_rejects_non_pool_drift(self):
        before = dict(project="test-project", name="ai-demo-alice-demo")
        with self.assertRaises(ValueError):
            lc.check_plan(plan("google_compute_network.demo", before, before, ["update"]), CONFIG, "pause")

    def test_pause_rejects_pool_config_drift(self):
        with self.assertRaises(ValueError):
            lc.check_plan(plan(before=POOL, after=dict(POOL, node_count=0, version="new"),
                               actions=["update"]), CONFIG, "pause")

    def test_replacement_denied(self):
        for action in ("plan", "provision", "pause", "resume"):
            with self.subTest(action=action), self.assertRaises(ValueError):
                lc.check_plan(plan(before=POOL, after=POOL, actions=["delete", "create"]), CONFIG, action)

    def test_scoped_destroy(self):
        lc.check_plan(plan(before=POOL, actions=["delete"]), CONFIG, "destroy")

    def test_foreign_resource_denied_even_on_destroy(self):
        for key, value in [("project", "other-project"), ("name", "production"), ("location", "us-east1-b")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                lc.check_plan(plan(before=dict(POOL, **{key: value}), actions=["delete"]), CONFIG, "destroy")
        with self.assertRaises(ValueError):
            lc.check_plan(plan("google_compute_network.production", before=POOL, actions=["delete"]), CONFIG, "destroy")

    def test_unknown_scope_rejected(self):
        with self.assertRaises(ValueError):
            lc.check_plan(plan(after=dict(POOL, project=None)), CONFIG, "provision")

    def test_api_never_disabled(self):
        address = 'google_project_service.required["compute.googleapis.com"]'
        api = dict(project="test-project", service="compute.googleapis.com", disable_on_destroy=False)
        lc.check_plan(plan(address, before=api, actions=["delete"]), CONFIG, "destroy")
        with self.assertRaises(ValueError):
            lc.check_plan(plan(address, before=dict(api, disable_on_destroy=True), actions=["delete"]), CONFIG, "destroy")

    def test_iam_is_only_dedicated_member(self):
        values = dict(project="test-project", role="roles/container.defaultNodeServiceAccount",
                      member="serviceAccount:ai-demo-alice-demo@test-project.iam.gserviceaccount.com")
        lc.check_resource("google_project_iam_member.node", values, CONFIG)
        for key, value in [("role", "roles/editor"), ("member", "allUsers")]:
            with self.assertRaises(ValueError):
                lc.check_resource("google_project_iam_member.node", dict(values, **{key: value}), CONFIG)

    def test_state_rejects_child_modules_and_foreign_resources(self):
        for root in ({"child_modules": [{}]}, {"resources": [{"address": "unknown", "values": POOL}]}):
            with self.assertRaises(ValueError):
                lc.check_state({"values": {"root_module": root}}, CONFIG)


class Runner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root_patch = patch.object(lc, "ROOT", Path(self.temp.name))
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.env_patch = patch.dict(os.environ, {}, clear=True)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.calls = []
        self.plan = {"resource_changes": []}
        self.state = {"values": {"root_module": {"resources": []}}}
        self.proc_patch = patch.object(lc.subprocess, "run", side_effect=self.fake)
        self.proc_patch.start()
        self.addCleanup(self.proc_patch.stop)

    def fake(self, command, **kwargs):
        self.calls.append(command)
        if "version" in command:
            output = {"terraform_version": "1.12.3"}
        elif "init" in command:
            d = self.folder / ".terraform"
            d.mkdir(exist_ok=True)
            (d / "terraform.tfstate").write_text(json.dumps({"backend": {"type": "gcs", "config": {
                "bucket": CONFIG["state_bucket"], "prefix": lc.backend_prefix(CONFIG)}}}))
            output = {}
        elif "show" in command:
            output = self.plan if "review.tfplan" in command else self.state
        else:
            output = {}
        if "plan" in command:
            (self.folder / "review.tfplan").write_text("test fixture, not a real plan")
        return subprocess.CompletedProcess(command, 0, json.dumps(output))

    @property
    def folder(self):
        return lc.ROOT / lc.backend_prefix(CONFIG) / CONFIG["state_bucket"]

    def args(self, action, authorize=True):
        result = [action]
        for key, value in CONFIG.items():
            if key not in ("spot", "public_endpoint"):
                result += ["--" + key.replace("_", "-"), value]
        if authorize:
            result += ["--authorize", f"{action}:{lc.identity(CONFIG)}"]
        return result

    def seed(self):
        self.folder.mkdir(parents=True)
        (self.folder / "identity.json").write_text(json.dumps(CONFIG))
        self.state = {"values": {"root_module": {"resources": [{"address": "google_container_node_pool.demo", "values": POOL}]},
                                "outputs": {"deployment_config": {"value": CONFIG}}}}

    def test_mutations_require_authorization_before_any_command(self):
        for action in ("plan", "provision", "pause", "resume", "destroy"):
            with self.subTest(action=action), self.assertRaises(ValueError):
                lc.main(self.args(action, False))
        self.assertEqual(self.calls, [])

    def test_wrong_action_token_rejected(self):
        args = self.args("destroy", True)
        args[-1] = "provision:" + lc.identity(CONFIG)
        with self.assertRaises(ValueError):
            lc.main(args)
        self.assertEqual(self.calls, [])

    def test_environment_injection_rejected(self):
        for key in ("TF_CLI_ARGS", "TF_WORKSPACE", "TF_VAR_project", "TOFU_CLI_ARGS_apply"):
            with patch.dict(os.environ, {key: "evil"}), self.assertRaises(ValueError):
                lc.main(self.args("provision", True))
        self.assertEqual(self.calls, [])

    def test_plan_never_applies_and_removes_saved_plan(self):
        lc.main(self.args("plan"))
        self.assertFalse(any("apply" in c for c in self.calls))
        self.assertFalse((self.folder / "review.tfplan").exists())

    def test_provision_applies_only_checked_saved_plan(self):
        self.plan = plan(after=POOL)
        lc.main(self.args("provision", True))
        applies = [c for c in self.calls if "apply" in c]
        self.assertEqual(len(applies), 1)
        self.assertEqual(applies[0][-1], "review.tfplan")
        self.assertFalse((self.folder / "review.tfplan").exists())

    def test_guard_failure_cannot_apply(self):
        self.plan = plan(after=dict(POOL, name="production"))
        with self.assertRaises(ValueError):
            lc.main(self.args("provision", True))
        self.assertFalse(any("apply" in c for c in self.calls))
        self.assertFalse((self.folder / "review.tfplan").exists())

    def test_destroy_uses_only_isolated_state(self):
        self.seed()
        self.plan = plan(before=POOL, actions=["delete"])
        lc.main(self.args("destroy", True))
        command = next(c for c in self.calls if "plan" in c)
        self.assertIn("-destroy", command)
        self.assertIn(f"-chdir={self.folder}", command)
        self.assertFalse(any("-target" in arg for c in self.calls for arg in c))

    def test_missing_state_refuses_destroy(self):
        lc.main(self.args("plan"))
        self.calls.clear()
        with self.assertRaises(ValueError):
            lc.main(self.args("destroy", True))
        self.assertFalse(any("apply" in c for c in self.calls))

    def test_immutable_inputs(self):
        self.seed()
        args = self.args("provision", True)
        args[args.index("--admin-cidr") + 1] = "10.40.0.6/32"
        with self.assertRaises(ValueError):
            lc.main(args)
        self.assertEqual(self.calls, [])

    def test_local_endpoint_switch_and_old_manifest_fail_closed(self):
        self.seed()
        args = self.args("provision") + ["--public-endpoint", "true"]
        args[args.index("--admin-cidr") + 1] = "8.8.8.8/32"
        with self.assertRaisesRegex(ValueError, "immutable"):
            lc.main(args)
        legacy = dict(CONFIG)
        del legacy["public_endpoint"]
        (self.folder / "identity.json").write_text(json.dumps(legacy))
        with self.assertRaisesRegex(ValueError, "immutable"):
            lc.main(self.args("provision"))
        self.assertEqual(self.calls, [])

    def test_remote_endpoint_switch_or_missing_field_fail_closed(self):
        self.seed()
        for value in (True, None):
            remote = dict(CONFIG, public_endpoint=value)
            if value is None:
                del remote["public_endpoint"]
            self.state["values"]["outputs"]["deployment_config"]["value"] = remote
            with self.assertRaisesRegex(ValueError, "Remote run configuration"):
                lc.main(self.args("provision"))
        self.assertFalse(any("plan" in c or "apply" in c for c in self.calls))

    def test_default_private_and_explicit_public_inputs(self):
        lc.main(self.args("plan"))
        self.assertIs(json.loads((self.folder / "inputs.json").read_text())["public_endpoint"], False)
        (self.folder / "identity.json").unlink()
        args = self.args("plan") + ["--public-endpoint", "true"]
        args[args.index("--admin-cidr") + 1] = "8.8.8.8/32"
        lc.main(args)
        self.assertIs(json.loads((self.folder / "inputs.json").read_text())["public_endpoint"], True)

    def test_unexpected_files_refused(self):
        self.seed()
        (self.folder / "evil.auto.tfvars").write_text("project = bad")
        with self.assertRaises(ValueError):
            lc.main(self.args("destroy", True))
        self.assertEqual(self.calls, [])

    def test_pause_intent_is_preserved_by_later_plan(self):
        self.seed()
        self.plan = plan(before=POOL, after=dict(POOL, node_count=0), actions=["update"])
        lc.main(self.args("pause", True))
        self.state["values"]["root_module"]["resources"][0]["values"] = dict(POOL, node_count=0)
        self.plan = {"resource_changes": []}
        lc.main(self.args("plan"))
        self.assertTrue(json.loads((self.folder / "inputs.json").read_text())["paused"])

    def test_status_is_explicit_read_only_scope(self):
        self.seed()
        lc.main(self.args("status"))
        command = self.calls[-1]
        self.assertEqual(command[:5], ["gcloud", "container", "clusters", "describe", "ai-demo-alice-demo"])
        self.assertEqual(command[command.index("--project") + 1], CONFIG["project"])
        self.assertEqual(command[command.index("--zone") + 1], CONFIG["zone"])
        self.assertFalse(any("apply" in c for c in self.calls))


class RemoteBackend(Runner):
    def test_secret_free_module_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            module = Path(tmp)
            for filename in ("main.tf", "variables.tf", ".terraform.lock.hcl"):
                (module / filename).write_bytes((lc.MODULE / filename).read_bytes())
            for filename in (".env", "token.json", "terraform.tfstate", "evil.auto.tfvars"):
                (module / filename).write_text("SECRET_SENTINEL")
            with patch.object(lc, "MODULE", module):
                lc.main(self.args("plan"))
            for file in self.folder.iterdir():
                if file.is_file():
                    self.assertNotIn("SECRET_SENTINEL", file.read_text())

    def test_disposable_checkout_recovers_remote_pause(self):
        self.state = {"values": {"root_module": {"resources": [{"address": "google_container_node_pool.demo", "values": dict(POOL, node_count=0)}]},
                                "outputs": {"deployment_config": {"value": CONFIG}}}}
        lc.main(self.args("plan"))
        self.assertTrue(json.loads((self.folder / "inputs.json").read_text())["paused"])

    def test_backend_before_read_plan_and_apply(self):
        lc.main(self.args("provision"))
        init = next(c for c in self.calls if "init" in c)
        self.assertIn("-reconfigure", init)
        self.assertIn("-backend-config=backend.hcl", init)
        self.assertLess(self.calls.index(init), next(i for i,c in enumerate(self.calls) if "show" in c))
        self.assertIn(lc.backend_prefix(CONFIG), (self.folder / "backend.hcl").read_text())

    def test_remote_configuration_cannot_be_replaced(self):
        self.seed()
        self.state["values"]["outputs"]["deployment_config"]["value"] = dict(CONFIG, spot=True)
        with self.assertRaises(ValueError):
            lc.main(self.args("provision"))
        self.assertFalse(any("plan" in c or "apply" in c for c in self.calls))

    def test_backend_mismatch_rejected(self):
        original = self.fake
        def wrong(command, **kwargs):
            result = original(command, **kwargs)
            if "init" in command:
                (self.folder / ".terraform/terraform.tfstate").write_text(json.dumps({"backend": {"type": "local"}}))
            return result
        with patch.object(lc.subprocess, "run", side_effect=wrong), self.assertRaises(ValueError):
            lc.main(self.args("provision"))
        self.assertFalse(any("plan" in c for c in self.calls))

if __name__ == "__main__":
    unittest.main()

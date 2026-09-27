#!/usr/bin/env python3
"""Check real tofu test -json -verbose plans and prove guard regression bites."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("tests_lifecycle", Path(__file__).with_name("test_lifecycle.py"))
assert spec is not None and spec.loader is not None
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
count = 0
for line in Path(sys.argv[1]).read_text().splitlines():
    record = json.loads(line)
    if record.get("type") == "test_plan" and not record.get("@testrun", "").startswith("reject_"):
        config = dict(tests.CONFIG)
        if record["@testrun"] == "public_admin_private_workers":
            config.update(public_endpoint=True, admin_cidr="8.8.8.8/32")
        if record["@testrun"] == "spot":
            config["spot"] = True
        plan = record["test_plan"]
        tests.lc.check_plan(plan, config, "plan")
        assert plan["planned_values"]["outputs"]["deployment_config"]["value"] == config
        for field, value in (("enable_private_nodes", False), ("enable_private_endpoint", config["public_endpoint"])):
            bad = copy.deepcopy(plan)
            cluster = next(c for c in bad["resource_changes"] if c["address"] == "google_container_cluster.demo")
            cluster["change"]["after"]["private_cluster_config"][0][field] = value
            try:
                tests.lc.check_plan(bad, config, "plan")
            except ValueError:
                pass
            else:
                raise AssertionError("Actual mock plan endpoint scope mutation accepted")
        bad = copy.deepcopy(plan)
        cluster = next(c for c in bad["resource_changes"] if c["address"] == "google_container_cluster.demo")
        cluster["change"]["after"]["master_authorized_networks_config"][0]["cidr_blocks"][0]["cidr_block"] = "0.0.0.0/0"
        try:
            tests.lc.check_plan(bad, config, "plan")
        except ValueError:
            pass
        else:
            raise AssertionError("Actual mock plan broad admin range accepted")
        count += 1
assert count == 4, count
with patch.object(tests.lc, "check_resource", lambda *args: None):
    result = unittest.TestResult()
    tests.Guards("test_foreign_resource_denied_even_on_destroy").run(result)
    assert len(result.failures) == 4, result.failures
print(f"PASS: {count} real mock plans accepted; disabling guard triggers 4 failures")

#!/usr/bin/env python3
"""Check real tofu test -json -verbose plans and prove guard regression bites."""
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
    if record.get("type") == "test_plan" and record.get("@testrun") != "reject_open_admin":
        tests.lc.check_plan(record["test_plan"], tests.CONFIG, "plan")
        count += 1
assert count == 3, count
with patch.object(tests.lc, "check_resource", lambda *args: None):
    result = unittest.TestResult()
    tests.Guards("test_foreign_resource_denied_even_on_destroy").run(result)
    assert len(result.failures) == 4, result.failures
print(f"PASS: {count} real mock plans accepted; disabling guard triggers 4 failures")

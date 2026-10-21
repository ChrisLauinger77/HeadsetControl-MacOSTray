"""Renovate updates build-contract.json alone, so no test may depend on the currently pinned values."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SIMULATED_UPDATE = {
    "headsetcontrol": {"revision": "0123456789abcdef" * 2 + "01234567", "version": "99.98.97"},
    "hidapi": {"revision": "fedcba9876543210" * 2 + "fedcba98", "version": "0.99.0"},
}
# Repository files the script tests read; scripts run as subprocesses must see the updated contract too.
INPUTS = ("scripts", ".github/workflows", "HeadsetControl-MacOSTray.xcodeproj/project.pbxproj",
          "HeadsetControl-MacOSTray/HIDAPI-LICENSE.txt")


class ContractUpdateTests(unittest.TestCase):
    def test_script_tests_pass_after_simulated_dependency_update(self):
        contract = json.loads((ROOT / "build-contract.json").read_text())
        for name, values in SIMULATED_UPDATE.items():
            for field, value in values.items():
                self.assertNotEqual(contract[name][field], value, f"choose another simulated {name} {field}")
                contract[name][field] = value
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for item in INPUTS:
                source, target = ROOT / item, work / item
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__"))
                else:
                    shutil.copy2(source, target)
            (work / "build-contract.json").write_text(json.dumps(contract, indent=2) + "\n")
            (work / "scripts/tests" / Path(__file__).name).unlink()
            result = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "scripts/tests",
                                     "-p", "test_*.py"], cwd=work, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         "Tests depend on pinned build-contract.json values; derive them from the contract:\n"
                         + result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

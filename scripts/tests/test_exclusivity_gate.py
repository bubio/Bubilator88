import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_exclusivity import CORE_MODULES, check_arguments, check_swiftpm, check_xcode
from test_pinned_core import check_checkouts


class ExclusivityGateTests(unittest.TestCase):
    def test_checks_must_be_explicit_and_unambiguous(self):
        for arguments in ([], ["-enforce-exclusivity=none"],
                          ["-enforce-exclusivity=unchecked"],
                          ["-enforce-exclusivity=unchecked", "-enforce-exclusivity=checked"],
                          ["-enforce-exclusivity=checked", "-Ounchecked"]):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                check_arguments(arguments, "checked")
        check_arguments(["-enforce-exclusivity", "checked"], "checked")
        check_arguments(["-O", "-enforce-exclusivity=unchecked"], "unchecked")

    def test_swiftpm_missing_module_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "description.json"
            commands = {name: dict(moduleName=name, otherArguments=["-enforce-exclusivity=checked"])
                        for name in CORE_MODULES}
            path.write_text(json.dumps(dict(swiftCommands=commands)))
            self.assertEqual(set(check_swiftpm(path, "checked")), CORE_MODULES)
            commands.pop("Z80")
            path.write_text(json.dumps(dict(swiftCommands=commands)))
            with self.assertRaises(ValueError):
                check_swiftpm(path, "checked")

    def test_xcode_requires_every_module_and_rejects_partial_propagation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.log"
            lines = [f"builtin-SwiftDriver -- /tool/swiftc -module-name {name} -enforce-exclusivity=unchecked"
                     for name in sorted(CORE_MODULES | {"Bubilator88"})]
            path.write_text("\n".join(lines))
            self.assertEqual(len(check_xcode(path, "unchecked")), 7)
            path.write_text("\n".join(lines[:-1]))
            with self.assertRaises(ValueError):
                check_xcode(path, "unchecked")
            path.write_text("\n".join(lines).replace("-module-name Z80 -enforce-exclusivity=unchecked",
                                                   "-module-name Z80 -enforce-exclusivity=checked"))
            with self.assertRaises(ValueError):
                check_xcode(path, "unchecked")

    def test_checkout_revision_must_match_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Bubilator88Core").mkdir()
            with patch("test_pinned_core.revision", return_value="actual"):
                check_checkouts(root, {"bubilator88core": "actual"})
                with self.assertRaises(ValueError):
                    check_checkouts(root, {"bubilator88core": "other"})
                with self.assertRaises(ValueError):
                    check_checkouts(root, {"swift-log": "actual"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise the release cask updater without publishing or changing the real cask."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("update-cask.py").resolve()
SOURCE = (SCRIPT.parent.parent / "Casks/winmouse.rb").read_text()


class CaskUpdateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Casks").mkdir()
        self.cask = self.root / "Casks/winmouse.rb"
        self.cask.write_text(SOURCE)

    def run_update(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.root,
                              text=True, capture_output=True)

    def test_payload_pins_version_and_checksum_without_writing(self):
        result = self.run_update("99.0.0", "a" * 64, "--github-sha", "b" * 40)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        content = base64.b64decode(payload["content"]).decode()
        self.assertIn('  version "99.0.0"', content)
        self.assertIn('  sha256 "' + "a" * 64 + '"', content)
        self.assertEqual(payload["sha"], "b" * 40)
        self.assertEqual(payload["branch"], "main")
        self.assertNotIn("author", payload)
        self.assertEqual(self.cask.read_text(), SOURCE)

    def test_local_update(self):
        result = self.run_update("99.0.0", "a" * 64)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('  version "99.0.0"', self.cask.read_text())

    def test_rejects_invalid_inputs_and_downgrades_without_writing(self):
        for version, checksum in [("0.0.0", "a" * 64), ("99.0.0-beta.1", "a" * 64),
                                  ("99.0.0", "no_check"), ("99.0.0\nother", "a" * 64)]:
            with self.subTest(version=version):
                self.assertNotEqual(self.run_update(version, checksum).returncode, 0)
                self.assertEqual(self.cask.read_text(), SOURCE)

    def test_rejects_ambiguous_cask(self):
        self.cask.write_text(SOURCE + '\n  sha256 "' + "b" * 64 + '"\n')
        self.assertNotEqual(self.run_update("99.0.0", "a" * 64).returncode, 0)


if __name__ == "__main__":
    unittest.main()

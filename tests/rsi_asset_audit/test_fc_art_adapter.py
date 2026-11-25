"""fc-art adapter (tools/rsi_adapters/fc_art.py): applies only to a pack with aw_weapon_art.gd.
Run: python3 -m unittest discover tests/rsi_asset_audit"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from rsi_adapters import fc_art  # noqa: E402

ART = '\t&"pistol": {"model": "pistol", "reload": {"style": "pistol"}, "mag_node": "mag"},\n'


class FcArtAdapter(unittest.TestCase):
    def test_pack_without_art_table_is_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "addons", "zee_gs_weapons"))
            src = {"root": root, "addon": "addons/zee_gs_weapons"}
            self.assertIsNone(fc_art.context(src))
            rec = {"kind": "weapon", "animations": [], "flags": []}
            fc_art.check(src, rec, os.path.join(root, "pistol.glb"), None, None)
            self.assertEqual(rec, {"kind": "weapon", "animations": [], "flags": []})

    def test_missing_addon_dir_is_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(fc_art.context({"root": root, "addon": "addons/nope"}))

    def test_pack_with_art_table_reads_rows(self):
        with tempfile.TemporaryDirectory() as root:
            addon = os.path.join(root, "addons", "fc_weapons")
            os.makedirs(addon)
            with open(os.path.join(addon, "aw_weapon_art.gd"), "w", encoding="utf-8") as f:
                f.write("const ART := {\n" + ART + "}\n")
            ctx = fc_art.context({"root": root, "addon": "addons/fc_weapons"})
            self.assertEqual(ctx["rows"]["pistol"], {"style": "pistol", "mag_node": "mag"})


if __name__ == "__main__":
    unittest.main()

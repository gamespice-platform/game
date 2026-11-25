"""TEXTURE_QUALITY (tools/rsi_asset_audit.py texture_blotch / uv_cover / tex_flags): blotched albedos flag, crisp ones pass.
Run: python3 -m unittest discover tests/rsi_asset_audit   (needs numpy and PIL)"""
import io
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import rsi_asset_audit as A  # noqa: E402

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402


def png(lum):
    buf = io.BytesIO()
    Image.fromarray((np.clip(lum, 0, 1) * 255).astype(np.uint8)).save(buf, "PNG")
    return buf.getvalue()


def blotchy(n=1024, seed=1):
    """Voronoi patches of random grey (the Polyy AI paint): flat cells, soft-edged, at random angles."""
    rng = np.random.default_rng(seed)
    pts = rng.random((400, 2)) * n
    vals = rng.random(400)
    yy, xx = np.mgrid[0:n:4, 0:n:4].astype(np.float32)
    d = (xx[..., None] - pts[:, 0]) ** 2 + (yy[..., None] - pts[:, 1]) ** 2
    cells = vals[d.argmin(-1)]
    im = Image.fromarray((cells * 255).astype(np.uint8)).resize((n, n), Image.BILINEAR)
    return 0.25 + 0.35 * np.asarray(im, np.float32) / 255


def crisp(n=1024, seed=2):
    """Machined panels: one tone, straight panel lines on the UV axes, fine grain and small scratches."""
    rng = np.random.default_rng(seed)
    a = np.full((n, n), 0.3, np.float32)
    a[::128, :] = 0.12
    a[:, ::96] = 0.12
    a += (rng.random((n, n)).astype(np.float32) - 0.5) * 0.08
    return a


def tex(blotch):
    return {"name": "base", "w": 1024, "h": 1024, "format": "png", "bytes": 1, "maps": ["albedo"], "embedded": True,
            "pot": True, "luma_std": 40.0, "quality": {"blotch": blotch, "mf": 30.0, "ratio": 0.2, "axis": 0.3}}


def flags(textures, budget=None):
    out = []
    A.tex_flags({"textures": textures, "model": {}}, budget or {}, "high", lambda c, s, m: out.append((c, s, m)))
    return out


def glb_one_triangle():
    """A glTF with one textured triangle covering the left-bottom half of UV space (u + v <= 1 flipped)."""
    uv = struct.pack("<6f", 0, 0, 1, 0, 0, 1)
    idx = struct.pack("<3H", 0, 1, 2) + b"\0\0"
    gltf = {"buffers": [{"byteLength": 32}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 24}, {"buffer": 0, "byteOffset": 24, "byteLength": 6}],
            "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC2"},
                          {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
            "images": [{"bufferView": 0}], "textures": [{"source": 0}],
            "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
            "meshes": [{"primitives": [{"attributes": {"TEXCOORD_0": 0}, "indices": 1, "material": 0}]}]}
    return gltf, uv + idx


class TextureBlotch(unittest.TestCase):
    def test_blotchy_flags_crisp_and_flat_pass(self):
        lim = A.THRESHOLDS["tex_blotch"]
        b = A.texture_blotch(png(blotchy()))
        c = A.texture_blotch(png(crisp()))
        f = A.texture_blotch(png(np.full((256, 256), 0.4, np.float32)))
        self.assertGreater(b["blotch"], lim, b)
        self.assertLess(c["blotch"], lim / 3, c)
        self.assertGreater(c["axis"], 0.5, c)
        self.assertEqual(f["blotch"], 0.0, f)

    def test_unreadable_image_is_none(self):
        self.assertIsNone(A.texture_blotch(b"not an image"))

    def test_uv_cover_rasterises_the_mapped_triangle(self):
        gltf, binc = glb_one_triangle()
        m = A.uv_cover(gltf, binc, 0, n=64)
        self.assertIsNotNone(m)
        self.assertAlmostEqual(float(m.mean()), 0.5, delta=0.05)
        self.assertTrue(m[2, 2] and not m[60, 60])
        self.assertIsNone(A.uv_cover(gltf, binc, 1, n=64))   # no material samples image 1

    def test_cover_skips_the_padding(self):
        # blotches only outside the mapped triangle: the padding does not count
        a = crisp(256)
        pad = blotchy(256)
        tri = np.tri(256, dtype=bool)[::-1, :]   # u + v <= 1 (row = v)
        a = np.where(tri, a, pad)
        gltf, binc = glb_one_triangle()
        whole = A.texture_blotch(png(a), n=256)
        masked = A.texture_blotch(png(a), n=256, cover=A.uv_cover(gltf, binc, 0, n=256))
        self.assertLess(masked["blotch"], whole["blotch"])
        self.assertAlmostEqual(masked["cover"], 0.5, delta=0.05)


class TextureQualityFlag(unittest.TestCase):
    def test_flag_carries_the_measured_value(self):
        out = flags([tex(19.9)])
        tq = [f for f in out if f[0] == "TEXTURE_QUALITY"]
        self.assertEqual(len(tq), 1)
        self.assertEqual(tq[0][1], "warn")
        self.assertIn("base 19.9", tq[0][2])

    def test_clean_texture_passes(self):
        self.assertFalse([f for f in flags([tex(4.7)]) if f[0] == "TEXTURE_QUALITY"])
        self.assertFalse([f for f in flags([dict(tex(0), quality=None)]) if f[0] == "TEXTURE_QUALITY"])

    def test_budget_override(self):
        self.assertFalse([f for f in flags([tex(19.9)], {"max_tex_blotch": 25}) if f[0] == "TEXTURE_QUALITY"])


if __name__ == "__main__":
    unittest.main()

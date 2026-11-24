#!/usr/bin/env python3
"""RSI asset audit: measure every model of every configured source (packs and games).

Nothing about which sources exist or what a kind is allowed is built in. Both come from a
rsi-config/1 JSON file (`nightly assets config`, or the file Nightly writes for `nightly assets refresh`):

  {"schema": "rsi-config/1", "tiers": ["low", "medium", "high"],
   "sources": [{"name", "type", "root", "models": [glob], "exclude": [dir], "defaultKind", "kindRules": [{"match", "kind"}], ...}],
   "kinds": [{"key", "match", "budget": {min_tris, max_tris, min_tex: {low, medium, high}, require_skin, required_clips, ...}}]}

Reads GLBs directly (no Godot): triangles, vertices, materials, bounding box, skins and bones, LOD levels, textures (size,
power of two, maps, import compression, flat albedo), animation clips. Each model is judged against the budget of its kind at
one texture-quality tier. Writes audit.json (schema rsi-assets/2, docs/rsi-asset-audit.md) with an `assets` array, plus a
self-contained viewer copy of each GLB. A source config may name an adapter (`"adapter": "fc-art"`, tools/rsi_adapters/)
for checks that need game code; none is required.

  tools/rsi_asset_audit.py --config rsi-config.json [--out DIR] [--source NAME ...] [--tier high] [--no-glb]
"""
import argparse
import base64
import datetime
import fnmatch
import importlib
import io
import json
import math
import os
import re
import struct
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Measurement constants (how a model is read), not budgets; budgets come from the config.
THRESHOLDS = {"faceted_vpt": 1.6, "flat_albedo_std": 16.0, "primitive_tris": 64, "mag_epsilon": 0.01,
              "uncompressed_bytes": 1 << 20}
SEVERITY_COST = {"error": 20, "warn": 7, "info": 2}
DEFAULT_MODELS = ["**/*.glb", "**/*.gltf"]

GL_TRIANGLES = 4


# ---------------------------------------------------------------- GLB reading
def read_gltf_text(path, data):
    """A text .gltf: the JSON plus its first buffer (external .bin or a base64 data: URI), the pair read_glb returns."""
    gltf = json.loads(data.decode("utf-8"))
    binc = b""
    bufs = gltf.get("buffers") or []
    uri = bufs[0].get("uri") if bufs else None
    if uri and uri.startswith("data:"):
        binc = base64.b64decode(uri.split(",", 1)[1])
    elif uri:
        with open(os.path.join(os.path.dirname(path), urllib.parse.unquote(uri)), "rb") as f:
            binc = f.read()
    return gltf, binc


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"glTF" and data.lstrip()[:1] == b"{":
        return read_gltf_text(path, data)
    magic, _ver, _len = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError("not a GLB")
    off, gltf, binc = 12, None, b""
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return gltf, binc


COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def accessor_values(gltf, binc, idx):
    acc = gltf["accessors"][idx]
    if "bufferView" not in acc:
        return []
    bv = gltf["bufferViews"][acc["bufferView"]]
    fmt, size = COMP[acc["componentType"]]
    n = NCOMP[acc["type"]]
    stride = bv.get("byteStride") or size * n
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    for i in range(acc["count"]):
        vals = struct.unpack_from("<" + fmt * n, binc, base + i * stride)
        out.append(vals if n > 1 else vals[0])
    return out


def mat_mul(a, b):
    return [sum(a[r + 4 * k] * b[k + 4 * c] for k in range(4)) for c in range(4) for r in range(4)]


def node_matrix(node):
    if "matrix" in node:
        return list(node["matrix"])
    t = node.get("translation", [0, 0, 0])
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    s = node.get("scale", [1, 1, 1])
    r = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
         2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
         2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)]
    return [r[0] * s[0], r[1] * s[0], r[2] * s[0], 0, r[3] * s[1], r[4] * s[1], r[5] * s[1], 0,
            r[6] * s[2], r[7] * s[2], r[8] * s[2], 0, t[0], t[1], t[2], 1]


def mesh_stats(gltf, binc):
    """Tris/verts per mesh instance in the default scene, world-space bbox."""
    meshes = gltf.get("meshes", [])
    per_mesh = []
    for m in meshes:
        tris = verts = 0
        mn, mx = [math.inf] * 3, [-math.inf] * 3
        for p in m.get("primitives", []):
            mode = p.get("mode", GL_TRIANGLES)
            pos = p["attributes"].get("POSITION")
            vcount = gltf["accessors"][pos]["count"] if pos is not None else 0
            icount = gltf["accessors"][p["indices"]]["count"] if "indices" in p else vcount
            if mode == GL_TRIANGLES:
                tris += icount // 3
            elif mode in (5, 6):
                tris += max(0, icount - 2)
            verts += vcount
            if pos is not None:
                acc = gltf["accessors"][pos]
                if "min" in acc and "max" in acc:
                    mn = [min(a, b) for a, b in zip(mn, acc["min"])]
                    mx = [max(a, b) for a, b in zip(mx, acc["max"])]
        per_mesh.append({"name": m.get("name", ""), "tris": tris, "verts": verts, "min": mn, "max": mx})
    nodes = gltf.get("nodes", [])
    scene = gltf.get("scenes", [{}])[gltf.get("scene", 0)] if gltf.get("scenes") else {"nodes": list(range(len(nodes)))}
    inst = []
    wmn, wmx = [math.inf] * 3, [-math.inf] * 3

    def walk(ni, parent):
        node = nodes[ni]
        m = mat_mul(parent, node_matrix(node))
        if "mesh" in node:
            pm = per_mesh[node["mesh"]]
            inst.append((node.get("name") or pm["name"], pm))
            if pm["min"][0] != math.inf:
                for cx in (pm["min"][0], pm["max"][0]):
                    for cy in (pm["min"][1], pm["max"][1]):
                        for cz in (pm["min"][2], pm["max"][2]):
                            p = [m[0] * cx + m[4] * cy + m[8] * cz + m[12],
                                 m[1] * cx + m[5] * cy + m[9] * cz + m[13],
                                 m[2] * cx + m[6] * cy + m[10] * cz + m[14]]
                            for k in range(3):
                                wmn[k] = min(wmn[k], p[k])
                                wmx[k] = max(wmx[k], p[k])
        for c in node.get("children", []):
            walk(c, m)

    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    for ni in scene.get("nodes", []):
        walk(ni, ident)
    bbox = [round(wmx[k] - wmn[k], 4) if wmx[k] > wmn[k] else 0.0 for k in range(3)]
    return inst, bbox, (wmn, wmx)


def image_info(raw):
    """(format, w, h) from PNG/JPEG/WebP bytes."""
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", raw[16:24])
        return "png", w, h
    if raw[:2] == b"\xff\xd8":
        i = 2
        while i < len(raw) - 9:
            if raw[i] != 0xFF:
                i += 1
                continue
            marker = raw[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", raw[i + 5:i + 9])
                return "jpg", w, h
            seg = struct.unpack(">H", raw[i + 2:i + 4])[0]
            i += 2 + seg
        return "jpg", 0, 0
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        kind = raw[12:16]
        if kind == b"VP8X":
            w = 1 + int.from_bytes(raw[24:27], "little")
            h = 1 + int.from_bytes(raw[27:30], "little")
        elif kind == b"VP8L":
            b = int.from_bytes(raw[21:25], "little")
            w, h = (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
        else:
            w, h = struct.unpack("<HH", raw[26:30])
            w, h = w & 0x3FFF, h & 0x3FFF
        return "webp", w, h
    return "unknown", 0, 0


def luminance_std(raw):
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        im = Image.open(io.BytesIO(raw)).convert("L")
        im.thumbnail((256, 256))
        hist = im.histogram()
    except Exception:
        return None
    n = sum(hist)
    mean = sum(i * c for i, c in enumerate(hist)) / n
    return round(math.sqrt(sum(c * (i - mean) ** 2 for i, c in enumerate(hist)) / n), 1)


def import_mode(path):
    """Godot texture import compression (lossless|lossy|vram|basis|uncompressed) and the lossy quality (0..1, None)."""
    imp = path + ".import"
    if not os.path.exists(imp):
        return "", None
    text = open(imp, encoding="utf-8", errors="replace").read()
    m = re.search(r"^compress/mode=(\d)", text, re.M)
    mode = {"0": "lossless", "1": "lossy", "2": "vram", "3": "vram_uncompressed", "4": "basis"}.get(m.group(1), "") if m else ""
    q = re.search(r"^compress/lossy_quality=([0-9.]+)", text, re.M)
    return mode, (float(q.group(1)) if q and mode == "lossy" else None)


def textures(gltf, binc, glb_dir, glb_base=""):
    images = gltf.get("images", [])
    texs = gltf.get("textures", [])
    maps = {}

    def use(tinfo, kind):
        if not tinfo:
            return
        t = texs[tinfo["index"]]
        src = t.get("source")
        if src is None:
            for ext in t.get("extensions", {}).values():
                src = ext.get("source", src)
        if src is not None:
            maps.setdefault(src, set()).add(kind)

    for m in gltf.get("materials", []):
        pbr = m.get("pbrMetallicRoughness", {})
        use(pbr.get("baseColorTexture"), "albedo")
        use(pbr.get("metallicRoughnessTexture"), "orm")
        use(m.get("normalTexture"), "normal")
        use(m.get("occlusionTexture"), "ao")
        use(m.get("emissiveTexture"), "emissive")
    out = []
    for i, img in enumerate(images):
        embedded = "bufferView" in img
        raw, ipath = b"", ""
        if embedded:
            bv = gltf["bufferViews"][img["bufferView"]]
            raw = binc[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
            # Godot extracts embedded images as <glb>_<image name>.<ext> (<glb>_<index> when unnamed) and imports those.
            stems = ["%s_%s" % (glb_base, img["name"])] if img.get("name") else []
            for stem in stems + ["%s_%d" % (glb_base, i)]:
                for ext in (".jpg", ".png", ".webp"):
                    cand = os.path.join(glb_dir, stem + ext)
                    if glb_base and not ipath and os.path.exists(cand):
                        ipath = cand
        elif "uri" in img and not img["uri"].startswith("data:"):
            ipath = os.path.join(glb_dir, img["uri"])
            if os.path.exists(ipath):
                raw = open(ipath, "rb").read()
        fmt, w, h = image_info(raw) if raw else ("missing", 0, 0)
        rec = {"name": img.get("name") or os.path.splitext(img.get("uri", "image_%d" % i))[0],
               "w": w, "h": h, "format": fmt, "bytes": len(raw),
               "maps": sorted(maps.get(i, [])), "embedded": embedded,
               "pot": w > 0 and h > 0 and (w & (w - 1)) == 0 and (h & (h - 1)) == 0}
        if ipath:
            rec["import"], q = import_mode(ipath)
            if q is not None:
                rec["lossy_quality"] = q
        if "albedo" in rec["maps"] and raw:
            rec["luma_std"] = luminance_std(raw)
        out.append(rec)
    if not out and glb_base:   # external images named <glb stem>_*.png beside a glb that carries none (launcher_rocket_diffuse.png)
        for f in sorted(os.listdir(glb_dir)):
            if not f.lower().endswith((".png", ".jpg", ".jpeg", ".webp")) or not f.startswith(glb_base + "_"):
                continue
            raw = open(os.path.join(glb_dir, f), "rb").read()
            fmt, w, h = image_info(raw)
            low = f.lower()
            maps = ["normal"] if "normal" in low else ["roughness"] if "rough" in low else ["metallic"] if "metal" in low else ["orm"] if "orm" in low else ["emissive"] if "emis" in low else ["ao"] if "_ao" in low else ["albedo"]
            rec = {"name": os.path.splitext(f)[0], "w": w, "h": h, "format": fmt, "bytes": len(raw), "maps": maps, "embedded": False,
                   "pot": w > 0 and h > 0 and (w & (w - 1)) == 0 and (h & (h - 1)) == 0}
            rec["import"], q = import_mode(os.path.join(glb_dir, f))
            if q is not None:
                rec["lossy_quality"] = q
            if "albedo" in maps:
                rec["luma_std"] = luminance_std(raw)
            out.append(rec)
    return out


def flat_colour(gltf):
    """True when no material references a texture and the colour comes from material factors or vertex colours (a palette model by design)."""
    mats = gltf.get("materials", [])
    for m in mats:
        pbr = m.get("pbrMetallicRoughness", {})
        if pbr.get("baseColorTexture") or pbr.get("metallicRoughnessTexture") or m.get("normalTexture") or m.get("emissiveTexture") or m.get("occlusionTexture"):
            return False
    vc = any("COLOR_0" in p.get("attributes", {}) for me in gltf.get("meshes", []) for p in me.get("primitives", []))
    return bool(mats) or vc


def animations(gltf, binc):
    nodes = gltf.get("nodes", [])
    out = []
    for a in gltf.get("animations", []):
        length, mag_disp, moving = 0.0, None, False
        for ch in a.get("channels", []):
            s = a["samplers"][ch["sampler"]]
            acc = gltf["accessors"][s["input"]]
            if "max" in acc:
                length = max(length, acc["max"][0])
            tgt = ch.get("target", {})
            vals = accessor_values(gltf, binc, s["output"]) if tgt.get("path") in ("translation", "rotation") else []
            if vals and any(max(abs(v[k] - vals[0][k]) for k in range(len(vals[0]))) > 1e-4 for v in vals):
                moving = True
            name = nodes[tgt["node"]].get("name", "").lower() if "node" in tgt and tgt["node"] < len(nodes) else ""
            if "mag" in name and tgt.get("path") == "translation" and vals:
                d = max(math.dist(v, vals[0]) for v in vals)
                mag_disp = max(mag_disp or 0.0, d)
        flags = []
        if not a.get("channels"):
            flags.append("no_tracks")
        elif not moving:
            flags.append("static")
        if mag_disp is not None:
            flags.append("mag_moves" if mag_disp >= THRESHOLDS["mag_epsilon"] else "mag_static")
        out.append({"name": a.get("name", ""), "length": round(length, 3), "tracks": len(a.get("channels", [])),
                    "flags": flags, "mag_displacement": None if mag_disp is None else round(mag_disp, 4)})
    return out


def embed_textures(glb_path, dst):
    """Write a self-contained GLB: external image URIs moved into the BIN chunk."""
    gltf, binc = read_glb(glb_path)
    binc = bytearray(binc)
    d = os.path.dirname(glb_path)
    for img in gltf.get("images", []):
        uri = img.get("uri")
        if not uri or uri.startswith("data:"):
            continue
        p = os.path.join(d, uri)
        if not os.path.exists(p):
            continue
        raw = open(p, "rb").read()
        while len(binc) % 4:
            binc.append(0)
        gltf.setdefault("bufferViews", []).append({"buffer": 0, "byteOffset": len(binc), "byteLength": len(raw)})
        binc.extend(raw)
        del img["uri"]
        img["bufferView"] = len(gltf["bufferViews"]) - 1
        img["mimeType"] = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"}.get(image_info(raw)[0], "image/png")
    while len(binc) % 4:
        binc.append(0)
    if gltf.get("buffers"):
        gltf["buffers"][0] = {"byteLength": len(binc)}
    elif binc:
        gltf["buffers"] = [{"byteLength": len(binc)}]
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    total = 12 + 8 + len(js) + (8 + len(binc) if binc else 0)
    tmp = dst + ".tmp"
    with open(tmp, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        if binc:
            f.write(struct.pack("<II", len(binc), 0x004E4942) + bytes(binc))
    os.replace(tmp, dst)


# ---------------------------------------------------------------- pack tables

def git(repo, *args):
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""


# ---------------------------------------------------------------- config
def glob_re(g):
    """Same glob syntax as Nightly (lib/assets-sources.mjs): ** any depth, * within one directory, ? one character."""
    s, i = "", 0
    while i < len(g):
        c = g[i]
        if c == "*" and g[i + 1:i + 2] == "*":
            if g[i + 2:i + 3] == "/":
                s += "(?:.*/)?"
                i += 3
            else:
                s += ".*"
                i += 2
            continue
        s += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return re.compile("^" + s + "$", re.I)


def load_config(path):
    cfg = json.load(open(path, encoding="utf-8"))
    if cfg.get("schema") != "rsi-config/1":
        sys.exit("%s: not an rsi-config/1 file (run `nightly assets config > rsi-config.json`)" % path)
    if not cfg.get("sources"):
        sys.exit("%s: no sources (add one with `nightly assets source add`)" % path)
    return cfg


def classify(rel, source, kinds):
    for rule in source.get("kindRules") or []:
        if re.search(rule["match"], rel, re.I):
            return rule["kind"]
    for k in sorted(kinds, key=lambda k: (k.get("sort", 0), k["key"])):
        if k.get("match") and re.search(k["match"], rel, re.I):
            return k["key"]
    return source.get("defaultKind") or "other"


def walk_models(source):
    """[(relative path, absolute path)] of the models a source's globs select, excluding any path with an excluded component."""
    root = source["root"]
    pats = [glob_re(g) for g in source.get("models") or DEFAULT_MODELS]
    skip = set(source.get("exclude") or [])
    out = []
    for dp, dn, fs in os.walk(root):
        dn[:] = sorted(d for d in dn if d not in skip)
        for f in sorted(fs):
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if any(p.match(rel) for p in pats):
                out.append((rel, full))
    return out


# ---------------------------------------------------------------- facts and checks
def rig_facts(gltf):
    skins = gltf.get("skins", [])
    levels = set()
    for n in gltf.get("nodes", []):
        g = re.search(r"(?:^|[_\s.-])lod[_\s.-]?(\d+)$", n.get("name", ""), re.I)
        if g:
            levels.add(int(g.group(1)))
        ids = (n.get("extensions") or {}).get("MSFT_lod", {}).get("ids")
        if ids:
            levels.add(len(ids))
    return {"skins": len(skins), "bones": sum(len(s.get("joints", [])) for s in skins), "lods": len(levels)}


def kind_flags(rec, B, tier):
    """Mirror of kindFlags in Nightly lib/assets-checks.mjs: same codes, severities and budget keys."""
    F = []

    def add(code, sev, msg):
        F.append({"code": code, "severity": sev, "msg": msg})

    m = rec["model"]
    if not m["glb"]:
        add("NO_MODEL", "error", "no model file")
        return F
    t = m["tris"]
    if B.get("min_tris") is not None and t < B["min_tris"]:
        add("VERY_LOW_TRIS" if t < B["min_tris"] / 3 else "LOW_TRIS", "error", "%d tris < %d" % (t, B["min_tris"]))
    if B.get("max_tris") is not None and t > B["max_tris"]:
        add("HIGH_TRIS", "warn", "%d tris > %d" % (t, B["max_tris"]))
    if B.get("min_materials") is not None and m["materials"] < B["min_materials"]:
        add("FEW_MATERIALS", "warn", "%d materials < %d" % (m["materials"], B["min_materials"]))
    tex_flags(rec, B, tier, add)
    rig_flags(rec, B, add)
    longest = max(m["bbox"])
    if B.get("min_size") is not None and 0 < longest < B["min_size"]:
        add("SCALE_SMALL", "warn", "largest edge %s m < %s m: wrong scale?" % (longest, B["min_size"]))
    if B.get("max_size") is not None and longest > B["max_size"]:
        add("SCALE_LARGE", "warn", "largest edge %s m > %s m: wrong scale?" % (longest, B["max_size"]))
    bd = m.get("bounds")
    if B.get("max_pivot_offset") is not None and bd and longest > 0:
        cx, cz = (bd["min"][0] + bd["max"][0]) / 2, (bd["min"][2] + bd["max"][2]) / 2
        off, base = math.hypot(cx, cz) / longest, abs(bd["min"][1]) / longest
        if max(off, base) > B["max_pivot_offset"]:
            add("PIVOT_OFF", "warn", "pivot is %d%% of the size away from the base centre" % round(max(off, base) * 100))
    if B.get("require_lods") and m["lods"] < (B.get("min_lods") or 2):
        add("NO_LODS", "warn", "%d LOD levels < %d" % (m["lods"], B.get("min_lods") or 2))
    return F


def tex_flags(rec, B, tier, add):
    tx = rec["textures"]
    need = (B.get("min_tex") or {}).get(tier)
    gone = [t["name"] for t in tx if t["format"] == "missing"]
    if gone:   # the model names an image file that is not on disk: a broken link, not a flat-colour design
        add("TEX_FILE_MISSING", "error", "%d image file(s) referenced by the model are missing: %s" % (len(gone), ", ".join(gone[:4])))
    if not tx:
        if need is not None or B.get("require_normal") or B.get("require_orm"):
            if rec["model"].get("flat_colour"):   # palette model by design, not a gap
                add("FLAT_COLOUR", "info", "flat-colour materials by design (no texture referenced)")
            else:
                add("NO_TEXTURES", "error", "no textures: the model should carry images and has none")
        return
    big = max(max(t["w"], t["h"]) for t in tx)
    if need is not None and big < need:
        add("LOW_TEX", "error", "largest texture %dpx < %dpx (tier %s)" % (big, need, tier))
    if B.get("max_tex") is not None and big > B["max_tex"]:
        add("HUGE_TEX", "warn", "largest texture %dpx > %dpx" % (big, B["max_tex"]))
    if any(t["w"] and not t["pot"] for t in tx):
        add("NPOT_TEX", "warn", ", ".join("%s %dx%d" % (t["name"], t["w"], t["h"]) for t in tx if t["w"] and not t["pot"]))
    if B.get("require_normal") and not any("normal" in t["maps"] for t in tx):
        add("MISSING_NORMAL", "warn", "no normal map")
    if B.get("require_orm") and not any(set(t["maps"]) & {"orm", "roughness", "metallic", "ao"} for t in tx):
        add("MISSING_ORM", "warn", "no roughness/metallic map")
    alb = [t for t in tx if "albedo" in t["maps"]] or tx
    flat = [t for t in alb if t.get("luma_std") is not None and t["luma_std"] < THRESHOLDS["flat_albedo_std"]]
    if flat and len(flat) == len(alb):
        add("FLAT_TEX", "warn", "albedo nearly uniform (luma std %s)" % ", ".join(str(t["luma_std"]) for t in flat))


def rig_flags(rec, B, add):
    m = rec["model"]
    clips = [a["name"].lower() for a in rec["animations"]]
    if B.get("require_skin") and not m["skins"] > 0:
        add("NO_SKIN", "error", "no skin: a rigged model is expected")
    if m["bones"] > 0:
        if B.get("min_bones") is not None and m["bones"] < B["min_bones"]:
            add("FEW_BONES", "warn", "%d bones < %d" % (m["bones"], B["min_bones"]))
        if B.get("max_bones") is not None and m["bones"] > B["max_bones"]:
            add("MANY_BONES", "warn", "%d bones > %d" % (m["bones"], B["max_bones"]))
    missing = [c for c in B.get("required_clips") or [] if not any(c.lower() in n for n in clips)]
    if missing:
        if clips:
            add("MISSING_ANIM_SET", "warn", "missing clips: " + ", ".join(missing))
        else:
            add("MISSING_ANIM_SET", "error", "no animation clips (needs %s): T-pose" % ", ".join(missing))
    elif not clips and m["skins"] > 0:
        add("NO_ANIM_CLIPS", "info", "the model carries no animation clips")
    for a in rec["animations"]:
        if "static" in a["flags"]:
            add("STATIC_CLIP", "warn", "clip %s never moves" % a["name"])


# ---------------------------------------------------------------- audit
def load_adapter(source):
    name = source.get("adapter")
    if not name:
        return None
    return importlib.import_module("rsi_adapters." + name.replace("-", "_"))


def audit_model(source, kinds, rel, glb, adapter, ctx, tier, out_dir, export, now, head):
    kind = classify(rel, source, kinds)
    B = next((k["budget"] for k in kinds if k["key"] == kind), {}) or {}
    wid = os.path.splitext(rel)[0].replace("/", "__")
    rec = {"pack": source["name"], "game": source.get("games", ""), "weapon_id": wid, "kind": kind, "source_commit": head,
           "last_changed": "", "model": {"glb": rel, "viewer_glb": "", "tris": 0, "verts": 0, "materials": 0, "meshes": 0,
                                          "bbox": [0, 0, 0], "primitive_meshes": [], "skins": 0, "bones": 0, "lods": 0},
           "textures": [], "animations": [], "sounds": [], "flags": [], "audited_at": now}
    stem = os.path.splitext(rel)[0]
    rec["last_changed"] = git(source["root"], "log", "-1", "--format=%cs", "--", rel, stem + "_*", stem + ".*")
    gltf, binc = read_glb(glb)
    inst, bbox, (wmn, wmx) = mesh_stats(gltf, binc)
    tris = sum(pm["tris"] for _n, pm in inst)
    rec["model"].update(tris=tris, verts=sum(pm["verts"] for _n, pm in inst), materials=len(gltf.get("materials", [])),
                        meshes=len(inst), bbox=bbox, **rig_facts(gltf),
                        primitive_meshes=sorted({n for n, pm in inst if 0 < pm["tris"] <= THRESHOLDS["primitive_tris"]}))
    if wmn[0] != math.inf:
        rec["model"]["bounds"] = {"min": [round(v, 4) for v in wmn], "max": [round(v, 4) for v in wmx]}
    rec["model"]["flat_colour"] = flat_colour(gltf)
    rec["textures"] = textures(gltf, binc, os.path.dirname(glb), os.path.splitext(os.path.basename(glb))[0])
    rec["animations"] = animations(gltf, binc)
    flags = rec["flags"]
    flags.extend(kind_flags(rec, B, tier))
    vpt = rec["model"]["verts"] / tris if tris else 0
    if vpt >= THRESHOLDS["faceted_vpt"]:
        flags.append({"code": "FACETED", "severity": "warn", "msg": "flat-shaded: %.2f verts per tri" % vpt})
    prims = rec["model"]["primitive_meshes"]
    if prims and len(prims) * 2 >= max(1, len(inst)):
        flags.append({"code": "PRIMITIVE_MESH", "severity": "warn", "msg": "%d of %d meshes are box/cylinder sized" % (len(prims), len(inst))})
    if adapter:
        adapter.check(source, rec, glb, ctx, sys.modules[__name__])
    if export:
        name = "%s__%s.glb" % (source["name"], wid)
        try:
            embed_textures(glb, os.path.join(out_dir, "glb", name))
            rec["model"]["viewer_glb"] = "glb/" + name
        except Exception as e:  # keep auditing; the viewer just lacks this one
            print("export %s: %s" % (name, e), file=sys.stderr)
    return finish(rec)


def finish(rec):
    score = 100 - sum(SEVERITY_COST[f["severity"]] for f in rec["flags"])
    rec["score"] = max(0, score)
    rec["pass"] = rec["score"] >= 70 and not any(f["severity"] == "error" for f in rec["flags"])
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True, help="rsi-config/1 JSON (nightly assets config)")
    ap.add_argument("--out", default=os.environ.get("NIGHTLY_ASSETS_DIR") or "rsi-assets", help="output dir for audit.json and glb/")
    ap.add_argument("--source", action="append", help="only this source (default: all in the config)")
    ap.add_argument("--no-glb", action="store_true", help="skip viewer GLB export")
    ap.add_argument("--tier", default="high", help="video texture-quality tier to judge textures against (a name from the config's tiers)")
    a = ap.parse_args()
    cfg = load_config(a.config)
    tiers = cfg.get("tiers") or ["low", "medium", "high"]
    if a.tier not in tiers:
        sys.exit("unknown --tier %s (config has %s)" % (a.tier, ", ".join(tiers)))
    kinds = cfg.get("kinds") or []
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    os.makedirs(os.path.join(a.out, "glb"), exist_ok=True)
    assets = []
    for source in cfg["sources"]:
        if a.source and source["name"] not in a.source:
            continue
        if not os.path.isdir(source["root"]):
            print("skip %s: no directory %s" % (source["name"], source["root"]), file=sys.stderr)
            continue
        head = git(source["root"], "rev-parse", "--short", "HEAD")
        adapter = load_adapter(source)
        ctx = adapter.context(source) if adapter else None
        for rel, glb in walk_models(source):
            try:
                assets.append(audit_model(source, kinds, rel, glb, adapter, ctx, a.tier, a.out, not a.no_glb, now, head))
            except Exception as e:
                assets.append(finish({"pack": source["name"], "game": source.get("games", ""), "weapon_id": os.path.splitext(rel)[0].replace("/", "__"),
                                      "kind": classify(rel, source, kinds), "source_commit": head, "last_changed": "", "model": {"glb": rel},
                                      "textures": [], "animations": [], "sounds": [], "audited_at": now,
                                      "flags": [{"code": "NO_MODEL", "severity": "error", "msg": "unreadable: %s" % e}]}))
    if not a.no_glb and not a.source:   # full run: drop viewer GLBs of assets no longer audited
        keep = {os.path.basename(w["model"].get("viewer_glb", "")) for w in assets}
        for f in os.listdir(os.path.join(a.out, "glb")):
            if f.endswith(".glb") and f not in keep:
                os.remove(os.path.join(a.out, "glb", f))
    by = {}
    for w in assets:
        b = by.setdefault(w["pack"], {"assets": 0, "pass": 0, "score_sum": 0})
        b["assets"] += 1
        b["pass"] += int(w["pass"])
        b["score_sum"] += w["score"]
    for b in by.values():
        b["avg_score"] = round(b.pop("score_sum") / b["assets"]) if b["assets"] else 0
    by_kind = {}
    for w in assets:
        by_kind[w["kind"]] = by_kind.get(w["kind"], 0) + 1
    doc = {"schema": "rsi-assets/2", "generated_at": now, "thresholds": {"tier": a.tier, "tiers": tiers, **THRESHOLDS},
           "summary": {"assets": len(assets), "pass": sum(w["pass"] for w in assets), "fail": sum(not w["pass"] for w in assets),
                       "by_pack": by, "by_kind": by_kind},
           "assets": assets}
    dst = os.path.join(a.out, "audit.json" if a.tier == "high" else "audit-%s.json" % a.tier)
    with open(dst + ".tmp", "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(dst + ".tmp", dst)
    s = doc["summary"]
    print("rsi-asset-audit [tier %s]: %d assets, %d pass, %d fail -> %s" % (a.tier, s["assets"], s["pass"], s["fail"], dst))
    for name, b in sorted(by.items()):
        print("  %-22s %4d assets %4d pass avg score %d" % (name, b["assets"], b["pass"], b["avg_score"]))


if __name__ == "__main__":
    main()

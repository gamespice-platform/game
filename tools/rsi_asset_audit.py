#!/usr/bin/env python3
"""RSI asset audit: measure every weapon model in every GameSpice weapon pack.

Reads GLBs directly (no Godot needed): triangle and vertex counts, materials,
bounding box, primitive-looking meshes, textures (size, power of two, maps used,
Godot import compression, near-flat albedo), animation clips and how far the
magazine node travels in them. For fc-weapons it also reads the art table, whose
reloads are procedural, to catch a reload style that never moves a magazine the
model visibly has, and reload props that are primitive meshes.

Writes audit.json in the rsi-assets/1 schema (docs/rsi-asset-audit.md) and a
self-contained copy of each weapon GLB (external textures embedded) for the
Nightly Assets viewer.

  tools/rsi_asset_audit.py [--root ~gamedev/godot] [--out /home/gamedev/perf-bench/rsi-assets]
                           [--pack fc-weapons ...] [--no-glb]
"""
import argparse
import datetime
import io
import json
import math
import os
import re
import struct
import subprocess
import sys

THRESHOLDS = {
    "min_tris": 3000,          # below: LOW_TRIS (a first-person gun fills a third of the screen)
    "very_low_tris": 1000,     # below: VERY_LOW_TRIS
    "min_tris_melee": 800,     # knives, axes, bats: simpler shapes
    "min_tris_throwable": 800, # grenades
    "min_tex": 2048,           # largest albedo edge below: LOW_TEX (guns; a view model is ~1000px wide)
    "min_tex_small": 1024,     # melee and throwables
    "faceted_vpt": 1.6,        # verts per tri at or above: FACETED (flat-shaded, every tri its own verts)
    "max_tex": 4096,           # any edge above: OVERSIZED_TEX
    "min_materials": 2,
    "flat_albedo_std": 16.0,   # albedo luminance std-dev below: FLAT_TEX (painted-flat or blotchy bake)
    "primitive_tris": 64,      # a mesh this small reads as a box/cylinder
    "primitive_ammo_tris": 200,  # reload prop (round/clip) below this: PRIMITIVE_AMMO
    "mag_epsilon": 0.01,       # metres the magazine must travel in a reload clip
    "uncompressed_bytes": 1 << 20,
}
# Texture targets per video texture-quality tier (dot-menu `texture_quality` 0..3 = low..ultra). The shipped texture must
# meet the tier the run judges (--tier); lower tiers are served from it by downscale/mip skip, never by a second asset.
# Override with --tiers-json FILE ({"high": {"min_tex": 2048, ...}}); 0 for min_lossy_quality means any lossy import passes.
TIERS = {
    "low": {"min_tex": 512, "min_tex_small": 256, "min_lossy_quality": 0.6},
    "medium": {"min_tex": 1024, "min_tex_small": 512, "min_lossy_quality": 0.75},
    "high": {"min_tex": 2048, "min_tex_small": 1024, "min_lossy_quality": 0.85},
    "ultra": {"min_tex": 4096, "min_tex_small": 2048, "min_lossy_quality": 1.01},  # 1.01: lossless only
}
SEVERITY_COST = {"error": 20, "warn": 7, "info": 2}
REQUIRED_CLIPS = {"fire": "error", "reload": "error", "draw": "error",
                  "reload_empty": "warn", "inspect": "warn", "holster": "warn"}
# id tokens (split on _ and -) that mark the weapon class; "battle_rifle" is not a bat
MELEE_RE = re.compile(r"(^|[_\-])(knife|axe|bat|crowbar|machete|sledge|longsword|sword|mace|dagger|spear|"
                      r"shield|hammer|pickaxe|shovel|bow)($|[_\-A-Z])")
THROW_RE = re.compile(r"(^|[_\-])(frag|sticky|flash|smoke|incendiary|grenade)($|[_\-A-Z])")

# Every pack: where its weapon models live and which games ship it.
PACKS = {
    "fc-weapons": {"games": "fatal-contact,zombie-zone,playlot",
                   "addon": "addons/fc_weapons", "art": "fc"},
    "zee-dot-weapons": {"games": "zombie-zone,playlot", "addon": "addons/zee_weapons",
                        "dirs": ["assets/low-poly-guns", "assets/blaster-kit", "assets/melee"],
                        "include": r"^(blaster-[a-r]|[a-z_]+(?<!_mag))\.glb$",
                        "exclude": r"(magazine|_mag$|^ext_mag|foregrip|laser|red_dot|scope|suppressor)"},
    "zed-dot-weapons": {"games": "zombie-zone", "addon": "addons/zed_weapons",
                        "dirs": ["assets/hq", "assets/weapon-pack"],
                        "exclude": r"(magazine|^ammo_|_mag$|foregrip|laser|red_dot|scope|suppressor)"},
    "zz-modern-weapons": {"games": "zombie-zone,playlot", "addon": "addons/zz_modern_weapons",
                          "dirs": ["addons/zz_modern_weapons/assets"], "exclude": r"(_mag$|magazine)"},
    "zz-medieval-weapons": {"games": "zombie-zone,playlot", "addon": "addons/zz_medieval_weapons",
                            "dirs": ["assets"], "exclude": r"^(arrow|bolt)$"},
}

GL_TRIANGLES = 4


# ---------------------------------------------------------------- GLB reading
def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
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
    return inst, bbox


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
    return out


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


def fc_rows(repo, addon):
    """fc-weapons art table: weapon id -> model, reload style, mag node; MAG_BOXES; reload props."""
    art = open(os.path.join(repo, addon, "aw_weapon_art.gd"), encoding="utf-8").read()
    rows = {}
    for m in re.finditer(r'^\t&"(\w+)": \{"model": "(\w+)"(.*)$', art, re.M):
        rest = m.group(3)
        style = re.search(r'"reload": \{"style": "(\w+)"', rest)
        mag = re.search(r'"mag_node": "(\w+)"', rest)
        part = re.search(r'"part": "(\w+)"', rest)
        rows[m.group(1)] = {"model": m.group(2), "style": style.group(1) if style else "",
                            "mag_node": mag.group(1) if mag else "", "part": part.group(1) if part else ""}
    core = os.path.join(repo, addon, "view", "aw_view_model_core.gd")
    boxes = set()
    if os.path.exists(core):
        src = open(core, encoding="utf-8").read()
        mb = re.search(r"MAG_BOXES[^{]*\{(.*?)^\}", src, re.S | re.M)
        if mb:
            boxes = {k[:-4] for k in re.findall(r'"([\w\-]+\.glb)"', mb.group(1))}
    return rows, boxes


# reload styles that hand-feed rounds (props) rather than swap a magazine
ROUND_STYLES = {"bolt": "round_sniper", "tube": "round_shell", "revolver": "round_pistol", "launcher": ""}
MAG_STYLES = {"magazine", "pistol", "cell", "belt"}


def weapon_list(repo, name, cfg):
    """[(weapon_id, glb_path, extra)]"""
    out = []
    if cfg.get("art") == "fc":
        rows, boxes = fc_rows(repo, cfg["addon"])
        mdir = os.path.join(repo, cfg["addon"], "assets", "models")
        for wid, row in rows.items():
            row["mag_box"] = row["model"] in boxes
            out.append((wid, os.path.join(mdir, row["model"] + ".glb"), row))
        return out
    seen = set()
    for d in cfg["dirs"]:
        full = os.path.join(repo, d)
        if not os.path.isdir(full):
            continue
        for f in sorted(os.listdir(full)):
            if not f.endswith(".glb"):
                continue
            stem = f[:-4]
            if cfg.get("include") and not re.match(cfg["include"], f):
                continue
            if cfg.get("exclude") and re.search(cfg["exclude"], stem):
                continue
            if stem in seen:      # first dir wins (hq before kit)
                continue
            seen.add(stem)
            mag = None
            for cand in (stem + "_mag.glb", stem + "_magazine.glb"):
                if os.path.exists(os.path.join(full, cand)):
                    mag = cand
            out.append((stem, os.path.join(full, f), {"mag_file": mag}))
    return out


def clip_support(repo, addon):
    """Which clip names the pack's code animates procedurally (FC has no GLB clips)."""
    found = set()
    for dp, _dn, fs in os.walk(os.path.join(repo, addon)):
        for f in fs:
            if f.endswith(".gd"):
                src = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
                for clip in REQUIRED_CLIPS:
                    if re.search(r'(func _?%s\b|&"%s"|"%s")' % (clip, clip, clip), src):
                        found.add(clip)
    return found


# ---------------------------------------------------------------- audit
def audit_weapon(repo, pack, cfg, wid, glb, extra, procedural, out_dir, export, now, head):
    rec = {"pack": pack, "game": cfg["games"], "weapon_id": wid, "source_commit": head,
           "last_changed": "", "model": {"glb": "", "viewer_glb": "", "tris": 0, "verts": 0, "materials": 0,
                                          "meshes": 0, "bbox": [0, 0, 0], "primitive_meshes": []},
           "textures": [], "animations": [], "sounds": [], "flags": [], "audited_at": now}
    flags = rec["flags"]

    def flag(code, sev, msg):
        flags.append({"code": code, "severity": sev, "msg": msg})

    if not os.path.exists(glb):
        flag("NO_MODEL", "error", "no model file %s" % os.path.relpath(glb, repo))
        return finish(rec)
    rel = os.path.relpath(glb, repo)
    rec["model"]["glb"] = rel
    stem = os.path.splitext(rel)[0]
    rec["last_changed"] = git(repo, "log", "-1", "--format=%cs", "--", rel, stem + "_*", stem + ".*")
    gltf, binc = read_glb(glb)
    inst, bbox = mesh_stats(gltf, binc)
    tris = sum(pm["tris"] for _n, pm in inst)
    rec["model"].update(tris=tris, verts=sum(pm["verts"] for _n, pm in inst),
                        materials=len(gltf.get("materials", [])), meshes=len(inst), bbox=bbox,
                        primitive_meshes=sorted({n for n, pm in inst if 0 < pm["tris"] <= THRESHOLDS["primitive_tris"]}))
    melee = bool(MELEE_RE.search(wid))
    throw = bool(THROW_RE.search(wid)) and "launcher" not in wid.lower()
    rec["kind"] = "melee" if melee else "throwable" if throw else "gun"
    lo = THRESHOLDS["min_tris_melee"] if melee else THRESHOLDS["min_tris_throwable"] if throw else THRESHOLDS["min_tris"]
    if tris < (THRESHOLDS["very_low_tris"] if rec["kind"] == "gun" else lo / 2):
        flag("VERY_LOW_TRIS", "error", "%d tris" % tris)
    elif tris < lo:
        flag("LOW_TRIS", "error", "%d tris < %d" % (tris, lo))
    vpt = rec["model"]["verts"] / tris if tris else 0
    if vpt >= THRESHOLDS["faceted_vpt"]:
        flag("FACETED", "warn", "flat-shaded: %.2f verts per tri" % vpt)
    if rec["model"]["materials"] < THRESHOLDS["min_materials"]:
        flag("FEW_MATERIALS", "warn", "%d material(s)" % rec["model"]["materials"])
    prims = rec["model"]["primitive_meshes"]
    if prims and len(prims) * 2 >= max(1, len(inst)):
        flag("PRIMITIVE_MESH", "warn", "%d of %d meshes are box/cylinder sized" % (len(prims), len(inst)))

    rec["textures"] = textures(gltf, binc, os.path.dirname(glb), os.path.splitext(os.path.basename(glb))[0])
    tx = rec["textures"]
    if not tx:
        flag("NO_TEXTURES", "error", "flat-colour materials only")
    else:
        alb = [t for t in tx if "albedo" in t["maps"]] or tx
        edge = max(max(t["w"], t["h"]) for t in alb)
        min_tex = THRESHOLDS["min_tex"] if rec["kind"] == "gun" else THRESHOLDS["min_tex_small"]
        if edge < min_tex:
            flag("LOW_TEX", "error", "largest albedo %dpx < %d" % (edge, min_tex))
        if any(not t["pot"] and t["w"] for t in tx):
            flag("NPOT_TEX", "warn", ", ".join("%s %dx%d" % (t["name"], t["w"], t["h"]) for t in tx if not t["pot"] and t["w"]))
        if any(max(t["w"], t["h"]) > THRESHOLDS["max_tex"] for t in tx):
            flag("OVERSIZED_TEX", "warn", "texture over %dpx" % THRESHOLDS["max_tex"])
        lossy = [t for t in tx if t.get("lossy_quality") is not None and t["lossy_quality"] < THRESHOLDS["min_lossy_quality"]]
        if lossy:
            flag("LOSSY_TEX", "warn", "lossy import below q%.2f for tier %s: %s" % (THRESHOLDS["min_lossy_quality"], THRESHOLDS["tier"],
                 ", ".join("%s q%.2f" % (t["name"], t["lossy_quality"]) for t in lossy[:4])))
        if any(t.get("import") == "lossless" and t["bytes"] > THRESHOLDS["uncompressed_bytes"] for t in tx):
            flag("UNCOMPRESSED_TEX", "info", "lossless import over 1 MiB")
        if not any("normal" in t["maps"] for t in tx):
            flag("MISSING_NORMAL", "warn", "no normal map")
        if not any("orm" in t["maps"] or "ao" in t["maps"] for t in tx):
            flag("MISSING_ORM", "warn", "no roughness/metal/AO map")
        flat = [t for t in alb if t.get("luma_std") is not None and t["luma_std"] < THRESHOLDS["flat_albedo_std"]]
        if flat and len(flat) == len(alb):
            flag("FLAT_TEX", "warn", "albedo nearly uniform (luma std %s)" % ", ".join(str(t["luma_std"]) for t in flat))

    rec["animations"] = animations(gltf, binc)
    have = {a["name"].lower() for a in rec["animations"]}
    for a in rec["animations"]:
        if "static" in a["flags"]:
            flag("STATIC_CLIP", "warn", "clip %s never moves" % a["name"])
        if a["name"].lower().startswith("reload") and "mag_static" in a["flags"]:
            flag("MAG_STATIC_RELOAD", "error", "%s: magazine moves %.3fm" % (a["name"], a["mag_displacement"]))
    for clip, sev in REQUIRED_CLIPS.items():
        if clip in have:
            continue
        if clip in procedural:
            rec["animations"].append({"name": clip, "length": None, "tracks": 0, "flags": ["procedural"],
                                      "mag_displacement": None})
        elif rec["kind"] == "gun" or clip in ("draw", "holster", "inspect"):
            flag("MISSING_CLIP_" + clip.upper(), sev, "no %s clip (GLB or procedural)" % clip)

    if cfg.get("art") == "fc":
        style = extra.get("style", "")
        has_mag = extra.get("mag_box") or extra.get("mag_node")
        if style and style not in MAG_STYLES and has_mag:
            flag("MAG_STATIC_RELOAD", "error",
                 "model has a box magazine but reload style '%s' never removes it" % style)
        prop = ROUND_STYLES.get(style)
        if prop:
            pp = os.path.join(os.path.dirname(glb), prop + ".glb")
            if os.path.exists(pp):
                pinst, _ = mesh_stats(*read_glb(pp))
                pt = sum(pm["tris"] for _n, pm in pinst)
                if pt < THRESHOLDS["primitive_ammo_tris"]:
                    flag("PRIMITIVE_AMMO", "error", "reload prop %s is %d tris" % (prop, pt))
        rec["reload_style"] = style
    elif extra.get("mag_file") is None and rec["kind"] == "gun" and "reload" not in have:
        flag("NO_MAG_NODE", "warn", "no separate magazine model for the reload")

    if export:
        name = "%s__%s.glb" % (pack, wid)
        try:
            embed_textures(glb, os.path.join(out_dir, "glb", name))
            rec["model"]["viewer_glb"] = "glb/" + name
        except Exception as e:  # keep auditing; viewer just lacks this one
            print("export %s: %s" % (name, e), file=sys.stderr)
    return finish(rec)


def finish(rec):
    score = 100 - sum(SEVERITY_COST[f["severity"]] for f in rec["flags"])
    rec["score"] = max(0, score)
    rec["pass"] = rec["score"] >= 70 and not any(f["severity"] == "error" for f in rec["flags"])
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default="/home/gamedev/godot")
    ap.add_argument("--out", default="/home/gamedev/perf-bench/rsi-assets")
    ap.add_argument("--pack", action="append", help="repo dir under --root (default: all); NAME=PATH for a worktree")
    ap.add_argument("--no-glb", action="store_true", help="skip viewer GLB export")
    ap.add_argument("--tier", default="high", help="video texture-quality tier to judge textures against: " + "|".join(TIERS))
    ap.add_argument("--tiers-json", help="JSON file overriding TIERS rows")
    a = ap.parse_args()
    if a.tiers_json:
        for k, row in json.load(open(a.tiers_json)).items():
            TIERS.setdefault(k, {}).update(row)
    if a.tier not in TIERS:
        sys.exit("unknown --tier %s (have %s)" % (a.tier, ", ".join(TIERS)))
    THRESHOLDS.update(TIERS[a.tier], tier=a.tier)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    os.makedirs(os.path.join(a.out, "glb"), exist_ok=True)
    picks = a.pack or list(PACKS)
    weapons = []
    for p in picks:
        name, _, path = p.partition("=")
        cfg = PACKS[name]
        repo = path or os.path.join(a.root, name)
        if not os.path.isdir(repo):
            print("skip %s: no repo at %s" % (name, repo), file=sys.stderr)
            continue
        head = git(repo, "rev-parse", "--short", "HEAD")
        procedural = clip_support(repo, cfg["addon"])
        for wid, glb, extra in weapon_list(repo, name, cfg):
            try:
                weapons.append(audit_weapon(repo, name, cfg, wid, glb, extra, procedural, a.out,
                                            not a.no_glb, now, head))
            except Exception as e:
                rec = finish({"pack": name, "game": cfg["games"], "weapon_id": wid, "source_commit": head,
                              "last_changed": "", "model": {"glb": os.path.relpath(glb, repo)},
                              "textures": [], "animations": [], "sounds": [], "audited_at": now,
                              "flags": [{"code": "NO_MODEL", "severity": "error", "msg": "unreadable: %s" % e}]})
                weapons.append(rec)
    if not a.no_glb and not a.pack:   # full run: drop viewer GLBs of weapons no longer audited
        keep = {os.path.basename(w["model"].get("viewer_glb", "")) for w in weapons}
        for f in os.listdir(os.path.join(a.out, "glb")):
            if f.endswith(".glb") and f not in keep:
                os.remove(os.path.join(a.out, "glb", f))
    by_pack = {}
    for w in weapons:
        b = by_pack.setdefault(w["pack"], {"weapons": 0, "pass": 0, "score_sum": 0})
        b["weapons"] += 1
        b["pass"] += int(w["pass"])
        b["score_sum"] += w["score"]
    for b in by_pack.values():
        b["avg_score"] = round(b.pop("score_sum") / b["weapons"]) if b["weapons"] else 0
    doc = {"schema": "rsi-assets/1", "generated_at": now, "thresholds": THRESHOLDS,
           "summary": {"weapons": len(weapons), "pass": sum(w["pass"] for w in weapons),
                       "fail": sum(not w["pass"] for w in weapons), "by_pack": by_pack},
           "weapons": weapons}
    dst = os.path.join(a.out, "audit.json" if a.tier == "high" else "audit-%s.json" % a.tier)
    with open(dst + ".tmp", "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(dst + ".tmp", dst)
    s = doc["summary"]
    print("rsi-asset-audit [tier %s]: %d weapons, %d pass, %d fail -> %s" % (a.tier, s["weapons"], s["pass"], s["fail"], dst))
    for name, b in sorted(by_pack.items()):
        print("  %-22s %3d weapons %3d pass avg score %d" % (name, b["weapons"], b["pass"], b["avg_score"]))


if __name__ == "__main__":
    main()

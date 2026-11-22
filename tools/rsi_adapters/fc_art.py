"""Adapter "fc-art": checks that need a pack's weapon art table (procedural reloads have no GLB clips).

Source config: {"adapter": "fc-art", "addon": "<dir under the source root>"}. The addon holds aw_weapon_art.gd and
view/aw_view_model_core.gd; models are matched by file stem against the art table's "model" names. Without an art row the
model is skipped, so this adapter only adds checks and never changes what is listed.
"""
import os
import re

ROUND_STYLES = {"bolt": "round_sniper", "tube": "round_shell", "revolver": "round_pistol", "launcher": ""}
MAG_STYLES = {"magazine", "pistol", "cell", "belt"}
CLIPS = ("fire", "reload", "draw", "reload_empty", "inspect", "holster")


def context(source):
    addon = os.path.join(source["root"], source.get("addon", ""))
    art = open(os.path.join(addon, "aw_weapon_art.gd"), encoding="utf-8").read()
    rows = {}
    for m in re.finditer(r'^\t&"(\w+)": \{"model": "(\w+)"(.*)$', art, re.M):
        style = re.search(r'"reload": \{"style": "(\w+)"', m.group(3))
        mag = re.search(r'"mag_node": "(\w+)"', m.group(3))
        rows[m.group(2)] = {"style": style.group(1) if style else "", "mag_node": mag.group(1) if mag else ""}
    core = os.path.join(addon, "view", "aw_view_model_core.gd")
    boxes = set()
    if os.path.exists(core):
        mb = re.search(r"MAG_BOXES[^{]*\{(.*?)^\}", open(core, encoding="utf-8").read(), re.S | re.M)
        if mb:
            boxes = {k[:-4] for k in re.findall(r'"([\w\-]+\.glb)"', mb.group(1))}
    procedural = set()
    for dp, _dn, fs in os.walk(addon):
        for f in fs:
            if f.endswith(".gd"):
                src = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
                procedural |= {c for c in CLIPS if re.search(r'(func _?%s\b|&"%s"|"%s")' % (c, c, c), src)}
    return {"rows": rows, "boxes": boxes, "procedural": procedural}


def check(source, rec, glb, ctx, audit):
    stem = os.path.splitext(os.path.basename(glb))[0]
    row = ctx["rows"].get(stem)
    if row is None:
        return
    flags = rec["flags"]
    style = row["style"]
    if style and style not in MAG_STYLES and (stem in ctx["boxes"] or row["mag_node"]):
        flags.append({"code": "MAG_STATIC_RELOAD", "severity": "error", "msg": "model has a box magazine but reload style '%s' never removes it" % style})
    prop = ROUND_STYLES.get(style)
    if prop:
        pp = os.path.join(os.path.dirname(glb), prop + ".glb")
        if os.path.exists(pp):
            pinst, _b, _bd = audit.mesh_stats(*audit.read_glb(pp))
            pt = sum(pm["tris"] for _n, pm in pinst)
            if pt < 200:
                flags.append({"code": "PRIMITIVE_AMMO", "severity": "error", "msg": "reload prop %s is %d tris" % (prop, pt)})
    have = {a["name"].lower() for a in rec["animations"]}
    for clip in ctx["procedural"] - have:
        rec["animations"].append({"name": clip, "length": None, "tracks": 0, "flags": ["procedural"], "mag_displacement": None})
    rec["reload_style"] = style

extends Node

## The visual QA harness's pure parts: the --only/--clips plan, the verdict, the T-pose distance, the outside cameras' placement and layer tagging.
## The rendered capture itself runs on a GPU box (docs/visual-qa.md).

const CHECKS := 16

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("dot-game: visual qa")
	_plan()
	_verdict()
	_rest_distance()
	_views()
	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _plan() -> void:
	var by_item := {"rifle": PackedStringArray(["idle", "fire"]), "pistol": PackedStringArray(["fire", "reload"])}
	var all := GSGameVisualQaCapture.plan(by_item, PackedStringArray(), PackedStringArray())
	_check(all.size() == 4, "plan: no filter keeps every pair, got %d" % all.size())
	_check(all[0] == PackedStringArray(["rifle", "idle"]), "plan: pairs keep item then clip order, got %s" % str(all[0]))
	var fire := GSGameVisualQaCapture.plan(by_item, PackedStringArray(), PackedStringArray(["fire"]))
	_check(fire.size() == 2, "plan: --clips fire picks it from both items, got %d" % fire.size())
	var one := GSGameVisualQaCapture.plan(by_item, PackedStringArray(["pistol"]), PackedStringArray(["fire"]))
	_check(one.size() == 1 and one[0] == PackedStringArray(["pistol", "fire"]), "plan: --only and --clips combine, got %s" % str(one))
	var none := GSGameVisualQaCapture.plan(by_item, PackedStringArray(["knife"]), PackedStringArray())
	_check(none.is_empty(), "plan: an unknown --only item plans nothing")


func _verdict() -> void:
	var rows: Array[Dictionary] = [
		{"check": "slide", "pass": true, "value": "0.1", "limit": "0.25", "note": ""},
		{"check": "floor", "pass": false, "value": "0.12", "limit": "0.05", "note": "sinks"},
		{"check": "tpose", "pass": false, "skip": true, "value": "-", "limit": "-", "note": "no skeleton"},
	]
	var v := GSGameVisualQaCapture.verdict(rows)
	_check(not v["pass"], "verdict: a failing row fails the clip")
	_check((v["fail"] as Array).size() == 1 and str(v["fail"][0]).begins_with("floor 0.12 (limit 0.05) sinks"), "verdict: the reason names check, value, limit and note, got %s" % str(v["fail"]))
	_check(not (v["worst"] as Dictionary).has("tpose"), "verdict: a skipped row neither fails nor shows")
	var ok_rows: Array[Dictionary] = [{"check": "slide", "pass": true, "value": "0", "limit": "0.25"}]
	_check(GSGameVisualQaCapture.verdict(ok_rows)["pass"], "verdict: all rows passing passes")


func _rest_distance() -> void:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("hips")
	skeleton.add_bone("spine")
	skeleton.set_bone_rest(1, Transform3D(Basis(Vector3.RIGHT, deg_to_rad(10.0)), Vector3.UP))
	var rest: Array = [Quaternion.IDENTITY, Basis(Vector3.RIGHT, deg_to_rad(10.0)).get_rotation_quaternion()]
	_check(GSGameVisualQaCapture.rest_distance_deg(skeleton, rest) < 0.01, "rest distance: the rest pose is 0 degrees away")
	var bent: Array = [Quaternion.IDENTITY, Basis(Vector3.RIGHT, deg_to_rad(40.0)).get_rotation_quaternion()]
	var d := GSGameVisualQaCapture.rest_distance_deg(skeleton, bent)
	_check(absf(d - 30.0) < 0.01, "rest distance: the worst bone is 30 degrees off rest, got %f" % d)
	skeleton.free()


func _views() -> void:
	var views := GSGameVisualQaViews.new()
	views.place(Vector3.ZERO, 0.0)
	_check(views.behind_camera == null, "views: place before setup is a no-op")
	views.setup(self, get_viewport().world_3d)
	views.place(Vector3(10.0, 0.0, 0.0), PI)
	_check(views.behind_camera.global_position.is_equal_approx(Vector3(8.6, 1.5, -2.0)), "views: behind-right turns with the subject, got %s" % str(views.behind_camera.global_position))
	_check(views.opponent_camera.global_position.is_equal_approx(Vector3(9.6, 1.6, 4.0)), "views: the opponent stands in front, got %s" % str(views.opponent_camera.global_position))
	var facing := -views.opponent_camera.global_basis.z
	_check(facing.dot(Vector3(10.0, 1.3, 0.0) - views.opponent_camera.global_position) > 0.0, "views: the opponent looks at the subject")
	var body := Node3D.new()
	var mesh := MeshInstance3D.new()
	var arms := Node3D.new()
	var arm_mesh := MeshInstance3D.new()
	body.add_child(mesh)
	body.add_child(arms)
	arms.add_child(arm_mesh)
	var tagged := GSGameVisualQaViews.tag_layers(body, 1 << 18, arms)
	_check(tagged == 1 and mesh.layers == 1 << 18 and arm_mesh.layers == 1, "views: tag_layers tags the body and skips the subtree, tagged %d" % tagged)
	body.free()

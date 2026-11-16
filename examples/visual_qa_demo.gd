extends DotGameVisualQaCapture

## The smallest DotGameVisualQaCapture: a capsule "avatar" that turns in place and walks a circle on the default stage.
## Renders, so it runs on a GPU box or xvfb, never in the headless suites (docs/visual-qa.md):
##   bash addons/dot_game/tools/dot_game_visual_qa_shot.sh --script examples/visual_qa_demo.gd -- --out /tmp/vq-demo

var _body: Node3D = null


func _items() -> PackedStringArray:
	return PackedStringArray(["capsule"])


func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray(["turn", "walk_circle", "missing"])


func _stage(_item: String, clip: String) -> DotResult:
	if clip == "missing":
		return DotResult.fail(DotError.CODE_INVALID, "the capsule has no missing clip")
	if _body == null:
		_body = Node3D.new()
		var mesh := MeshInstance3D.new()
		mesh.mesh = CapsuleMesh.new()
		mesh.position.y = 1.0
		_body.add_child(mesh)
		var nose := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.15, 0.15, 0.4)
		nose.mesh = box
		nose.position = Vector3(0.0, 1.5, -0.45)
		_body.add_child(nose)
		root.add_child(_body)
		# Your own body on its own layer, which the first-person camera leaves out.
		DotGameVisualQaViews.tag_layers(_body, 1 << 18)
		first_person.cull_mask &= ~(1 << 18)
	_body.position = Vector3.ZERO
	_body.rotation = Vector3.ZERO
	return DotResult.success(clip)


func _subject(_item: String) -> Node3D:
	return _body


func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var angle := t * PI
	if clip == "turn":
		_body.rotation.y = angle
	else:
		_body.position = Vector3(sin(angle), 0.0, cos(angle) - 1.0) * 2.0
		_body.rotation.y = angle + PI * 0.5

extends GSGameVisualQaCapture

## The judge loop's GPU proof (tests/visual_judge, docs/visual-qa.md "The judge loop"): the demo capsule (examples/visual_qa_demo.gd) turning smoothly ("turn"), and "pop", its circle walk with two planted defects a judge must catch: for three frames in the middle the body teleports 1.5 m sideways and its nose box floats 0.6 m off the head.
## Capture it on a GPU box (gpu.sh runs only tools/*.sh): [code]bash addons/gs_game/tools/gs_game_visual_qa.sh --shot tools/visual_judge_proof_shot.sh --out screenshots/vj_proof --no-report -- --clips turn,pop[/code]

var _body: Node3D = null


func _items() -> PackedStringArray:
	return PackedStringArray(["capsule"])


func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray(["turn", "pop"])


func _stage(_item: String, clip: String) -> GSResult:
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
		GSGameVisualQaViews.tag_layers(_body, 1 << 18)
		first_person.cull_mask &= ~(1 << 18)
	_body.position = Vector3.ZERO
	_body.rotation = Vector3.ZERO
	return GSResult.success(clip)


func _subject(_item: String) -> Node3D:
	return _body


func _drive(_item: String, clip: String, t: float, frame: int) -> void:
	var angle := t * PI
	var nose := _body.get_child(1) as Node3D
	nose.position = Vector3(0.0, 1.5, -0.45)
	if clip == "turn":
		_body.rotation.y = angle
		return
	_body.position = Vector3(sin(angle), 0.0, cos(angle) - 1.0) * 2.0
	_body.rotation.y = angle + PI * 0.5
	if frame >= 50 and frame < 53:
		_body.position += Vector3(1.5, 0.0, 0.0)
		nose.position = Vector3(0.0, 2.1, -0.45)

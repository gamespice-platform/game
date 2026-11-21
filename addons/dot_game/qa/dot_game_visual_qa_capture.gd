class_name GSGameVisualQaCapture
extends SceneTree

## The visual QA test scene (docs/visual-qa.md): for each item (weapon, avatar, NPC) and clip it stages the subject, then
## saves every frame at --fps from the first-person camera (f_NNN.jpg), behind-right (t_NNN.jpg) and an opponent in front
## (o_NNN.jpg) into <out>/<item>/_frames/<clip>/, and prints one `VISUALQA {json}` verdict line per clip.
## A game extends this in tools/<name>.gd and overrides the hooks below; dot_game_visual_qa_shot.sh runs it under xvfb.
## Args: --out DIR, --fps N, --only item,item, --clips clip,clip (or --anims), --limits res://x.json. Tool-only: no API level.

## Frames whose every bone sits within this many degrees of its rest pose count as a T-pose (no animation applied).
const TPOSE_DEG := 1.0

var out_dir := "screenshots/visual_qa"
var fps := 60
var only: PackedStringArray = []
var only_clips: PackedStringArray = []
var limits_path := ""
var views := GSGameVisualQaViews.new()
## The stage this class builds when [method _build] is not overridden (floor, light, sky); null otherwise.
var stage: Node3D = null
var first_person: Camera3D = null
var errors := 0


# --- Hooks a game overrides -------------------------------------------------------------------------------------------

## The item names (weapon ids, avatar names, NPC kinds).
func _items() -> PackedStringArray:
	return PackedStringArray()


## The clip names of [param item] (animations, or scripted actions such as walk_circle).
func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray()


## Builds the world once, on the first frame. The default is a lit test stage with a grid floor (see [method build_stage]).
func _build() -> void:
	build_stage()


## Puts [param item] in the scene and readies [param clip]. A failure skips the clip with its message as the reason.
func _stage(_item: String, _clip: String) -> GSResult:
	return GSResult.fail(GSError.CODE_UNSUPPORTED, "the capture script does not override _stage")


## The node whose position is the subject's feet and whose Y rotation is its facing (-Z forward).
func _subject(_item: String) -> Node3D:
	return null


## The skeleton the foot slide, floor and T-pose checks read; the default is the first Skeleton3D under the subject.
func _skeleton(item: String) -> Skeleton3D:
	var subject := _subject(item)
	if subject == null:
		return null
	var found := subject.find_children("*", "Skeleton3D", true, false)
	return null if found.is_empty() else found[0] as Skeleton3D


## Seconds of [param clip] to record.
func _seconds(_item: String, _clip: String) -> float:
	return 2.0


## Frames to run between staging and the first saved frame (assets streaming in, physics settling).
func _warmup_frames(_item: String, _clip: String) -> int:
	return 2


## Poses the subject at [param t] seconds. Seek explicitly (AnimationPlayer.seek(t, true)) so every run draws the same frames.
func _drive(_item: String, _clip: String, _t: float, _frame: int) -> void:
	pass


## Whether the subject should be on the ground at [param t] (false during a jump), for the floor check.
func _grounded(_item: String, _clip: String, _t: float) -> bool:
	return true


## Runs just before each frame draws: hide your own body from the first-person camera, re-show it to the outside ones.
func _before_draw(_item: String, _clip: String, _frame: int) -> void:
	pass


## Places the first-person camera; the default looks out of the subject's eyes, down at its hands and feet.
func _place_first_person(item: String) -> void:
	var subject := _subject(item)
	if subject == null or first_person == null:
		return
	var turn := Basis(Vector3.UP, subject.global_rotation.y)
	first_person.global_position = subject.global_position + turn * Vector3(0.0, 1.6, -0.15)
	first_person.look_at(subject.global_position + turn * Vector3(0.0, 0.6, -1.4))


## Adds the game's own rows ({check, pass, value, limit, note}) to a clip's checks: grip, muzzle, held-item offsets.
func _checks(_item: String, _clip: String, rows: Array[Dictionary]) -> Array[Dictionary]:
	return rows


# --- Helpers --------------------------------------------------------------------------------------------------------

## A 40 m grid floor at y 0 (so foot slide and floor clipping show), a sun, and a plain sky.
func build_stage() -> Node3D:
	stage = Node3D.new()
	stage.name = "VisualQaStage"
	root.add_child(stage)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_mesh.mesh = plane
	var grid := StandardMaterial3D.new()
	grid.albedo_texture = _grid_texture()
	grid.uv1_scale = Vector3(40.0, 40.0, 1.0)
	grid.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	floor_mesh.material_override = grid
	stage.add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	stage.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage.add_child(world_env)
	first_person = Camera3D.new()
	first_person.fov = 75.0
	stage.add_child(first_person)
	first_person.make_current()
	return stage


## The run's (item, clip) pairs after --only and --clips, in order. Static so a suite can check the filter.
static func plan(clips_by_item: Dictionary, only_items: PackedStringArray, wanted: PackedStringArray) -> Array[PackedStringArray]:
	var pairs: Array[PackedStringArray] = []
	for item: String in clips_by_item:
		if not only_items.is_empty() and not only_items.has(item):
			continue
		for clip: String in clips_by_item[item]:
			if wanted.is_empty() or wanted.has(clip):
				pairs.append(PackedStringArray([item, clip]))
	return pairs


## The worst angle in degrees between [param rotations] (one per bone) and [param skeleton]'s rest pose.
static func rest_distance_deg(skeleton: Skeleton3D, rotations: Array) -> float:
	var worst := 0.0
	for i in mini(rotations.size(), skeleton.get_bone_count()):
		var rest := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
		worst = maxf(worst, rad_to_deg(rest.angle_to(rotations[i] as Quaternion)))
	return worst


## A clip's verdict from its check rows: {pass, fail: ["check value > limit"], worst: {check: value}}.
static func verdict(rows: Array[Dictionary]) -> Dictionary:
	var fail: Array[String] = []
	var worst := {}
	for row: Dictionary in rows:
		if row.get("skip", false):
			continue
		worst[row["check"]] = row["value"]
		if not row["pass"]:
			fail.append("%s %s (limit %s)%s" % [row["check"], row["value"], row["limit"], (" " + str(row["note"])) if str(row.get("note", "")) != "" else ""])
	return {"pass": fail.is_empty(), "fail": fail, "worst": worst}


# --- The run ---------------------------------------------------------------------------------------------------------

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var next := args[i + 1] if i + 1 < args.size() else ""
		match args[i]:
			"--out": out_dir = next
			"--fps": fps = next.to_int()
			"--only": only = next.split(",", false)
			"--clips", "--anims": only_clips = next.split(",", false)
			"--limits": limits_path = next
	if fps < 1:
		printerr("visual_qa: --fps must be a whole number of at least 1")
		quit(2)
		return
	# The tree is not ready in _initialize: build on the first frame.
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	_build()
	views.setup(root, root.world_3d)
	var by_item := {}
	for item in _items():
		by_item[item] = _clips(item)
	var pairs := plan(by_item, only, only_clips)
	if pairs.is_empty():
		printerr("visual_qa: nothing to capture (items %s, --only %s, --clips %s)" % [str(by_item.keys()), str(only), str(only_clips)])
		quit(2)
		return
	for pair in pairs:
		await _capture(pair[0], pair[1])
	print("VISUALQA_DONE %d clips, %d errors" % [pairs.size(), errors])
	quit(1 if errors > 0 else 0)


func _capture(item: String, clip: String) -> void:
	var staged := _stage(item, clip)
	if not staged.ok:
		print("VISUALQA " + JSON.stringify({"item": item, "clip": clip, "status": "skip", "why": staged.error.message}))
		return
	for _i in _warmup_frames(item, clip):
		await process_frame
	var seconds := _seconds(item, clip)
	var count := roundi(seconds * fps)
	if count < 1:
		errors += 1
		printerr("visual_qa: %s %s records %s s, under one frame at %d fps" % [item, clip, seconds, fps])
		return
	var dir := "%s/%s/_frames/%s" % [out_dir, item, clip]
	var made := DirAccess.make_dir_recursive_absolute(dir)
	if made != OK:
		errors += 1
		printerr("visual_qa: cannot make %s: %s" % [dir, error_string(made)])
		return
	var metrics := GSClipMetrics.new()
	var skeleton := _skeleton(item)
	var tpose := 0
	# The outside views draw one frame behind the first staging: one staged draw before frame 0 is saved.
	_drive(item, clip, 0.0, 0)
	await RenderingServer.frame_pre_draw
	_place(item, clip, 0)
	await RenderingServer.frame_post_draw
	for i in count:
		var t := float(i) / float(fps)
		_drive(item, clip, t, i)
		await RenderingServer.frame_pre_draw
		_place(item, clip, i)
		var subject := _subject(item)
		var sample := metrics.pose_sample(t, skeleton, subject.global_position if subject != null else Vector3.ZERO, _grounded(item, clip, t))
		metrics.add(sample)
		if skeleton != null and skeleton.get_bone_count() > 0 and rest_distance_deg(skeleton, sample.get("rotations", [])) < TPOSE_DEG:
			tpose += 1
		await RenderingServer.frame_post_draw
		var saved := views.save(dir, i, root.get_viewport())
		if not saved.ok:
			errors += 1
			printerr("visual_qa: %s" % str(saved.error))
			return
	var limits := GSClipMetrics.limits_for(limits_path, clip) if limits_path != "" else {}
	var rows := metrics.evaluate(limits)
	var tpose_limit := int(limits.get("tpose_frames", 1))
	if skeleton == null:
		rows.append({"check": "tpose", "pass": true, "skip": true, "value": "-", "limit": "-", "note": "no skeleton"})
	else:
		rows.append({"check": "tpose", "pass": tpose < tpose_limit, "value": str(tpose), "limit": str(tpose_limit), "note": "frames in rest pose"})
	rows = _checks(item, clip, rows)
	var result := verdict(rows)
	result.merge({"item": item, "clip": clip, "fps": fps, "frames": count, "checks": rows})
	print("VISUALQA " + JSON.stringify(result))


func _place(item: String, clip: String, frame: int) -> void:
	_before_draw(item, clip, frame)
	_place_first_person(item)
	var subject := _subject(item)
	if subject != null:
		views.place(subject.global_position, subject.global_rotation.y)


func _grid_texture() -> ImageTexture:
	var image := Image.create(64, 64, true, Image.FORMAT_RGB8)
	image.fill(Color(0.42, 0.42, 0.42))
	var line := Color(0.15, 0.15, 0.15)
	for i in 64:
		image.set_pixel(i, 0, line)
		image.set_pixel(0, i, line)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

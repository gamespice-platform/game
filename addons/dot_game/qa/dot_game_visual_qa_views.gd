class_name GSGameVisualQaViews
extends RefCounted

## The two outside cameras of a visual QA capture (docs/visual-qa.md): behind-right (how a teammate sees you) and an
## opponent standing in front, each a SubViewport of the game's own world. The first-person view is the game's own
## camera. Tool-only: no API level.

## Each outside view's pixel size. Its height should match the window so the three views stack into one clip.
var size := Vector2i(480, 540)
var fov := 50.0
## What the outside cameras draw: everything but the first-person arms and view layers (see [method tag_layers]).
var cull_mask := 0xFFFFF & ~(1 << 17) & ~(1 << 19)
## Behind-right camera: offset from the feet in the subject's frame (-Z is forward), looking at this height.
var behind_offset := Vector3(1.4, 1.5, 2.0)
var behind_look_height := 1.1
## Opponent camera: standing this far in front, eyes at this height, looking at the chest.
var opponent_offset := Vector3(0.4, 1.6, -4.0)
var opponent_look_height := 1.3
var jpg_quality := 0.9
## The judge's capture variant (env SHOT_VQA_VARIANT, set per pass by dot_game_visual_judge.sh; gpu.sh carries SHOT_*
## to the box). 0 is the standard framing and light; 1 and 2 move both outside cameras and turn and dim/brighten every
## DirectionalLight3D, so consecutive judge passes see the subject from new angles under new light.
var variant := int(OS.get_environment("SHOT_VQA_VARIANT")) if OS.get_environment("SHOT_VQA_VARIANT").is_valid_int() else 0
var _lit := false

var behind_view: SubViewport = null
var behind_camera: Camera3D = null
var opponent_view: SubViewport = null
var opponent_camera: Camera3D = null


## Builds both views under [param host], drawing [param world] with [param environment] (null keeps the world's own).
func setup(host: Node, world: World3D, environment: Environment = null) -> void:
	_apply_camera_variant()
	behind_view = _view(host, world, environment)
	behind_camera = behind_view.get_child(0) as Camera3D
	opponent_view = _view(host, world, environment)
	opponent_camera = opponent_view.get_child(0) as Camera3D


## Places both cameras around a subject standing at [param feet], facing -Z turned by [param yaw] radians.
func place(feet: Vector3, yaw: float) -> void:
	if behind_camera == null:
		return
	if not _lit:
		_lit = true
		_apply_light_variant(behind_view)
	var turn := Basis(Vector3.UP, yaw)
	behind_camera.global_position = feet + turn * behind_offset
	behind_camera.look_at(feet + Vector3(0.0, behind_look_height, 0.0))
	opponent_camera.global_position = feet + turn * opponent_offset
	opponent_camera.look_at(feet + Vector3(0.0, opponent_look_height, 0.0))


## Writes frame [param index] of all three views into [param dir]: f_NNN.jpg ([param first_person]), t_NNN.jpg, o_NNN.jpg.
## Call it after RenderingServer.frame_post_draw so all three hold the same frame.
func save(dir: String, index: int, first_person: Viewport) -> GSResult:
	var shots := {"f": first_person, "t": behind_view, "o": opponent_view}
	for prefix: String in shots:
		var view := shots[prefix] as Viewport
		if view == null:
			continue
		var path := "%s/%s_%03d.jpg" % [dir, prefix, index]
		var err := view.get_texture().get_image().save_jpg(path, jpg_quality)
		if err != OK:
			return GSResult.fail(GSError.CODE_IO, "visual QA frame not saved", "%s: %s" % [path, error_string(err)])
	return GSResult.success(index)


## Puts every VisualInstance3D under [param node] on [param layer] (skipping the [param skip] subtree), so one camera
## can hide it: the first-person arms on 1 << 17 for the outside views, your own body on 1 << 18 for the first-person camera.
static func tag_layers(node: Node, layer: int, skip: Node = null) -> int:
	if node == null or node == skip:
		return 0
	var tagged := 0
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer
		tagged += 1
	for child: Node in node.get_children():
		tagged += tag_layers(child, layer, skip)
	return tagged


## Variant 1: behind-left and a lower opponent off to the side; variant 2: a high close behind-right and the opponent
## further out on the other side. Other values wrap.
func _apply_camera_variant() -> void:
	match variant % 3:
		1:
			behind_offset = Vector3(-1.6, 1.2, 1.6)
			opponent_offset = Vector3(-1.8, 1.3, -3.4)
		2:
			behind_offset = Vector3(0.9, 2.1, 1.3)
			opponent_offset = Vector3(1.6, 1.8, -4.6)


## Turns every DirectionalLight3D in the scene around the vertical axis and scales its energy for variants 1 and 2,
## once, the first time the cameras are placed (the capture scene has built its lights by then).
func _apply_light_variant(node: Node) -> void:
	if variant % 3 == 0 or node == null or not node.is_inside_tree():
		return
	var yaw := deg_to_rad(70.0 if variant % 3 == 1 else -70.0)
	var energy := 0.65 if variant % 3 == 1 else 1.35
	for light: Node in node.get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		var sun := light as DirectionalLight3D
		sun.global_basis = Basis(Vector3.UP, yaw) * sun.global_basis
		sun.light_energy *= energy
	print("VISUALQA variant %d: cameras %s / %s, lights turned %d deg, energy x%.2f" % [variant, behind_offset, opponent_offset, roundi(rad_to_deg(yaw)), energy])


func _view(host: Node, world: World3D, environment: Environment) -> SubViewport:
	var view := SubViewport.new()
	view.size = size
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.world_3d = world
	host.add_child(view)
	var cam := Camera3D.new()
	cam.fov = fov
	cam.cull_mask = cull_mask
	if environment != null:
		cam.environment = environment
	view.add_child(cam)
	return view

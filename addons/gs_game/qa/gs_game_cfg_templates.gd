extends SceneTree

## Rewrites every game's shipped `cfg/game/<game>/config_*/game.yml` from its config's fields: GPU_OFFLOAD=0 heavy -- godot --headless --path . --script addons/gs_game/qa/gs_game_cfg_templates.gd
## GPU_OFFLOAD=0 matters: heavy may run the job on a staging box, where the files land in its copy and never here.


func _init() -> void:
	var failed := false
	print("project: %s (%s)" % [ProjectSettings.globalize_path("res://"), OS.get_environment("HOSTNAME")])
	for script: Script in GSGameConfigSchemas.config_scripts():
		if not script.has_method("make_binder"):
			continue
		var made := GSGameConfigSchemas.binder_of(script)
		if not made.ok:
			printerr("FAILED ", made.error.message)
			failed = true
			continue
		var binder: GSGameConfigBinder = made.value
		var res := binder.write_templates()
		print("%s %s" % ["wrote" if res.ok else "FAILED", ",".join(binder.template_files().keys())])
		if not res.ok:
			printerr(res.error.message)
		failed = failed or not res.ok
	quit(1 if failed else 0)

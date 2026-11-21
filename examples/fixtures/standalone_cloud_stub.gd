extends Node
## Stands in for GSCloudClient: the same members GSGameStandaloneContent touches, driven by the test.

enum Phase { IDLE, DOWNLOADING, READY, FAILED }

signal phase_changed(phase: Phase, text: String)
signal progress_changed(progress: Dictionary)

var host_role := ""
var config: Object = null
var config_file := ""
var http_base_urls := PackedStringArray()
var manifest_url_template := ""
var manifest_url_fallbacks := PackedStringArray()
var local_search_dirs := PackedStringArray()
var keys := PackedStringArray()


func _ready() -> void:
	GSRegistry.register(&"gs_cloud_client", self)


func acquired_keys() -> PackedStringArray:
	return keys


func manifest_urls_for(id: StringName, version: String) -> PackedStringArray:
	var out := PackedStringArray()
	for b in http_base_urls:
		out.append("%s/%s/%s/manifest.json" % [b, id, version])
	return out

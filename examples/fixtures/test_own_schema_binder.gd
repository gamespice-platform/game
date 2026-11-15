extends RefCounted

## Fixture for headless_config: a binder over a config whose own script provides its kind (as
## DotFlashlightConfig does), so DotGameConfigSchemas leaves that kind to the config.


static func make_config() -> DotConfig:
	return preload("test_own_schema_config.gd").new()


static func make_binder(cfg: DotConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, "to", "to")
	b.profile_kind = "own"
	return b

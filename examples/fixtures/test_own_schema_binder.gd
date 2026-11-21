extends RefCounted

## Fixture for headless_config: a binder over a config whose own script provides its kind (as
## GSFlashlightConfig does), so GSGameConfigSchemas leaves that kind to the config.


static func make_config() -> GSConfig:
	return preload("test_own_schema_config.gd").new()


static func make_binder(cfg: GSConfig) -> GSGameConfigBinder:
	var b := GSGameConfigBinder.create(cfg, "to", "to")
	b.profile_kind = "own"
	return b

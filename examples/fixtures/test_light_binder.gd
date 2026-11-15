extends RefCounted

## Fixture for headless_config: a binder script that is not itself a config (a game's flashlight script),
## so its config comes from make_config(), never from new().


static func make_config() -> DotConfig:
	return preload("test_config.gd").new()


static func make_binder(cfg: DotConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, "tl", "tl")
	b.profile_kind = "light"
	return b

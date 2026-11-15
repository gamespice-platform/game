extends "test_config.gd"

## Fixture for headless_config: a config that provides its own profile kind, as an addon config does.


static func profile_schemas() -> Dictionary:
	return {"own": {"schema": [], "children": {}}}

class_name GSGameStatsReport
extends RefCounted

## The family's one switch for filing a server's stats with the backbone: the cvar `stats_report`.

const CHANNEL := "game.stats"
const CVAR := "stats_report"
const TIMER_NAME := "StatsReportTimer"


## Registers `stats_report` (default 0) on [param module], plus each name in [param legacy] as an alias that
## moves with it. [param apply] is func(on: bool) -> GSResult for a game that drives its own tracker;
## unset, [method apply_default] flips the tracker the module's feed or the registry holds.
static func bind(module: GSModule, apply: Callable = Callable(), legacy: PackedStringArray = PackedStringArray()) -> GSConVar:
	var flags := GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	var primary := module.add_cvar(CVAR,
		"0", "File player stats with the backbone (1) or keep them on this server (0); uses the server's own backbone ticket", flags
	).with_min(0.0).with_max(1.0)
	var all: Array[GSConVar] = [primary]
	for old_name: String in legacy:
		all.append(module.add_cvar(old_name, "0", "Alias of %s" % CVAR, flags).with_min(0.0).with_max(1.0))

	# Weak refs throughout: the cvar's own signal must not hold the cvar (or the module that owns it) alive.
	var refs: Array[WeakRef] = []
	for cv: GSConVar in all:
		refs.append(weakref(cv))
	var module_ref := weakref(module)
	var busy := [false]
	var run := func(on: bool) -> void:
		var m := module_ref.get_ref() as GSModule
		if m == null:
			return
		var res: GSResult = apply.call(on) if apply.is_valid() else apply_default(m, on)
		GSLog.info(CHANNEL, "stats reporting", {"on": on, "ok": res.ok})
	var follow := func(changed_cv: GSConVar, new_value: String) -> void:
		if busy[0]:
			return
		busy[0] = true
		var on := new_value.to_int() != 0
		for ref: WeakRef in refs:
			var other := ref.get_ref() as GSConVar
			if other != null and other != changed_cv:
				other.force_set("1" if on else "0")
		busy[0] = false
		run.call(on)
	for i in all.size():
		var idx := i
		all[i].changed.connect(func(_old: String, new_value: String) -> void:
			follow.call(refs[idx].get_ref() as GSConVar, new_value))

	# A cfg that sets only an old name still turns it on.
	for cv: GSConVar in all:
		if cv.get_string() != "0" and cv.get_int() != 0:
			follow.call(null, "1")
			break
	return primary


## Turns the backbone report on the module's tracker on or off. The reporter signs with the registered
## backbone client's own ticket, so nothing is configured here.
static func apply_default(module: GSModule, on: bool) -> GSResult:
	var tracker: Object = null
	if module is GSGameModule and (module as GSGameModule).stats_feed != null:
		tracker = (module as GSGameModule).stats_feed.active_tracker()
	if tracker == null:
		tracker = GSRegistry.get_service(GSGameStatsFeed.SERVICE)
	if tracker == null or not tracker.has_method("flush") or tracker.get("reporter") == null:
		return GSResult.fail(GSError.CODE_STATE, "There is no stats tracker.")

	if not on:
		tracker.set("report_to_backbone", false)
		return GSResult.success(false)

	var reporter: Object = tracker.get("reporter")
	if not reporter.call("is_available"):
		tracker.set("report_to_backbone", false)
		GSLog.warn(CHANNEL, "stats reporting needs a backbone client with STATS_WRITE; staying off")
		return GSResult.fail(GSError.CODE_STATE, "No backbone client to report stats through.")

	tracker.set("report_to_backbone", true)
	tracker.set("define_on_start", true)
	var node := tracker as Node
	var interval := float(tracker.get("report_interval"))
	if node != null and interval > 0.0 and node.get_node_or_null(TIMER_NAME) == null:
		var timer := Timer.new()
		timer.name = TIMER_NAME
		timer.wait_time = interval
		timer.autostart = true
		timer.timeout.connect(func() -> void: tracker.call("flush"))
		node.add_child(timer)
	return GSResult.success(true)

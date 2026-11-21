class_name GSGamePageGuard
extends RefCounted

## The browser's leave-site prompt for [GSGameClient]: armed while a game is live, so Ctrl+W does not lose a round silently.

const CHANNEL := "game.client"
const INSTALL := "install"
const ARM := "arm"
const DISARM := "disarm"

static func is_web(c: Node) -> bool:
	return c.web_guard_fn.is_valid() or GSPlatform.is_web()


## The listeners live in GameSpice Core's web/gs_web.js, loaded by the shell page; only the flag is set from here.
static func run(c: Node, command: String) -> void:
	if c.web_guard_fn.is_valid():
		c.web_guard_fn.call(command)
	elif command == ARM or command == DISARM:
		GSWeb.set_tab_guard_armed(command == ARM)
	elif not GSWeb.has_tab_guard():
		GSLog.warn(CHANNEL, "the page does not load gs_web.js; no leave-site prompt or keyboard lock")


static func install(c: Node) -> void:
	if c._guard_installed or not is_web(c):
		return
	c._guard_installed = true
	run(c, INSTALL)


## Arms the prompt while online with a live link, or offline (a solo round lost to Ctrl+W is lost all the same).
static func refresh(c: Node) -> void:
	if not c._guard_installed:
		return
	var want: bool = c.offline or c.is_in_live_game()
	if want == c._guard_armed:
		return
	c._guard_armed = want
	run(c, ARM if want else DISARM)
	GSLog.debug(CHANNEL, "leave-site prompt armed" if want else "leave-site prompt disarmed")


static func clear(c: Node, log := true) -> void:
	if c._guard_installed and c._guard_armed:
		c._guard_armed = false
		run(c, DISARM)
		if log:
			GSLog.debug(CHANNEL, "leave-site prompt cleared for a deliberate navigation")

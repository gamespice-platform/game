extends Node

## The bridge between a game and its netcode, reduced to the interface GameSpice Game uses.
##
## Duck-typed by [GSGameNetcode] and [GSGameModule]: in a real game this is the game's own class.

var game: Object = null
var net: GSNetManager = null

## What the module hands a services layer as its `link`.
var link: Object = null

## Set by the module when a services layer can relay voice.
var voice_relay_fn: Callable = Callable()

var attached: bool = false
var link_opened: bool = false
var ticks: Array[int] = []
var added: Array[int] = []
var removed: Array[int] = []

## Set by a suite to make `attach` refuse, which is the path that has to unwind.
var refuse_attach: bool = false


func attach(p_game: Object, p_net: GSNetManager) -> GSResult:
	if refuse_attach:
		return GSResult.fail(GSError.CODE_STATE, "refusing on purpose")

	game = p_game
	net = p_net
	attached = true
	return GSResult.success(null)


func open_link(_server: GSServer) -> void:
	link_opened = true
	link = self


func server_tick(tick: int) -> void:
	ticks.append(tick)


func add_player(peer_id: int, userid: int, _name: String) -> GSResult:
	added.append(userid)
	link = link if link != null else self
	return GSResult.success(peer_id)


func remove_peer(peer_id: int) -> void:
	removed.append(peer_id)

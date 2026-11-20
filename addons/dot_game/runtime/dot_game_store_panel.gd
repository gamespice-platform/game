class_name DotGameStorePanel
extends PanelContainer

## The site store in game: the points balance, what the player owns, what they can buy with a Buy button, and a link to the store page. Plain controls, so any game's menu or HUD can parent it.
##
## The same read the server's [DotGameStoreEntitlements] merges into the loadout, here with names for the player to see. A failed read shows the error and a Retry button.

const CHANNEL := "game.store"
const PATH := "store/entitlements"
## What the player can buy, with prices and whether they own it (STORE_READ).
const ITEMS_PATH := "store/items"
## Buys one item with the player's app points (STORE_WRITE); answers like [constant PATH].
const PURCHASE_PATH := "store/purchase"
const STORE_PATH := "/dashboard/store"
## The token audiences ([code]app:<id>[/code], [code]server:<id>[/code]) that have a store page of their own.
const OWNER_KINDS: Array[String] = ["app", "server"]

## Emitted by the button with the address to open; a game that cannot open a browser listens instead.
signal store_requested(url: String)
signal owned_changed()
## A purchase went through; [param answer] is TMC's (`status`, `purchase`, `points`, `items`).
signal purchased(item_id: String, answer: Dictionary)

## Where "Get more" goes. Empty means this game's store page on the site this client signs in against.
var store_url: String = ""

var _owned: Array = []
var _offers: Array = []
var _points: Dictionary = {}
var _audience: String = ""
var _error: String = ""
var _client: Object = null
var _player_key: String = ""
var _busy := false
var _list: VBoxContainer = null
var _shop: VBoxContainer = null
var _title: Label = null
var _balance: Label = null
var _status: Label = null
var _retry: Button = null
var _button: Button = null


## Items from an entitlements response as `{key, name, kind, store}`, one per key.
static func owned_from(body: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	var items: Variant = body.get("items", [])
	if not items is Array:
		return out
	for item: Variant in items:
		if not item is Dictionary:
			continue
		var d: Dictionary = item
		var key := str(d.get("key", ""))
		if key == "" or seen.has(key):
			continue
		seen[key] = true
		out.append({"key": key, "name": str(d.get("name", key)), "kind": str(d.get("kind", "")), "store": str(d.get("store", ""))})
	return out


## What can be bought from a `store/items` answer as `{id, key, name, kind, price, owned}`; entries without an id are skipped.
static func offers_from(body: Dictionary) -> Array:
	var out: Array = []
	var items: Variant = body.get("items", [])
	if not items is Array:
		return out
	for item: Variant in items:
		if not item is Dictionary or str((item as Dictionary).get("id", "")) == "":
			continue
		var d: Dictionary = item
		out.append({"id": str(d["id"]), "key": str(d.get("key", "")), "name": str(d.get("name", d.get("key", d["id"]))),
			"kind": str(d.get("kind", "")), "price": int(d["price"]) if d.get("price") is int or d.get("price") is float else 0, "owned": d.get("owned") == true})
	return out


## The `aud` of a store token, read without checking the signature: it only picks which store page to link.
static func audience_of(token: String) -> String:
	var payload: Variant = JSON.parse_string(DotHash.base64url_decode_text(token.get_slice(".", 0))) if token.contains(".") else null
	return str((payload as Dictionary).get("aud", "")) if payload is Dictionary else ""


## The store page of [param audience] on [param site]: `/dashboard/store/app/<id>` or `/dashboard/store/server/<id>`, else the store's front page. Empty when the site is not known.
static func store_url_for(site: String, audience: String) -> String:
	if site == "":
		return ""
	var kind := audience.get_slice(":", 0)
	var id := audience.get_slice(":", 1) if audience.contains(":") else ""
	if kind in OWNER_KINDS and id.is_valid_int() and int(id) > 0:
		return "%s%s/%s/%s" % [site, STORE_PATH, kind, id]
	return site + STORE_PATH


## Adds a "Store" page to a GameSpice Menu (located by duck typing: null or no `add_page` does nothing) that shows a fresh panel each time it opens. [param player_key_fn] returns the player key; [param client_fn] the backbone client (default: the registry's `dot_backbone_client`). Returns the page, or null.
static func add_to_menu(menu: Object, player_key_fn: Callable, client_fn: Callable = Callable(), before: StringName = &"") -> Object:
	if menu == null or not menu.has_method(&"add_page"):
		return null
	var page_script: Script = (load("uid://bihmsrfo1d7x7") as GDScript)._class_script("DotMenuPage")  # DotGameStoreEntitlements, loaded so the two parsers do not hold each other
	if page_script == null:
		return null
	var cache: Array = []
	var page: Object = page_script.call("make", &"store", "Store", "Your points, what you own and what you can buy.")
	page.set("build", func(_kit: Object, body: Control) -> void:
		var panel := DotGameStorePanel.new()
		panel.set_owned(cache)
		body.add_child(panel)
		var client: Object = client_fn.call() if client_fn.is_valid() else DotRegistry.get_service(&"dot_backbone_client")
		var key: String = str(player_key_fn.call()) if player_key_fn.is_valid() else ""
		if client == null or key == "":
			return
		await panel.refresh(client, key)
		cache.assign(panel.owned()))
	menu.call(&"add_page", page, before)
	return page


func _init() -> void:
	name = "StorePanel"
	custom_minimum_size = Vector2(260, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 6)
	add_child(col)
	_balance = Label.new()
	_balance.name = "Balance"
	col.add_child(_balance)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	_retry = Button.new()
	_retry.name = "Retry"
	_retry.text = "Retry"
	_retry.pressed.connect(retry)
	col.add_child(_retry)
	_title = Label.new()
	col.add_child(_title)
	_list = VBoxContainer.new()
	col.add_child(_list)
	_shop = VBoxContainer.new()
	_shop.name = "Shop"
	col.add_child(_shop)
	_button = Button.new()
	_button.name = "GetMore"
	_button.text = "Get more in the store"
	_button.pressed.connect(open_store)
	col.add_child(_button)
	_rebuild()


## Replaces what is shown with [param items] (see [method owned_from]).
func set_owned(items: Array) -> void:
	_owned = items.duplicate()
	_rebuild()
	owned_changed.emit()


func owned() -> Array:
	return _owned


func is_owned(key: String) -> bool:
	for d: Variant in _owned:
		if str((d as Dictionary).get("key", "")) == key:
			return true
	return false


## {enabled, balance, label} from the last read; empty before one.
func points() -> Dictionary:
	return _points


func offers() -> Array:
	return _offers


## The message shown for the last failed read or purchase; empty when the last one worked.
func error_text() -> String:
	return _error


## Reads the player's entitlements and points, then what they can buy, through a backbone client (`get_integration`, GameSpice Auth's). A failed read is returned, logged and shown with a Retry button; the list is left as it was. A store without the `store/items` read only hides the Buy list.
func refresh(client: Object, player_key: String) -> DotResult:
	_client = client
	_player_key = player_key
	if client == null or not client.has_method("get_integration"):
		return _failed(DotResult.fail(DotError.CODE_STATE, "No backbone client with get_integration."), "read")
	var res: DotResult = await client.call("get_integration", PATH, {"player": player_key, "include": "points"})
	if res.ok and not res.value is Dictionary:
		res = DotResult.fail(DotError.CODE_INVALID, "The entitlements response is not an object.")
	if not res.ok:
		return _failed(res, "read")
	_error = ""
	_apply(res.value)
	var shop: DotResult = await client.call("get_integration", ITEMS_PATH, {"player": player_key})
	_offers = offers_from(shop.value) if shop.ok and shop.value is Dictionary else []
	if not shop.ok:
		DotLog.debug(CHANNEL, "store items not readable; buying in game is hidden", {"error": str(shop.error)})
	_rebuild()
	return DotResult.success(_owned.size())


## Reads again with the last client and player; what the Retry button does.
func retry() -> void:
	if _client != null and _player_key != "":
		await refresh(_client, _player_key)


## Buys [param item_id] with the player's points through the backbone client's `post_integration`. On success the owned list and balance come from TMC's answer and [signal purchased] fires; a refusal (not enough points, not for sale) is shown and returned. One purchase at a time.
func buy(item_id: String) -> DotResult:
	if _busy:
		return DotResult.fail(DotError.CODE_STATE, "A purchase is already running.")
	if _client == null or not _client.has_method("post_integration") or _player_key == "":
		return _failed(DotResult.fail(DotError.CODE_STATE, "Buying needs a signed-in player and a backbone client with post_integration."), "buy")
	_busy = true
	_rebuild()
	var res: DotResult = await _client.call("post_integration", PURCHASE_PATH, {"player": _player_key, "itemId": item_id,
		"idemKey": "%s:%s:%d" % [_player_key, item_id, Time.get_ticks_usec()], "include": "points"})
	_busy = false
	if res.ok and not res.value is Dictionary:
		res = DotResult.fail(DotError.CODE_INVALID, "The purchase response is not an object.")
	if not res.ok:
		return _failed(res, "buy")
	_error = ""
	for o: Dictionary in _offers:
		if o["id"] == item_id:
			o["owned"] = true
	_apply(res.value)
	purchased.emit(item_id, res.value)
	return DotResult.success(res.value)


func _apply(body: Dictionary) -> void:
	var shown: Variant = body.get("points")
	_points = (shown as Dictionary).duplicate() if shown is Dictionary else {}
	var aud := audience_of(str(body.get("token", "")))
	if aud != "":
		_audience = aud
	set_owned(owned_from(body))


func _failed(res: DotResult, what: String) -> DotResult:
	DotLog.warn(CHANNEL, "store panel %s failed" % what, {"error": str(res.error)})
	var msg := res.error.message if res.error != null else "unknown error"
	_error = ("Could not buy: %s" if what == "buy" else "The store is unavailable: %s") % msg
	_rebuild()
	return res


## The address "Get more" opens: [member store_url], else this game's store page (from the token's audience) on the sign-in site.
func resolved_store_url() -> String:
	if store_url != "":
		return store_url
	return store_url_for(DotGameAvatarContent.default_site_url(), _audience)


## The sign-in site's store page; empty when the site is not known. Shared with the loadout menu's locked items.
static func default_store_url() -> String:
	var site := DotGameAvatarContent.default_site_url()
	return site + STORE_PATH if site != "" else ""


func open_store() -> void:
	var url := resolved_store_url()
	if url == "":
		return
	store_requested.emit(url)
	if store_requested.get_connections().size() == 0:
		OS.shell_open(url)


func _rebuild() -> void:
	if _list == null:
		return
	for c: Node in _list.get_children():
		c.queue_free()
		_list.remove_child(c)
	for c: Node in _shop.get_children():
		c.queue_free()
		_shop.remove_child(c)
	var enabled := bool(_points.get("enabled", false)) and _points.get("balance") != null
	_balance.visible = enabled
	_balance.text = "Balance: %d %s" % [int(_points.get("balance", 0)), str(_points.get("label", "points"))] if enabled else ""
	_status.visible = _error != ""
	_status.text = _error
	_retry.visible = _error != "" and _client != null
	_title.text = "Store items you own (%d)" % _owned.size()
	if _owned.is_empty():
		var none := Label.new()
		none.text = "You own nothing from this store yet." if _error == "" else "Nothing to show until the store answers."
		_list.add_child(none)
	for d: Variant in _owned:
		var row := Label.new()
		row.text = "%s  [%s]" % [str((d as Dictionary)["name"]), str((d as Dictionary)["kind"])] if str((d as Dictionary)["kind"]) != "" else str((d as Dictionary)["name"])
		_list.add_child(row)
	var buyable := _offers.filter(func(o: Dictionary) -> bool: return not o["owned"] and not is_owned(str(o["key"])))
	if not buyable.is_empty():
		var head := Label.new()
		head.text = "Buy with points"
		_shop.add_child(head)
	for o: Dictionary in buyable:
		var buy_button := Button.new()
		buy_button.name = "Buy_%s" % str(o["id"]).validate_node_name()
		buy_button.text = "%s  %d" % [o["name"], o["price"]]
		buy_button.disabled = _busy or (enabled and int(_points.get("balance", 0)) < int(o["price"]))
		var id := str(o["id"])
		buy_button.pressed.connect(func() -> void: buy(id))
		_shop.add_child(buy_button)
	_button.visible = resolved_store_url() != ""

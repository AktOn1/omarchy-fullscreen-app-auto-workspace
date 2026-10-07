-- Fullscreen App Auto Workspace: a fullscreen game lives on its own special workspace, like the
-- SUPER + S scratchpad, so a keybind hides it and brings it back. A game that
-- runs fullscreen or borderless (a window covering its whole monitor) moves
-- there by itself and is kept fullscreen for as long as it stays there.
-- Windowed games and every other app are left alone.
--
-- Loaded by the Omarchy shell plugin through `hyprctl eval`. Uses only raw
-- Hyprland Lua (hl.*), no network, no os.execute / io.popen. Everything it
-- registers is tracked so M.stop() removes it again.

local previous = rawget(_G, "__game_layer")
if previous and previous.stop then
  pcall(previous.stop)
end

local LAYER = "fullscreen"
local LAYER_WS = "special:" .. LAYER
local keep_others = false

local M = {}
local rules, handlers, timers = {}, {}, {}
local running = false
local busy = {}
local pending = false
local saved_focus_on_activate = nil
local focus_restore_id = 0

local function restore_focus_on_activate()
  if saved_focus_on_activate ~= nil then
    hl.config({ misc = { focus_on_activate = saved_focus_on_activate } })
    saved_focus_on_activate = nil
  end
end

-- Only repeating timers need tracking; one-shots expire on their own.
local function add_repeating_timer(fn, opts)
  local t = hl.timer(fn, opts)
  timers[#timers + 1] = t
  return t
end

local function add_rule(rule)
  local r = hl.window_rule(rule)
  rules[#rules + 1] = r
  return r
end

-- Dynamic tags carry a trailing "*".
local function is_game(window)
  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == "game" then
      return true
    end
  end
  return false
end

local function on_layer(window)
  return window.workspace ~= nil and window.workspace.name == LAYER_WS
end

-- Borderless games are plain windows the size of the monitor; Hyprland's
-- border may push them a few pixels off, so allow a little slack.
local function covers_monitor(window)
  local monitor = window.monitor
  local size = window.size
  if not monitor or type(size) ~= "table" or not size.x then
    return false
  end
  local slack = 2 * (tonumber(hl.get_config("general.border_size")) or 0) + 4
  return size.x >= monitor.width - slack and size.y >= monitor.height - slack
end

local function wants_layer(window)
  return window.fullscreen > 0 or window.fullscreen_client > 0 or (window.floating and covers_monitor(window))
end

-- Our own moves and fullscreen changes fire events too; leave a window alone
-- for a moment after acting on it.
local function run(window, dispatchers)
  if #dispatchers == 0 then
    return
  end
  local address = window.address
  busy[address] = true
  for _, dispatcher in ipairs(dispatchers) do
    pcall(hl.dispatch, dispatcher)
  end
  hl.timer(function()
    busy[address] = nil
  end, { timeout = 300, type = "oneshot" })
end

local function claim(window)
  local dispatchers = {}
  if not on_layer(window) then
    table.insert(dispatchers, hl.dsp.window.move({ window = window, workspace = LAYER_WS, follow = window.active }))
  end
  if window.fullscreen ~= 2 then
    table.insert(dispatchers, hl.dsp.window.fullscreen({ window = window, mode = "fullscreen", action = "set" }))
  end
  run(window, dispatchers)
end

-- A window opened while the layer had focus belongs on the normal workspace.
local function evict(window)
  local monitor = window.monitor or hl.get_active_monitor()
  local workspace = monitor and monitor.active_workspace
  if not workspace then
    return
  end
  local dispatchers = {}
  if window.fullscreen > 0 then
    table.insert(dispatchers, hl.dsp.window.fullscreen({ window = window, action = "unset" }))
  end
  table.insert(dispatchers, hl.dsp.window.move({ window = window, workspace = tostring(workspace.id), follow = true }))
  run(window, dispatchers)
end

-- Everything that is not a game leaves the layer first, then games that
-- belong there get it (and their fullscreen) back.
local function sweep()
  if not running then
    return
  end
  local windows = hl.get_windows()
  for _, window in ipairs(windows) do
    if not keep_others and window.mapped and not busy[window.address] and not is_game(window) and on_layer(window) then
      evict(window)
    end
  end
  for _, window in ipairs(windows) do
    if window.mapped and not busy[window.address] and is_game(window) and (on_layer(window) or wants_layer(window)) then
      claim(window)
    end
  end
end

-- Window state catches up just after an event, so sweep a moment later.
local function schedule()
  if pending then
    return
  end
  pending = true
  hl.timer(function()
    pending = false
    sweep()
  end, { timeout = 50, type = "oneshot" })
end

-- Hides the layer (and briefly stops windows from stealing focus back), or
-- shows it when a game is on it.
function M.toggle()
  local monitor = hl.get_active_monitor()
  local special = monitor and monitor.active_special_workspace
  if special and special.name == LAYER_WS then
    -- Keep the first value across rapid toggles, or the temporary false would be saved as the user's setting.
    if saved_focus_on_activate == nil then
      saved_focus_on_activate = hl.get_config("misc.focus_on_activate")
    end
    hl.config({ misc = { focus_on_activate = false } })
    focus_restore_id = focus_restore_id + 1
    local id = focus_restore_id
    hl.timer(function()
      if id == focus_restore_id then
        restore_focus_on_activate()
      end
    end, { timeout = 2000, type = "oneshot" })
  else
    -- Showing an empty layer would only dim the screen, so open it only when
    -- a game is on it.
    local occupied = false
    for _, window in ipairs(hl.get_windows()) do
      if window.mapped and window.workspace and window.workspace.name == LAYER_WS then
        occupied = true
        break
      end
    end
    if not occupied then
      return
    end
  end
  hl.dispatch(hl.dsp.workspace.toggle_special(LAYER))
end

-- opts.extra_classes:    extra window class patterns that count as games
-- opts.never_fullscreen: class patterns whose fullscreen Hyprland decides
-- opts.sweep_interval_ms: how often the safety sweep runs (default 1500)
-- opts.layer:            name of the special workspace the games go to (default "fullscreen")
-- opts.keep_others:      leave non-game windows on that workspace alone (set when it is a shared scratchpad)
function M.start(opts)
  opts = opts or {}
  if running then
    M.stop()
  end
  running = true
  LAYER = type(opts.layer) == "string" and opts.layer ~= "" and opts.layer or "fullscreen"
  LAYER_WS = "special:" .. LAYER
  keep_others = opts.keep_others == true

  -- Wine/Proton (*.exe), Proton (steam_app_*), gamescope, and anything that
  -- declares itself a game. Browser videos and players are left alone.
  add_rule({ match = { class = "^(.*\\.exe|steam_app_.*|gamescope)$" }, tag = "+game" })
  add_rule({ match = { content = "game" }, tag = "+game" })
  for _, pattern in ipairs(opts.extra_classes or {}) do
    add_rule({ match = { class = pattern }, tag = "+game" })
  end

  -- Wine games ask for focus again as soon as they lose it; with Omarchy's
  -- focus_on_activate that would reopen the layer right after hiding it.
  add_rule({ match = { tag = "game" }, suppress_event = "activatefocus" })
  -- Some games drop their fullscreen at startup and only cover the screen as
  -- a plain window. Hyprland decides their fullscreen instead.
  for _, pattern in ipairs(opts.never_fullscreen or {}) do
    add_rule({ match = { class = pattern }, suppress_event = "fullscreen activatefocus" })
  end

  handlers[#handlers + 1] = hl.on("window.fullscreen", schedule)
  handlers[#handlers + 1] = hl.on("window.open", schedule)
  handlers[#handlers + 1] = hl.on("window.active", schedule)

  -- Borderless games often size themselves to the screen only after opening,
  -- and nothing fires for a resize, so sweep now and then as well.
  add_repeating_timer(sweep, { timeout = tonumber(opts.sweep_interval_ms) or 1500, type = "repeat" })
end

function M.stop()
  running = false
  restore_focus_on_activate()
  for _, handler in ipairs(handlers) do
    pcall(function() handler:remove() end)
  end
  for _, timer in ipairs(timers) do
    pcall(function() timer:set_enabled(false) end)
  end
  for _, rule in ipairs(rules) do
    pcall(function() rule:set_enabled(false) end)
  end
  rules, handlers, timers, busy, pending = {}, {}, {}, {}, false
end

_G.__game_layer = M
return M

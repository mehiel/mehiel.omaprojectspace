-- Projectspaces (mehiel.omaprojectspace). Linked as ~/.config/hypr/omaprojectspace.lua
-- and required from hyprland.lua by `omaprojectspace install`.

-- The workspace panel: names, attachments, and what each projectspace sets.
o.bind("SUPER + ALT + P", "Projectspaces", "omarchy-shell mehiel.omaprojectspace toggle")

-- The stock browser binds hand URLs straight to a running Chrome, past the
-- uwsm-app shim. On an attached workspace this opens the projectspace's own
-- $BROWSER (its Chrome profile) instead; elsewhere it is the stock launcher.
o.rebind("SUPER + SHIFT + RETURN", "Browser", "omaprojectspace browser")
o.rebind("SUPER + SHIFT + B", "Browser", "omaprojectspace browser")

-- Windows are saved on demand only (`omaprojectspace save`). An earlier
-- version saved every minute from a timer; a config reload stops one left
-- running from it.
if OMAPROJECTSPACE_SAVE_TIMER then
  OMAPROJECTSPACE_SAVE_TIMER:set_enabled(false)
  OMAPROJECTSPACE_SAVE_TIMER = nil
end

-- Omarchy renumbers a workspace (hl.dsp.workspace.change_id) when it joins
-- another monitor's block of ten: moved there, or left behind by an unplugged
-- monitor and sent home when it returns. Hyprland reports none of it, and
-- attachments are keyed by id, so they would stay behind. This remembers which
-- workspace every window is on. A workspace that is gone, while every window
-- it had now sits together on one that did not exist before, was renumbered,
-- and `omaprojectspace renumber` carries its attachment, saved windows and
-- name along. A window you move is recorded as it moves, so emptying a
-- workspace that way never counts as one.
local where = {}
local existing = {}

local function look()
  local windows, ids = {}, {}
  for _, workspace in ipairs(hl.get_workspaces()) do
    if not workspace.special and workspace.id > 0 then ids[workspace.id] = true end
  end
  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    if workspace and not workspace.special and workspace.id > 0 then windows[window.address] = workspace.id end
  end
  return windows, ids
end

local function follow()
  local windows, ids = look()
  local held = {}
  for address, id in pairs(where) do
    held[id] = held[id] or {}
    table.insert(held[id], address)
  end

  local moves = {}
  for old, addresses in pairs(held) do
    if not ids[old] then
      local target, together = nil, true
      for _, address in ipairs(addresses) do
        local now = windows[address]
        if now then
          if target and target ~= now then together = false end
          target = target or now
        end
      end
      if together and target and not existing[target] then
        table.insert(moves, old .. ":" .. target)
      end
    end
  end

  where, existing = windows, ids
  if #moves > 0 then
    hl.exec_cmd("omaprojectspace renumber " .. table.concat(moves, " "))
  end
end

-- Omarchy renumbers right after the event that prompts it, so look a beat later.
local pending = nil
local function soon()
  if pending then pending:set_enabled(false) end
  pending = hl.timer(function()
    pending = nil
    follow()
  end, { timeout = 300, type = "oneshot" })
end

hl.on("window.move_to_workspace", function(window, workspace)
  if window and workspace and not workspace.special and workspace.id > 0 then
    where[window.address] = workspace.id
    existing[workspace.id] = true
  end
  soon()
end)

for _, event in ipairs({
  "window.open", "window.destroy", "workspace.created", "workspace.removed",
  "workspace.move_to_monitor", "monitor.added", "monitor.removed", "config.reloaded",
}) do
  hl.on(event, soon)
end

where, existing = look()

-- A project can be attached on more than one monitor: editors on one screen,
-- its chat or browser on the other. Bringing up one of its workspaces brings
-- up the others too, each on its own monitor. A monitor follows only when one
-- of its own workspaces is attached to that project and it shows none of them
-- yet, so nothing else on it is disturbed. Focus merely crossing to another
-- monitor isn't a switch, and doesn't count.
local config_dir = os.getenv("OMAPROJECTSPACE_CONFIG_DIR")
  or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/omaprojectspace"

-- Workspace id -> project home, read from the file the CLI keeps.
local function attachments()
  local file = io.open(config_dir .. "/attachments.json", "r")
  if not file then return {} end
  local text = file:read("a")
  file:close()
  local homes = {}
  local body = text:match('"workspaces"%s*:%s*(%b{})') or ""
  for id, home in body:gmatch('"(%d+)"%s*:%s*"([^"]*)"') do homes[tonumber(id)] = home end
  return homes
end

-- What each monitor shows, so a switch is told apart from a change of focus.
local shown = {}

local function remember()
  shown = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    if monitor.active_workspace then shown[monitor.name] = monitor.active_workspace.id end
  end
end

local function bring_project()
  local focused = hl.get_active_monitor()
  local workspace = focused and focused.active_workspace
  local switched = workspace and shown[focused.name] ~= workspace.id
  remember()
  if not switched or workspace.special or workspace.id < 1 then return end

  local homes = attachments()
  local home = homes[workspace.id]
  if not home then return end

  local moved = false
  for _, monitor in ipairs(hl.get_monitors()) do
    local active = monitor.active_workspace
    if monitor.name ~= focused.name and not monitor.is_mirror and not (active and homes[active.id] == home) then
      local base = o.workspaces.workspace_id(monitor, 1) - 1
      for slot = 1, o.workspaces.slots do
        if homes[base + slot] == home then
          o.workspaces.focus(slot, monitor.name)()
          moved = true
          break
        end
      end
    end
  end

  if moved then
    hl.dispatch(hl.dsp.focus({ monitor = focused.name }))
    remember()
  end
end

-- A beat later, so a switch that is part of a longer Omarchy action (moving a
-- workspace between monitors, an unplug) has finished first.
local bringing = nil
hl.on("workspace.active", function()
  if bringing then bringing:set_enabled(false) end
  bringing = hl.timer(function()
    bringing = nil
    bring_project()
  end, { timeout = 30, type = "oneshot" })
end)

remember()

-- Projectspaces (mehiel.omaprojectspace). Linked as ~/.config/hypr/omaprojectspace.lua
-- and required from hyprland.lua by `omaprojectspace install`.

-- The workspace panel: names, attachments, and what each projectspace sets.
o.bind("SUPER + ALT + P", "Projectspaces", "omarchy-shell mehiel.omaprojectspace toggle")

-- The stock browser binds hand URLs straight to a running Chrome, past the
-- uwsm-app shim. On an attached workspace this opens the projectspace's own
-- $BROWSER (its Chrome profile) instead; elsewhere it is the stock launcher.
o.rebind("SUPER + SHIFT + RETURN", "Browser", "omaprojectspace browser")
o.rebind("SUPER + SHIFT + B", "Browser", "omaprojectspace browser")

-- Windows: a snapshot every minute, so `omaprojectspace restore` (or the
-- panel's o key) can reopen the last session's windows after a login. A
-- config reload runs this file again; the old timer stops first.
if OMAPROJECTSPACE_SAVE_TIMER then OMAPROJECTSPACE_SAVE_TIMER:set_enabled(false) end
OMAPROJECTSPACE_SAVE_TIMER = hl.timer(function()
  hl.exec_cmd("omaprojectspace save --auto")
end, { timeout = 60000, type = "repeat" })

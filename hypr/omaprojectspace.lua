-- Projectspaces (mehiel.omaprojectspace). Linked as ~/.config/hypr/omaprojectspace.lua
-- and required from hyprland.lua by `omaprojectspace install`.

-- The workspace panel: names, attachments, and what each projectspace sets.
o.bind("SUPER + ALT + P", "Projectspaces", "omarchy-shell mehiel.omaprojectspace toggle")

-- The stock browser binds hand URLs straight to a running Chrome, past the
-- uwsm-app shim. On an attached workspace this opens the projectspace's own
-- $BROWSER (its Chrome profile) instead; elsewhere it is the stock launcher.
o.rebind("SUPER + SHIFT + RETURN", "Browser", "omaprojectspace browser")
o.rebind("SUPER + SHIFT + B", "Browser", "omaprojectspace browser")

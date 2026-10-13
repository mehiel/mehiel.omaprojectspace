# Design notes

How Projectspaces works, and why it works this way.

## The model

| Term | Meaning |
|---|---|
| Projectspace | A folder with a mise config at its root, one level under a root (default `~/Projects`). Its name is the folder name, or `PROJECTSPACE` from its env. |
| Projectspace home | That folder. Launches start in it, and `mise env` runs from it. |
| Attachment | A mapping from a workspace id (1–10) to a projectspace home. Optional: an unattached workspace behaves as stock. |

The filesystem defines projectspaces; nothing registers them. The only state
is the attachments file, `~/.config/omaprojectspace/attachments.json`.
`omaprojectspace` is its only writer, under a lock. The widget watches the
file and calls the CLI to change it.

Configuration belongs in mise, because the tools a team uses already read
their settings from the env: `CLAUDE_CONFIG_DIR`, `HERDR_SESSION`,
`AWS_PROFILE`, `BROWSER`. Projectspaces reads only `PROJECTSPACE`,
`PROJECTSPACE_COLOR` and `PROJECTSPACE_ICON`, and only to draw the bar.

## Getting the env into launches

Every Omarchy launch path goes through `uwsm-app`:
- the app launcher (`uwsm-app -- gtk-launch …`)
- `o.launch` keybinds
- `omarchy-launch-terminal`, `-tui`, `-editor` and `-webapp`

`uwsm-app` asks the app daemon for a `systemd-run --scope` command line and
`eval`s it in its own process. The launched app therefore inherits the
caller's env and working directory.

So the integration is a shim named `uwsm-app`, placed ahead of `/usr/bin` on
the session PATH (`~/.local/bin`). For each launch it:

1. asks Hyprland for the active workspace. A launch always lands there.
2. looks the workspace up in the attachments file;
3. exports `mise env --json` for that folder, plus `PROJECTSPACE` and
   `PROJECTSPACE_HOME`, and changes into the folder. When the terminal
   launcher passes `--dir=$HOME` (its fallback when there is no focused
   terminal), it rewrites that to the folder;
4. hands off to `/usr/bin/uwsm-app`.

`mise env` takes about 12ms, and the whole shim adds 20–35ms to a launch.

**The shim fails open.** A broken config, a missing folder or a bug still
launches the app, without the projectspace env. An EXIT trap execs the real
`uwsm-app` if anything goes wrong before the hand-off. Session daemons pass
straight through: hyprsunset, udiskie, the monitor watcher and the shell.
`OMAPROJECTSPACE=off` disables the shim for a launch.

Alternatives that were considered and rejected:
- Hyprland has no generic pre-exec hook, and patching `o.launch` covers only
  keybinds.
- `systemd --user` env and `hyprctl setenv` are global, not per workspace.
- Rewriting `.desktop` files is too much to maintain, and it misses terminals
  and keybinds.

### The browser

`omarchy-launch-browser` hands URLs straight to a running Chrome over its
singleton socket, so it never reaches `uwsm-app`. The browser keybinds call
`omaprojectspace browser` instead. It runs the projectspace's `$BROWSER` when
one is set, and falls back to the stock launcher otherwise.

## The widget

- `BarWidget.qml`: the strip, data loading and IPC. It extends the shell's
  `Panel`, the base class the first-party popups use.
- `PanelContent.qml`: the keyboard panel, built from the shell's `qs.Ui` kit
  (`CursorSurface` rows, `PanelHero`, `PanelKeyCatcher`), the same parts the
  first-party panels use.
- `Model.js`: pure logic (labels, colors, attachments, the strip, the cursor).
  It runs under QML and node and is tested in `tests/model.test.js`.

Colors: a projectspace without `PROJECTSPACE_COLOR` gets a slot in an
eight-color palette. The slot is its name's hash; on a collision it takes the
next free slot, assigned in folder order. Up to eight projectspaces never
share a color, and a color moves only when a new folder collides with it.
The palette does not come from the theme, because many themes are monochrome.

## Shell quirks worth knowing

- The shell launches apps through `bash -lc`, so the login profile's PATH
  must put `~/.local/bin` before `/usr/bin`. `doctor` checks this.
- Quickshell resolves a plugin file's sibling QML types only in folders its
  scanner indexed at startup. A new `.qml` file needs a shell restart.
- `ShellIpc` answers from the first enabled handler. Every monitor has its
  own widget instance, so only the instance on the focused monitor enables its
  handler. That is why Super+Alt+P opens the panel where you are.

## Open ideas

- **Per-projectspace webapps.** Example: a Slack webapp in each team's Chrome
  profile, declared in that team's mise config. This would cover
  single-instance apps that cannot switch env.
- **Default-browser routing.** Links clicked inside other apps would open in
  the team's browser. This means replacing the desktop's default browser, so
  it has to be opt-in.
- **A projectspace marker.** If one-level discovery ever turns out to be too
  broad, `PROJECTSPACE` in a folder's env can become the marker that makes it
  a projectspace.

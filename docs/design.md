# Design notes

How Projectspaces works, and why it works this way.

## The model

| Term | Meaning |
|---|---|
| Projectspace | A folder with a mise config at its root, one level under a root (default `~/Projects`). Its name is the folder name, or `PROJECTSPACE` from its env. |
| Projectspace home | That folder. Launches start in it, and `mise env` runs from it. |
| Attachment | A mapping from a workspace id to a projectspace home. Ids are Omarchy's: each monitor owns a block of ten (1–10, 11–20, …). Optional: an unattached workspace behaves as stock. |

The filesystem defines projectspaces; nothing registers them. The only state
is the attachments file, `~/.config/omaprojectspace/attachments.json`.
Besides the workspace map it holds one hand-edited key, `qconsole`: the
projectspace (or `"none"`) for launches while Omarchy's Quake console is open
on the focused monitor. A special workspace is never Hyprland's active one, so
the shim asks `hyprctl monitors` for it. Writes keep the key.
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

## Restoring windows

`save --ws N` runs only when asked, and writes workspace N's entry in
`~/.config/omaprojectspace/windows.json`, replacing the one before. It sits
with the attachments because it is setup you chose, not session state. An
earlier version saved every minute and restored "the last session"; that
brought back whatever happened to be open, so it went. The entry records how
to reopen each window, not the window itself:

- a terminal: its folder, and the argv of a herdr, tmux or zellij it runs;
- the browser: one per workspace;
- an app: its desktop entry. Omarchy writes `-Default` into every web app's
  `StartupWMClass`, while the window's class ends in its real profile, so a
  web app matches on the URL part and then on the `--profile-directory` in
  `Exec`.

`restore` opens one window at a time. For each, a temporary window rule
(`workspace = "N silent"`, `no_initial_focus`) catches the next window of
that class. The command runs through Hyprland's `exec_cmd` with
`OMAPROJECTSPACE_WORKSPACE=N`, so it gets the session's env and the shim adds
workspace N's projectspace. The rule is switched off as soon as the window
appears, or after 15 seconds. Hyprland's exec rules match by PID, which would
miss Chrome: a new Chrome window belongs to the Chrome process that is
already running.

Restoring at login is a widget setting. Every bar instance asks the CLI; the
CLI acts once per Hyprland instance (recorded in
`~/.local/state/omaprojectspace/login-restored`), and only in its first five
minutes.

## The widget

- `BarWidget.qml`: the strip, data loading and IPC. It extends the shell's
  `Panel`, the base class the first-party popups use.
- `PanelContent.qml`: the keyboard panel, built from the shell's `qs.Ui` kit
  (`CursorSurface` rows, `PanelHero`, `PanelKeyCatcher`), the same parts the
  first-party panels use. Two columns: the workspaces on the left, the
  selected one's projectspace, open windows and saved windows on the
  right. Below about 660 px the card stacks them. What is open comes from
  `windows --json` (Hyprland's clients, workspaces and monitors in one
  `hyprctl --batch`, named the way a snapshot names them), re-read on
  Hyprland's window events while the panel is open.
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
- A plugin rescan reloads the QML but can keep the old `Model.js`, which
  shows up as bindings quietly reading `null`. Restart the shell after
  changing it.
- Omarchy renumbers workspaces with `hl.dsp.workspace.change_id`, and
  Hyprland emits no event for that. `hypr/omaprojectspace.lua` keeps which
  workspace each window is on and looks again a beat after any event that
  can lead to a renumber (a workspace moving monitors, a monitor coming or
  going, a reload). A workspace that is gone, while all of its windows sit
  together on one that did not exist before, was renumbered; it calls
  `omaprojectspace renumber`. A window moved by hand updates the record as
  it moves, so emptying a workspace that way is never taken for one.
- A project attached on several monitors comes up on all of them: on
  `workspace.active`, `hypr/omaprojectspace.lua` reads `attachments.json`
  (a flat id -> home map, parsed with Lua patterns, since Hyprland's Lua has
  no JSON) and runs `o.workspaces.focus(slot, monitor)` on each other monitor
  that owns a workspace of the same home and shows none, then refocuses the
  monitor the switch happened on. It keeps what each monitor shows, so focus
  crossing monitors isn't taken for a switch, and it runs a beat after the
  event so a longer Omarchy action finishes first.

- The panel's screen tabs come from Omarchy's `monitor-workspaces` state
  file (`Model.parseScreens`), so a tab is a block of ten ids. `block` is
  the bar's own monitor, `shownBlock` the tab on view; rows, digits, the
  active row and going to a workspace all follow `shownBlock`, and going
  runs `o.workspaces.focus(slot, connector)` for that tab's monitor. An
  unplugged screen's ids exist only as attachments and names until it
  returns, so going to one is refused unless it is open somewhere as a
  guest. A project-first view (a row per project, a column per screen) was
  considered and set aside until there is some use of the tabs to go by.

- A Qt Quick TextField finishes editing on Return and then lets the key go
  on to its parents. Renaming ends in that same moment, which unblocks the
  PanelKeyCatcher, and it took the Return for "go" and closed the panel. The
  rename field takes Return and Enter itself; losing focus also saves, and
  a press anywhere else in the panel takes focus from it.

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

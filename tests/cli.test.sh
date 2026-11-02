#!/bin/bash
# shellcheck disable=SC2016  # stub scripts and sh -c bodies expand later, on purpose
# bash tests/cli.test.sh
# The CLI and the launch shim against a throwaway HOME, with mise, hyprctl,
# uwsm-app and omarchy-shell stubbed: no real session is touched.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=$REPO/bin/omaprojectspace
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

passes=0
failures=0

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == *"$expected"* ]]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    echo "FAIL $name"
    echo "     expected to contain: $expected"
    echo "     got: $actual"
  fi
}

refute() {
  local name=$1 unexpected=$2 actual=$3
  if [[ $actual != *"$unexpected"* ]]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    echo "FAIL $name"
    echo "     expected not to contain: $unexpected"
    echo "     got: $actual"
  fi
}

# ------------------------------------------------------------------ world

export HOME=$SANDBOX/home
mkdir -p "$HOME/Projects"/{acme,globex,plain} "$SANDBOX/bin" "$HOME/elsewhere/initech"
echo '[env]' >"$HOME/Projects/acme/mise.local.toml"
echo '[env]' >"$HOME/Projects/globex/mise.toml"
echo '[env]' >"$HOME/elsewhere/initech/mise.toml"
mkdir -p "$HOME/Projects/acme/app"

# mise: the env is whatever env.json sits in the folder it runs from;
# BROKEN makes it fail like an untrusted config.
cat >"$SANDBOX/bin/mise" <<'EOF'
#!/bin/bash
[[ $1 == env && $2 == --json ]] || exit 2
if [[ -f BROKEN ]]; then echo "mise ERROR Config files in $PWD/mise.toml are not trusted." >&2; exit 1; fi
if [[ -f env.json ]]; then cat env.json; else echo '{"GLOBAL":"1"}'; fi
EOF
# hyprctl: the active workspace is FAKE_ACTIVE_WS; windows are the JSON in
# FAKE_CLIENTS. eval and dispatch are logged, and a dispatch after a restore's
# window rule opens a window of the rule's class on its workspace (unless
# FAKE_NO_WINDOW), the way Hyprland would.
cat >"$SANDBOX/bin/hyprctl" <<'EOF'
#!/bin/bash
log=$HOME/hyprctl.log
[[ $1 == -j ]] && shift
case $1 in
clients) cat "${FAKE_CLIENTS:-/nonexistent}" 2>/dev/null || echo '[]' ;;
# clients; workspaces; monitors: one monitor, every workspace with windows on it.
--batch)
  clients=$(cat "${FAKE_CLIENTS:-/nonexistent}" 2>/dev/null || echo '[]')
  echo "$clients"
  jq '[.[].workspace.id | select(. > 0)] | unique | map({id: ., monitor: "DP-1", tiledLayout: "dwindle"})' <<<"$clients"
  echo '[{"name":"DP-1","x":0,"y":0,"width":2000,"height":1000,"scale":1,"transform":0,"reserved":[0,0,0,0]}]' ;;
# monitors: the focused one shows the Quake console when FAKE_QCONSOLE is set.
monitors) echo "[{\"name\":\"DP-1\",\"focused\":true,\"specialWorkspace\":{\"name\":\"${FAKE_QCONSOLE:+special:qconsole}\"}}]" ;;
instances) echo "[{\"instance\":\"${HYPRLAND_INSTANCE_SIGNATURE:-}\",\"pid\":${FAKE_HYPR_PID:-1}}]" ;;
eval)
  echo "eval $2" >>"$log"
  if [[ $2 =~ class\ =\ \[==\[\^\((.*)\)\$\]==\].*workspace\ =\ \'([0-9]+)\ silent\' ]]; then
    printf '%s\n%s\n' "$(sed 's/\\\(.\)/\1/g' <<<"${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}" >"$HOME/hyprctl.pending"
  fi
  echo ok ;;
dispatch)
  echo "dispatch $2" >>"$log"
  if [[ -z ${FAKE_NO_WINDOW:-} && -s $HOME/hyprctl.pending && -n ${FAKE_CLIENTS:-} ]]; then
    { read -r class; read -r ws; } <"$HOME/hyprctl.pending"
    : >"$HOME/hyprctl.pending"
    n=$(($(cat "$HOME/hyprctl.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$HOME/hyprctl.count"
    pid=$((4194100 + n))
    [[ $2 =~ --dir=([^] ]+) ]] && { mkdir -p "$HOME/cwd"; echo "${BASH_REMATCH[1]}" >"$HOME/cwd/$pid"; }
    jq --arg c "$class" --argjson ws "$ws" --argjson pid "$pid" \
      '. + [{address: ("0x" + ($pid | tostring)), class: $c, initialClass: $c, pid: $pid, workspace: {id: $ws}, mapped: true}]' \
      "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
  fi
  echo ok ;;
*) echo "{\"id\": ${FAKE_ACTIVE_WS:-1}}" ;;
esac
EOF
printf '#!/bin/sh\ncat "$HOME/cwd/$1" 2>/dev/null || echo "$HOME"\n' >"$SANDBOX/bin/omarchy-cmd-terminal-cwd"
cat >"$SANDBOX/bin/uwsm-app" <<'EOF'
#!/bin/bash
echo "cwd=$PWD"
echo "argv=$*"
env | grep -E '^(PROJECTSPACE|PROJECTSPACE_HOME|BROWSER|TEAM|OMAPROJECTSPACE_WORKSPACE)=' | sort
EOF
printf '#!/bin/sh\necho "$*" >>"$HOME/shell.log"\nexit 0\n' >"$SANDBOX/bin/omarchy-shell"
printf '#!/bin/sh\necho "stock browser $*"\n' >"$SANDBOX/bin/omarchy-launch-browser"
printf '#!/bin/sh\necho "notify $*" >>"$HOME/notifications"\n' >"$SANDBOX/bin/notify-send"
chmod +x "$SANDBOX/bin"/*

echo '{"GLOBAL":"1","TEAM":"acme","BROWSER":"chrome-acme","PROJECTSPACE_COLOR":"#ff8800"}' >"$HOME/Projects/acme/env.json"
echo '{"GLOBAL":"1","TEAM":"globex","PROJECTSPACE":"Globex Corp"}' >"$HOME/Projects/globex/env.json"

export PATH=$SANDBOX/bin:/usr/bin:/bin
export OMAPROJECTSPACE_REAL_UWSM_APP=$SANDBOX/bin/uwsm-app
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME OMAPROJECTSPACE_STATE_DIR OMAPROJECTSPACE_CONFIG_DIR PROJECTSPACE PROJECTSPACE_HOME OMAPROJECTSPACE OMAPROJECTSPACE_WORKSPACE TEAM BROWSER

run() { "$CLI" "$@" 2>&1; }

# ------------------------------------------------------------- discovery

out=$(run list --json)
check "list finds acme" '"name":"acme"' "$out"
check "list finds globex by its PROJECTSPACE name" '"name":"Globex Corp"' "$out"
refute "list skips folders without a mise config" '"plain"' "$out"
check "list reads the color" '"color":"#ff8800"' "$out"
check "list shows only what the projectspace adds" '"env":{"BROWSER":"chrome-acme","TEAM":"acme"}' "$out"
check "list has no attachments yet" '"attachments":{}' "$out"

# ------------------------------------------------------------ attachments

check "attach by name" "workspace 3 → acme" "$(run attach 3 acme)"
check "attachments are stored with ~" '"3": "~/Projects/acme"' "$(cat "$HOME/.config/omaprojectspace/attachments.json")"
check "attach by path outside the roots" "workspace 10 → initech" "$(run attach 10 ~/elsewhere/initech)"
check "attach takes a second monitor's workspace" "workspace 19 → acme" "$(run attach 19 acme)"
check "detach takes it too" "workspace 19 detached" "$(run detach 19)"
check "attach rejects workspace 0" "workspace must be a number from 1" "$(run attach 0 acme)"
check "attach rejects a name for a workspace" "workspace must be a number from 1" "$(run attach x acme)"
check "attach rejects unknown names" "no projectspace named 'nope'" "$(run attach 4 nope)"
check "attach rejects folders without mise" "not a projectspace" "$(run attach 4 ~/Projects/plain)"

out=$(run list --json)
check "list reports the attachment" '"workspaces":[3]' "$out"
check "list includes attached folders outside the roots" '"name":"initech"' "$out"

check "status of an attached workspace" "workspace 3: acme" "$(run status --ws 3)"
check "status of the active workspace" "workspace 3: acme" "$(FAKE_ACTIVE_WS=3 run status)"
check "status of a plain workspace" "workspace 5: no projectspace" "$(run status --ws 5)"
check "status json" '"workspace":3,"projectspace":{"name":"acme"' "$(run status --ws 3 --json)"

check "detach" "workspace 10 detached" "$(run detach 10)"
refute "detach removes it" '"10"' "$(cat "$HOME/.config/omaprojectspace/attachments.json")"

# -------------------------------------------------------------- env/exec

out=$(run env --ws 3)
check "env carries mise's env" "TEAM=acme" "$out"
check "env adds PROJECTSPACE" "PROJECTSPACE=acme" "$out"
check "env adds PROJECTSPACE_HOME" "PROJECTSPACE_HOME=$HOME/Projects/acme" "$out"
check "env by name" "TEAM=globex" "$(run env --name globex)"
check "env of a plain workspace fails" "has no projectspace" "$(run env --ws 5)"

out=$(run exec --ws 3 -- sh -c 'echo "$PWD $TEAM $PROJECTSPACE"')
check "exec runs in the home with the env" "$HOME/Projects/acme acme acme" "$out"

# ---------------------------------------------------------------- launch

out=$(FAKE_ACTIVE_WS=3 run launch -- -- gtk-launch app.desktop)
check "launch on an attached workspace: cwd" "cwd=$HOME/Projects/acme" "$out"
check "launch on an attached workspace: env" "TEAM=acme" "$out"
check "launch keeps uwsm-app's argv" "argv=-- gtk-launch app.desktop" "$out"

out=$(FAKE_ACTIVE_WS=3 run launch -- -- xdg-terminal-exec --dir="$HOME")
check "terminal fallback dir moves to the home" "argv=-- xdg-terminal-exec --dir=$HOME/Projects/acme" "$out"
out=$(FAKE_ACTIVE_WS=3 run launch -- -- xdg-terminal-exec --dir=/tmp)
check "terminal from another terminal keeps its dir" "argv=-- xdg-terminal-exec --dir=/tmp" "$out"

out=$(OMAPROJECTSPACE_WORKSPACE=3 FAKE_ACTIVE_WS=5 run launch -- -- foo)
check "a forced workspace picks the projectspace" "TEAM=acme" "$out"
refute "a forced workspace does not stick to the app" "OMAPROJECTSPACE_WORKSPACE" "$out"

out=$(FAKE_ACTIVE_WS=3 run launch -- -s a -T -- foo)
check "uwsm-app options pass through" "argv=-s a -T -- foo" "$out"
check "uwsm-app options still get the env" "TEAM=acme" "$out"

out=$(FAKE_ACTIVE_WS=5 PROJECTSPACE=stale PROJECTSPACE_HOME=/x run launch -- -- foo)
refute "a plain workspace drops a stale PROJECTSPACE" "PROJECTSPACE=" "$out"
check "a plain workspace launches from where it was" "cwd=$PWD" "$out"

out=$(FAKE_ACTIVE_WS=3 run launch -- -- hyprsunset)
refute "session daemons pass through" "TEAM=acme" "$out"
out=$(FAKE_ACTIVE_WS=3 OMAPROJECTSPACE_PASSTHROUGH=myd run launch -- -- /usr/bin/myd)
refute "extra passthrough by basename" "TEAM=acme" "$out"
out=$(FAKE_ACTIVE_WS=3 OMAPROJECTSPACE=off run launch -- -- foo)
refute "OMAPROJECTSPACE=off" "TEAM=acme" "$out"
out=$(FAKE_ACTIVE_WS=3 run launch -- stop)
check "non-launch uwsm-app calls pass through" "argv=stop" "$out"
out=$(OMAPROJECTSPACE_WORKSPACE=3 FAKE_ACTIVE_WS=5 run launch -- -- foo)
check "OMAPROJECTSPACE_WORKSPACE overrides the active workspace" "TEAM=acme" "$out"

# The Quake console: follows the workspace until the "qconsole" key says otherwise.
att=$HOME/.config/omaprojectspace/attachments.json
out=$(FAKE_QCONSOLE=1 FAKE_ACTIVE_WS=3 run launch -- -- foo)
check "the console follows the workspace by default" "TEAM=acme" "$out"
jq '. + {qconsole: "none"}' "$att" >"$att.tmp" && mv "$att.tmp" "$att"
out=$(FAKE_QCONSOLE=1 FAKE_ACTIVE_WS=3 PROJECTSPACE=stale run launch -- -- foo)
refute "qconsole none: no projectspace env" "TEAM=acme" "$out"
refute "qconsole none: drops a stale PROJECTSPACE" "PROJECTSPACE=" "$out"
check "qconsole none: still launches" "argv=-- foo" "$out"
out=$(FAKE_ACTIVE_WS=3 run launch -- -- foo)
check "qconsole only applies while the console is open" "TEAM=acme" "$out"
out=$(FAKE_QCONSOLE=1 OMAPROJECTSPACE_WORKSPACE=3 run launch -- -- foo)
check "a launch pinned to a workspace ignores the console" "TEAM=acme" "$out"
jq '.qconsole = "~/Projects/globex"' "$att" >"$att.tmp" && mv "$att.tmp" "$att"
out=$(FAKE_QCONSOLE=1 FAKE_ACTIVE_WS=3 run launch -- -- foo)
check "qconsole home: that projectspace's env" "TEAM=globex" "$out"
run attach 4 acme >/dev/null
check "attach keeps the qconsole key" '"qconsole": "~/Projects/globex"' "$(cat "$att")"
run detach 4 >/dev/null
jq 'del(.qconsole)' "$att" >"$att.tmp" && mv "$att.tmp" "$att"

touch "$HOME/Projects/acme/BROKEN"
out=$(FAKE_ACTIVE_WS=3 run launch -- -- foo)
check "a failing mise still launches" "argv=-- foo" "$out"
refute "a failing mise launches without the env" "TEAM=acme" "$out"
check "a failing mise notifies" "not trusted" "$(cat "$HOME/notifications")"
rm "$HOME/Projects/acme/BROKEN"

echo '{"1BAD":"x","TEAM":"acme"}' >"$HOME/Projects/acme/env.json"
out=$(FAKE_ACTIVE_WS=3 run launch -- -- foo)
check "keys that are not identifiers are skipped" "TEAM=acme" "$out"

run attach 6 globex >/dev/null
rm -rf "$HOME/Projects/globex"
out=$(FAKE_ACTIVE_WS=6 run launch -- -- foo)
check "a vanished home still launches" "argv=-- foo" "$out"
check "a vanished home notifies" "no longer exists" "$(cat "$HOME/notifications")"
check "list marks a vanished attachment" '"6":{"home":"'"$HOME"'/Projects/globex","name":null,"missing":true}' "$(run list --json)"

# --------------------------------------------------------------- browser

# The real launch is uwsm-app → `omaprojectspace exec` → $BROWSER; the stub
# uwsm-app runs its argv so the whole chain is exercised.
cat >"$SANDBOX/bin/uwsm-app-run" <<'EOF2'
#!/bin/bash
[[ $1 == -- ]] && shift
exec "$@"
EOF2
printf '#!/bin/sh\necho "chrome-acme from $PWD with $*"\n' >"$SANDBOX/bin/chrome-acme"
chmod +x "$SANDBOX/bin/uwsm-app-run" "$SANDBOX/bin/chrome-acme"
echo '{"GLOBAL":"1","TEAM":"acme","BROWSER":"chrome-acme"}' >"$HOME/Projects/acme/env.json"
out=$(FAKE_ACTIVE_WS=3 OMAPROJECTSPACE_REAL_UWSM_APP=$SANDBOX/bin/uwsm-app-run run browser https://example.com)
check "browser opens the projectspace's \$BROWSER from its home" "chrome-acme from $HOME/Projects/acme with https://example.com" "$out"
out=$(FAKE_ACTIVE_WS=5 run browser https://example.com)
check "browser elsewhere is the stock launcher" "stock browser https://example.com" "$out"
echo '{"GLOBAL":"1","TEAM":"acme"}' >"$HOME/Projects/acme/env.json"
out=$(FAKE_ACTIVE_WS=3 run browser)
check "browser on a projectspace without \$BROWSER is the stock launcher" "stock browser" "$out"

# --------------------------------------------------------------- windows

export OMAPROJECTSPACE_APPLICATIONS=$SANDBOX/apps
export FAKE_CLIENTS=$SANDBOX/clients.json
export FAKE_HYPR_PID=$$
export OMAPROJECTSPACE_RESTORE_TIMEOUT=2
mkdir -p "$SANDBOX/apps" "$HOME/cwd"
desktop() { printf '[Desktop Entry]\nName=%s\nExec=%s\nStartupWMClass=%s\n' "$2" "$3" "$4" >"$SANDBOX/apps/$1"; }
# Omarchy writes -Default into every web app's StartupWMClass, whatever
# profile its Exec opens.
desktop "Slack A.desktop" "Slack A" 'omarchy-launch-webapp "https://slack.example.com/" --profile-directory="Profile 1"' chrome-slack.example.com__-Default
desktop "Slack B.desktop" "Slack B" 'omarchy-launch-webapp "https://slack.example.com/" --profile-directory="Profile 2"' chrome-slack.example.com__-Default
desktop "notes.desktop" "Notes" notes ""
client() { jq -nc --arg c "$1" --argjson ws "$2" --argjson pid "$3" '{address: ("0x" + ($pid | tostring)), class: $c, initialClass: $c, pid: $pid, workspace: {id: $ws}, mapped: true, title: ($c + " title"), at: [0, 0], size: [1000, 1000], floating: false, fullscreen: 0, focusHistoryID: 0}'; }
{
  client foot 3 4194001
  client google-chrome 3 4194002
  client google-chrome 3 4194002
  client chrome-slack.example.com__-Profile_2 3 4194002
  client notes 4 4194003
  client mystery 5 4194004
  client foot -98 4194005
} | jq -s . >"$FAKE_CLIENTS"
echo "$HOME/Projects/acme" >"$HOME/cwd/4194001"
cp "$FAKE_CLIENTS" "$SANDBOX/clients.full.json"
STATE=$HOME/.local/state/omaprojectspace
SAVED=$HOME/.config/omaprojectspace/windows.json
export OMAPROJECTSPACE_INSTANCE=B

check "windows before any save" "No saved windows yet" "$(run windows)"
check "windows json before any save" '{"workspaces":[],"live":' "$(run windows --json)"
check "restore with nothing saved" "no workspace has saved windows" "$(run restore)"

out=$(run save --ws 3)
check "save counts what it can reopen on that workspace" "Saved 3 windows on workspace 3." "$out"
snap=$(jq -c '.workspaces["3"]' "$SAVED")
check "save records the projectspace" '"projectspace":"~/Projects/acme"' "$snap"
check "save records a terminal's folder" '"dir":"~/Projects/acme"' "$snap"
check "save keeps one browser per workspace" '1' "$(jq '[.windows[] | select(.kind == "browser")] | length' <<<"$snap")"
check "a web app matches its profile's entry" '"desktop":"Slack B.desktop"' "$snap"
refute "save leaves other workspaces alone" '"4"' "$(jq -c '.workspaces | keys' "$SAVED")"
check "save defaults to the active workspace" "Saved 1 window on workspace 4." "$(FAKE_ACTIVE_WS=4 run save)"
check "an app matches its entry by id" '"desktop":"notes.desktop"' "$(jq -c '.workspaces["4"]' "$SAVED")"
check "save names what it cannot reopen" "nothing to save on workspace 5" "$(run save --ws 5)"
check "and names the windows it cannot reopen" "no desktop entry reopens mystery" "$(run save --ws 5)"
check "an empty workspace has nothing to save" "it has no windows" "$(run save --ws 9)"
refute "a workspace with nothing reopenable is not saved" '"5"' "$(jq -c '.workspaces | keys' "$SAVED")"
check "save rejects workspace 0" "workspace must be a number from 1" "$(run save --ws 0)"
check "saving is on demand: no session files" "" "$(ls "$STATE" 2>/dev/null | grep -E 'session' || true)"

check "everything open: nothing to restore" "already open" "$(run restore)"
check "windows marks what is open" "· open  Browser" "$(run windows)"

jq '[.[] | select(.class != "foot" and (.class | startswith("chrome-slack") | not))]' "$SANDBOX/clients.full.json" >"$FAKE_CLIENTS"
out=$(run windows)
check "windows marks a closed terminal" "○ Terminal · ~/Projects/acme" "$out"
check "windows marks a closed web app" "○ Slack B" "$out"
check "windows says when it was saved" "workspace 3  ~/Projects/acme  (saved " "$out"
out=$(run windows --json)
check "the plan counts what is missing" '"missing":2' "$out"
check "each workspace says when it was saved" 'true' "$(jq '.workspaces[0].saved > 0' <<<"$out")"
check "windows json has what is open now, with the layout" '"layout":"dwindle"' "$(jq -c '.live["3"]' <<<"$out")"
check "and the monitor" '"name":"DP-1"' "$(jq -c '.live["3"].monitor' <<<"$out")"
check "open windows carry geometry, title and their saved name" '"title":"google-chrome title","at":[0,0],"size":[1000,1000]' "$(jq -c '.live["3"].windows[] | select(.kind == "browser")' <<<"$out" | head -1)"
check "a window nothing can reopen is still listed as open" '"name":"mystery"' "$(jq -c '.live["5"].windows[0]' <<<"$out")"
out=$(run restore --dry-run)
check "dry run lists the terminal" "workspace 3: Terminal · ~/Projects/acme" "$out"
check "dry run lists the web app" "workspace 3: Slack B" "$out"
check "dry run opens nothing" "0" "$(jq length <<<"$(grep -c dispatch "$HOME/hyprctl.log" 2>/dev/null || echo 0)")"

: >"$HOME/hyprctl.log"
out=$(run restore --ws 3)
check "restore opens the terminal" "✓ workspace 3: Terminal · ~/Projects/acme" "$out"
check "restore opens the web app" "✓ workspace 3: Slack B" "$out"
log=$(cat "$HOME/hyprctl.log")
check "restore places windows silently on their workspace" "workspace = '3 silent', no_initial_focus = true" "$log"
check "restore escapes the class for the rule" 'chrome-slack\.example\.com__-Profile_2' "$log"
check "restore launches through the shim with the workspace" "OMAPROJECTSPACE_WORKSPACE=3 $REPO/shim/uwsm-app -- xdg-terminal-exec --dir=$HOME/Projects/acme" "$log"
check "restore opens web apps from their entry" 'gtk-launch Slack\ B.desktop' "$log"
check "restore drops the rule afterwards" "t.rule:set_enabled(false); t.rule = nil" "$(tail -1 "$HOME/hyprctl.log")"
check "restored windows count as open" "already open" "$(run restore)"

jq '[.[] | select(.class != "foot")]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
out=$(FAKE_NO_WINDOW=1 run restore --notify)
check "a window that never shows up fails" "✗ workspace 3: Terminal · ~/Projects/acme (no window after 2s)" "$out"
check "and the rule still goes" "t.rule = nil" "$(tail -1 "$HOME/hyprctl.log")"
check "restore --notify reports" "Windows restored" "$(tail -1 "$HOME/notifications")"
check "restore rejects workspace 0" "workspace must be a number from 1" "$(run restore --ws 0)"

jq '[.[] | if .class == "notes" then .workspace.id = 6 else . end]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
check "an app open elsewhere is not opened twice" "· open on 6  Notes" "$(run windows)"
refute "and restore leaves it" "Notes" "$(FAKE_NO_WINDOW=1 run restore)"

# Login: once per session, and only right after it started.
check "login restore outside the login window does nothing" "" "$(OMAPROJECTSPACE_LOGIN_WINDOW=0 run restore --login)"
refute "and opens nothing" "✓" "$(OMAPROJECTSPACE_LOGIN_WINDOW=0 run restore --login)"
check "login restore right after login" "✓ workspace 3: Terminal" "$(OMAPROJECTSPACE_LOGIN_WINDOW=100000 run restore --login)"
check "login restore marks the session" 'B' "$(cat "$STATE/login-restored")"
jq '[.[] | select(.class != "foot")]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
refute "login restore runs once per session" "✓" "$(OMAPROJECTSPACE_LOGIN_WINDOW=100000 run restore --login)"
check "a new session restores at login again" "✓ workspace 3: Terminal" "$(OMAPROJECTSPACE_INSTANCE=C OMAPROJECTSPACE_LOGIN_WINDOW=100000 run restore --login)"

# Save again replaces; forget drops.
cp "$SANDBOX/clients.full.json" "$FAKE_CLIENTS"
jq '[.[] | select(.class != "google-chrome")]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
run save --ws 3 >/dev/null
refute "saving again replaces the setup" '"kind":"browser"' "$(jq -c '.workspaces["3"]' "$SAVED")"
check "forget drops a workspace's save" "Forgot workspace 3" "$(run forget --ws 3)"
check "and only that one" '["4"]' "$(jq -c '.workspaces | keys' "$SAVED")"
unset OMAPROJECTSPACE_INSTANCE FAKE_CLIENTS

# ------------------------------------------------------------- renumber
# Omarchy moves a workspace into another monitor's block of ten under a new id.

ATT=$HOME/.config/omaprojectspace/attachments.json
run attach 9 acme >/dev/null
: >"$HOME/shell.log"
check "renumber reports the move" "workspace 9 → 19" "$(run renumber 9:19)"
check "the attachment follows" '"19":"~/Projects/acme"' "$(jq -c .workspaces "$ATT")"
refute "and leaves the old id" '"9":' "$(jq -c .workspaces "$ATT")"
check "the bar is told, to carry names" "mehiel.omaprojectspace renumber 9:19" "$(cat "$HOME/shell.log")"
run attach 9 ~/elsewhere/initech >/dev/null
run renumber 9:19 >/dev/null
check "a displaced attachment takes the freed id" '"9":"~/Projects/acme"' "$(jq -c .workspaces "$ATT")"
check "and the newcomer its new one" '"19":"~/elsewhere/initech"' "$(jq -c .workspaces "$ATT")"
run renumber 9:19 19:9 >/dev/null
check "a trade swaps them back" '"19":"~/Projects/acme"' "$(jq -c .workspaces "$ATT")"
run detach 9 >/dev/null
run renumber 9:19 >/dev/null
check "an unattached workspace lands unattached; what sat there takes its old id" '"9":"~/Projects/acme"' "$(jq -c .workspaces "$ATT")"
refute "and the new id has no attachment" '"19":' "$(jq -c .workspaces "$ATT")"
run renumber 9:19 >/dev/null
check "saved windows follow too" '["14"]' "$(run renumber 4:14 >/dev/null; jq -c '.workspaces | keys' "$SAVED")"
check "renumbering nothing attached changes nothing" '"19":"~/Projects/acme"' "$(run renumber 5:15 >/dev/null; jq -c .workspaces "$ATT")"
check "renumber rejects junk" "renumber takes <from>:<to>" "$(run renumber 9-19)"
check "renumber rejects two onto one" "two workspaces onto one id" "$(run renumber 8:19 9:19)"
check "renumber to the same id is a no-op" "" "$(run renumber 9:9)"

# ---------------------------------------------------------------- shim

mkdir -p "$SANDBOX/shimtest/shim" "$SANDBOX/shimtest/bin"
cp "$REPO/shim/uwsm-app" "$SANDBOX/shimtest/shim/"
printf '#!/bin/bash\necho "cli $*"\n' >"$SANDBOX/shimtest/bin/omaprojectspace"
chmod +x "$SANDBOX/shimtest/bin/omaprojectspace"
check "the shim hands off to its repo's CLI" "cli launch -- -- foo" "$("$SANDBOX/shimtest/shim/uwsm-app" -- foo 2>&1)"
rm "$SANDBOX/shimtest/bin/omaprojectspace"
check "the shim without a CLI is plain uwsm-app" "argv=-- foo" "$("$SANDBOX/shimtest/shim/uwsm-app" -- foo 2>&1)"

echo "$passes passed, $failures failed"
((failures == 0))

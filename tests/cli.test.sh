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
case $1 in
clients) cat "${FAKE_CLIENTS:-/nonexistent}" 2>/dev/null || echo '[]' ;;
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
printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/omarchy-shell"
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
check "attach rejects workspace 11" "workspace must be 1-10" "$(run attach 11 acme)"
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
client() { jq -nc --arg c "$1" --argjson ws "$2" --argjson pid "$3" '{address: ("0x" + ($pid | tostring)), class: $c, initialClass: $c, pid: $pid, workspace: {id: $ws}, mapped: true}'; }
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

check "windows before any session" "No previous session saved yet" "$(run windows)"
check "windows json before any session" '{"saved":null,"workspaces":[],"current":null' "$(run windows --json)"

out=$(OMAPROJECTSPACE_INSTANCE=A run save)
check "save counts what it can reopen" "Saved 4 windows on workspaces 3, 4." "$out"
check "save names what it cannot" "can't reopen mystery on workspace 5" "$out"
snap=$(cat "$STATE/session.json")
check "save records the session" '"instance":"A"' "$snap"
check "save records the projectspace" '"projectspace":"~/Projects/acme"' "$snap"
check "save records a terminal's folder" '"dir":"~/Projects/acme"' "$snap"
check "save keeps one browser per workspace" '1' "$(jq '[.workspaces["3"].windows[] | select(.kind == "browser")] | length' <<<"$snap")"
check "a web app matches its profile's entry" '"desktop":"Slack B.desktop"' "$snap"
check "an app matches its entry by id" '"desktop":"notes.desktop"' "$snap"
refute "special workspaces are left out" '"-98"' "$snap"
check "the same session overwrites in place" "session.json" "$(OMAPROJECTSPACE_INSTANCE=A run save --auto; ls "$STATE")"
refute "the same session never rotates" "last-session.json" "$(ls "$STATE")"

OMAPROJECTSPACE_INSTANCE=B run save --auto
check "a new session keeps the old one as the last" '"instance":"A"' "$(cat "$STATE/last-session.json")"
check "and starts its own" '"instance":"B"' "$(cat "$STATE/session.json")"
check "windows reports this session's snapshot" '"windows":4,"workspaces":2}' "$(OMAPROJECTSPACE_INSTANCE=B run windows --json)"
check "a snapshot from another session is not this one's" '"current":null' "$(OMAPROJECTSPACE_INSTANCE=C run windows --json)"

export OMAPROJECTSPACE_INSTANCE=B
check "everything open: nothing to restore" "already open" "$(run restore)"
check "windows marks what is open" "· open  Browser" "$(run windows)"

jq '[.[] | select(.class != "foot" and (.class | startswith("chrome-slack") | not))]' "$SANDBOX/clients.full.json" >"$FAKE_CLIENTS"
out=$(run windows)
check "windows marks a closed terminal" "○ Terminal · ~/Projects/acme" "$out"
check "windows marks a closed web app" "○ Slack B" "$out"
check "the plan counts what is missing" '"missing":2' "$(run windows --json)"
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
check "restore rejects workspace 11" "workspace must be 1-10" "$(run restore --ws 11)"

jq '[.[] | if .class == "notes" then .workspace.id = 6 else . end]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
check "an app open elsewhere is not opened twice" "· open on 6  Notes" "$(run windows)"
refute "and restore leaves it" "Notes" "$(FAKE_NO_WINDOW=1 run restore)"

# Login: once per session, and only right after it started.
check "login restore outside the login window does nothing" "" "$(OMAPROJECTSPACE_LOGIN_WINDOW=0 run restore --login)"
refute "and opens nothing" "✓" "$(OMAPROJECTSPACE_LOGIN_WINDOW=0 run restore --login)"
check "login restore right after login" "✓ workspace 3: Terminal" "$(OMAPROJECTSPACE_LOGIN_WINDOW=100000 run restore --login)"
check "login restore marks the session" 'B' "$(jq -r .restored_instance "$STATE/last-session.json")"
jq '[.[] | select(.class != "foot")]' "$FAKE_CLIENTS" >"$FAKE_CLIENTS.tmp" && mv "$FAKE_CLIENTS.tmp" "$FAKE_CLIENTS"
refute "login restore runs once per session" "✓" "$(OMAPROJECTSPACE_LOGIN_WINDOW=100000 run restore --login)"

# Logging out closes every window before Hyprland exits.
echo '[]' >"$FAKE_CLIENTS"
run save --auto
check "an automatic save of no windows keeps the snapshot" '"kind":"browser"' "$(cat "$STATE/session.json")"
check "a manual save of no windows clears it" "Saved 0 windows." "$(run save)"
OMAPROJECTSPACE_INSTANCE=C run save --auto
check "an empty session never replaces the last one" 'A' "$(jq -r .instance "$STATE/last-session.json")"
unset OMAPROJECTSPACE_INSTANCE FAKE_CLIENTS

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

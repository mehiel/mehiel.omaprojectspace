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
cat >"$SANDBOX/bin/hyprctl" <<'EOF'
#!/bin/bash
echo "{\"id\": ${FAKE_ACTIVE_WS:-1}}"
EOF
cat >"$SANDBOX/bin/uwsm-app" <<'EOF'
#!/bin/bash
echo "cwd=$PWD"
echo "argv=$*"
env | grep -E '^(PROJECTSPACE|PROJECTSPACE_HOME|BROWSER|TEAM)=' | sort
EOF
printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/omarchy-shell"
printf '#!/bin/sh\necho "stock browser $*"\n' >"$SANDBOX/bin/omarchy-launch-browser"
printf '#!/bin/sh\necho "notify $*" >>"$HOME/notifications"\n' >"$SANDBOX/bin/notify-send"
chmod +x "$SANDBOX/bin"/*

echo '{"GLOBAL":"1","TEAM":"acme","BROWSER":"chrome-acme","PROJECTSPACE_COLOR":"#ff8800"}' >"$HOME/Projects/acme/env.json"
echo '{"GLOBAL":"1","TEAM":"globex","PROJECTSPACE":"Globex Corp"}' >"$HOME/Projects/globex/env.json"

export PATH=$SANDBOX/bin:/usr/bin:/bin
export OMAPROJECTSPACE_REAL_UWSM_APP=$SANDBOX/bin/uwsm-app
unset XDG_CONFIG_HOME PROJECTSPACE PROJECTSPACE_HOME OMAPROJECTSPACE OMAPROJECTSPACE_WORKSPACE TEAM BROWSER

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

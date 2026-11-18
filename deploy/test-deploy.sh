#!/usr/bin/env bash
# test-deploy.sh — end-to-end tests for deploy.sh using a fake ssh on the local machine (no real remote needed)
#
# Usage:
#   ./test-deploy.sh                       # test deploy.sh with whichever of bash/dash/zsh/fish is on PATH as login shell
#   SHELLS="bash dash" ./test-deploy.sh    # choose the remote login shells to test
#   DEPLOY_BASH="bash --posix" ./test-deploy.sh   # run deploy.sh itself with the given bash
#   DEPLOY=/path/to/deploy.sh ./test-deploy.sh
#
# The fake ssh skips options such as -t/-o/-p/-i/-l, takes the host name, joins the remaining
# arguments with spaces (as real ssh does) and runs them with $FAKE_SHELL -c in a fake remote home.
# rsync's -e calls this fake ssh too, so syncing also runs end to end locally.

# shellcheck disable=SC2016 # test data is single-quoted on purpose; $vars must reach the remote verbatim
# shellcheck disable=SC2088 # ~ is written verbatim into the config, for the remote to expand
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${DEPLOY:-$HERE/deploy.sh}"
read -r -a DEPLOY_BASH_CMD <<<"${DEPLOY_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-deploy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------- fake ssh ----------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
G=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o | -p | -i | -l) shift 2 ;;
  -G)
    G=1
    shift
    ;;
  -*) shift ;;
  *)
    shift # host name
    break
    ;;
  esac
done
# ssh -G: print the contents of $FAKE_SSH_G as the config; print nothing if unset (deploy then skips the host key check)
if ((G)); then
  [[ -n "${FAKE_SSH_G:-}" ]] && cat "$FAKE_SSH_G"
  exit 0
fi
export HOME="$FAKE_REMOTE_HOME"
cd "$HOME" || exit 255
exec "${FAKE_SHELL:-bash}" -c "$*"
EOF
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

if [[ -z "${SHELLS:-}" ]]; then
  SHELLS=""
  for s in bash dash zsh fish; do command -v "$s" >/dev/null && SHELLS+="$s "; done
fi

PASS=0
FAIL=0
RESULTS=()

# Each case: a fresh fake remote home and local project
setup() {
  REMOTE_HOME="$WORK/remote-$1-$FAKE_SHELL"
  PROJ="$WORK/proj-$1-$FAKE_SHELL/myproj"
  rm -rf "$REMOTE_HOME" "${PROJ%/*}"
  mkdir -p "$REMOTE_HOME" "$PROJ"
  echo hello >"$PROJ/hello.txt"
  export FAKE_REMOTE_HOME="$REMOTE_HOME"
  # write via the config file, which also tests sourced values
  printf 'HOST=fakehost\nREMOTE_DIR=%q\n' '~/app' >"$PROJ/.deploy.conf"
}
conf() { printf '%s=%q\n' "$1" "$2" >>"$PROJ/.deploy.conf"; }

# Run deploy; results go to $OUT and $RC
run_deploy() {
  OUT="$(cd "$PROJ" && env -u DEPLOY_HOST XDG_CONFIG_HOME="$WORK/xdg" \
    "${DEPLOY_BASH_CMD[@]}" "$DEPLOY" "$@" 2>&1)"
  RC=$?
}

check() { # check NAME RESULT(0/1) DETAIL_ON_FAILURE
  local name="$1" ok="$2" why="$3"
  if [[ "$ok" == 0 ]]; then
    PASS=$((PASS + 1))
    RESULTS+=("PASS|$FAKE_SHELL|$name|")
    printf '  \033[32mPASS\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    RESULTS+=("FAIL|$FAKE_SHELL|$name|$why")
    printf '  \033[31mFAIL\033[0m %s — %s\n' "$name" "$why"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
  fi
}

# Whole-line match: avoids matching deploy's own "running on remote: <cmd>" line
has() { grep -qxF -- "$1" <<<"$OUT"; }
has_in() { grep -qxF -- "$2" <<<"$1"; }
wait_for() { # wait_for FILE STRING: wait up to 10 s
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_file() { # wait_file FILE: wait up to 10 s
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

RUN8='greet="世界"
echo "你好 $greet"
echo '"'"'single "dq" $notexpanded'"'"'
echo "home=$HOME"
cat <<'"'"'EOF'"'"'
heredoc 中文 $x
EOF'

check8() { # is case 8's output correct? ($1 is the text to check)
  local t="$1"
  has_in "$t" "你好 世界" && has_in "$t" 'single "dq" $notexpanded' &&
    has_in "$t" "home=$REMOTE_HOME" && has_in "$t" 'heredoc 中文 $x'
}

for FAKE_SHELL in $SHELLS; do
  export FAKE_SHELL
  echo "== remote login shell: $FAKE_SHELL"

  setup 1
  conf STOP_CMD 'touch stopped # comment'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/stopped" ]] && has ran
  check "1 STOP ends with a comment" $? "rc=$RC"

  setup 2
  conf STOP_CMD $'touch s1\ntouch s2\n'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/s1" && -f "$REMOTE_HOME/app/s2" ]] && has ran
  check "2 STOP multi-line (trailing newline)" $? "rc=$RC"

  setup 3
  conf STOP_CMD 'touch s3;'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/s3" ]] && has ran
  check "3 STOP ends with ;" $? "rc=$RC"

  setup 4
  conf STOP_CMD 'touch s4 &'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran && wait_file "$REMOTE_HOME/app/s4"
  check "4 STOP ends with &" $? "rc=$RC"

  setup 5a
  conf STOP_CMD 'false'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "5a STOP fails (false)" $? "rc=$RC"

  setup 5b
  conf STOP_CMD 'exit 1'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "5b STOP fails (exit 1)" $? "rc=$RC"

  setup 6
  conf RUN_CMD $'set -e\necho step1\nfalse\necho step2'
  run_deploy
  [[ $RC != 0 ]] && has step1 && ! has step2
  check "6 RUN multi-line set -e fails midway" $? "rc=$RC"

  setup 7
  conf RUN_CMD 'echo a; exit 3'
  run_deploy
  [[ $RC == 3 ]] && has a
  check "7 RUN exit 3 → deploy exits 3" $? "rc=$RC"

  setup 8
  conf RUN_CMD "$RUN8"
  run_deploy
  [[ $RC == 0 ]] && check8 "$OUT"
  check "8 RUN non-ASCII/quotes/\$vars/heredoc" $? "rc=$RC"

  setup 9
  conf RUN_CMD "$RUN8"$'\nsleep 5'
  conf BACKGROUND 1
  start=$SECONDS
  run_deploy
  took=$((SECONDS - start))
  [[ $RC == 0 && $took -lt 4 ]] && wait_for "$REMOTE_HOME/app/deploy.log" 'heredoc 中文' &&
    check8 "$(cat "$REMOTE_HOME/app/deploy.log")"
  check "9 background mode (correct log, returns at once)" $? "rc=$RC took=${took}s log=$(cat "$REMOTE_HOME/app/deploy.log" 2>/dev/null | tr '\n' '/')"

  setup 10
  : >"$REMOTE_HOME/blocker" # a regular file in the way makes mkdir -p fail
  printf 'REMOTE_DIR=%q\n' '~/blocker/sub' >>"$PROJ/.deploy.conf"
  conf STOP_CMD 'touch STOP_RAN'
  conf RUN_CMD 'touch RUN_RAN'
  run_deploy
  found="$(find "$REMOTE_HOME" -name '*_RAN' | tr '\n' ' ')"
  ok=1
  [[ $RC != 0 && -z "$found" ]] && ok=0
  check "10 remote dir cannot be created → nothing runs" "$ok" "rc=$RC found=$found"

  # 10b: cd fails (STOP deletes the remote dir); RUN's second command must not run in the wrong dir either
  setup 10b
  conf STOP_CMD 'cd ~ && rm -rf ~/app'
  conf RUN_CMD 'touch RUN_RAN_A; touch RUN_RAN_B'
  run_deploy
  found="$(find "$REMOTE_HOME" -name 'RUN_RAN_*' | tr '\n' ' ')"
  [[ $RC != 0 && -z "$found" ]]
  check "10b cd fails → neither a nor b of RUN runs" $? "rc=$RC found=$found"

  setup 11
  printf 'REMOTE_DIR=%q\n' '~/my app' >>"$PROJ/.deploy.conf"
  conf RUN_CMD 'pwd'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/my app/hello.txt" ]] && has "$REMOTE_HOME/my app"
  check "11 REMOTE_DIR with spaces" $? "rc=$RC"

  setup 12
  conf RUN_CMD 'echo bg'
  conf BACKGROUND 1
  run_deploy
  wait_for "$REMOTE_HOME/app/deploy.log" bg
  run_deploy -s
  [[ $RC == 0 && -f "$REMOTE_HOME/app/deploy.log" ]]
  check "12 redeploy keeps deploy.log" $? "rc=$RC"

  # Extra: EXCLUDES set to an empty array (empty arrays break set -u on bash 3.2)
  setup 13
  conf RUN_CMD 'echo ran'
  echo 'EXCLUDES=()' >>"$PROJ/.deploy.conf"
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "13 EXCLUDES=() empty array" $? "rc=$RC"
done

# ---------- host key check (independent of the remote shell; runs once) ----------
# setsid leaves deploy without a controlling terminal (simulating cron / CI / an agent)
if command -v setsid >/dev/null && command -v ssh-keygen >/dev/null; then
  export FAKE_SHELL=bash
  echo "== host key check"
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey"
  KH="$WORK/known_hosts"
  printf 'fakehost %s\n10.0.0.9 %s\n' "$(cut -d' ' -f1,2 "$WORK/hostkey.pub")" \
    "$(cut -d' ' -f1,2 "$WORK/hostkey.pub")" >"$KH"
  export FAKE_SSH_G="$WORK/ssh-G"
  ssh_g() { # ssh_g hostname [more ssh -G lines...]
    printf 'hostname %s\nport 22\nstricthostkeychecking ask\n' "$1" >"$FAKE_SSH_G"
    printf 'userknownhostsfile %s\nglobalknownhostsfile %s\n' "$KH" "$WORK/none" >>"$FAKE_SSH_G"
    shift
    if (($#)); then printf '%s\n' "$@" >>"$FAKE_SSH_G"; fi
  }
  run_notty() { # run deploy without a terminal
    OUT="$(cd "$PROJ" && env -u DEPLOY_HOST XDG_CONFIG_HOME="$WORK/xdg" \
      setsid -w "${DEPLOY_BASH_CMD[@]}" "$DEPLOY" 2>&1 </dev/null)"
    RC=$?
  }

  setup 14a
  conf RUN_CMD 'echo ran'
  ssh_g fakehost
  run_notty
  [[ $RC == 0 ]] && has ran
  check "14a known host → deploys normally" $? "rc=$RC"

  setup 14b
  conf RUN_CMD 'echo ran'
  ssh_g unknownhost
  run_notty
  [[ $RC != 0 && ! -e "$REMOTE_HOME/app" ]] && grep -qF 'is not in known_hosts' <<<"$OUT"
  check "14b unknown host, no terminal → no connection, explains why" $? "rc=$RC"

  setup 14c
  conf RUN_CMD 'echo ran'
  ssh_g 10.0.0.9 'hostkeyalias myalias'
  run_notty
  [[ $RC != 0 ]] && grep -qF 'looked up as: myalias' <<<"$OUT"
  check "14c HostKeyAlias looks up the alias (known IP does not count)" $? "rc=$RC"

  setup 14d
  conf RUN_CMD 'echo ran'
  ssh_g 10.0.0.9 'port 2222'
  run_notty
  [[ $RC != 0 ]] && grep -qF 'looked up as: [10.0.0.9]:2222' <<<"$OUT"
  check "14d non-22 port looks up [host]:port" $? "rc=$RC"

  setup 14e
  conf RUN_CMD 'echo ran'
  ssh_g unknownhost 'stricthostkeychecking accept-new'
  run_notty
  [[ $RC == 0 ]] && has ran
  check "14e StrictHostKeyChecking=accept-new → not blocked" $? "rc=$RC"
  unset FAKE_SSH_G
else
  echo "== skipping host key check tests (no setsid or ssh-keygen)"
fi

echo
echo "passed $PASS, failed $FAIL"
# Machine-readable results (for reports)
if [[ -n "${RESULTS_FILE:-}" ]]; then printf '%s\n' "${RESULTS[@]}" >"$RESULTS_FILE"; fi
[[ $FAIL == 0 ]]

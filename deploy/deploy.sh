#!/usr/bin/env bash
# deploy — generic rsync deploy script: sync a project to a remote machine (a Pi or any Linux host), then build / run it there.
#
# Install once and use it in any project:
#   install -m 755 deploy.sh ~/.local/bin/deploy
#   (or via home-manager: see deploy/default.nix)
#
# Usage:
#   deploy [options] [target]
#
#   target (optional) reads .deploy.<target>.conf, e.g. `deploy pi2`
#
# Options:
#   -H, --host HOST        remote host (user@host also works)
#   -u, --user USER        SSH user
#   -p, --port PORT        SSH port
#   -i, --key FILE         SSH private key
#   -d, --dir DIR          remote directory (default ~/<project dir name>)
#   -b, --build CMD        run locally BEFORE syncing (e.g. cross-compile)
#       --no-build         skip the local build (use what is already built)
#   -c, --cmd CMD          run remotely AFTER syncing (e.g. make && ./app)
#   -S, --stop CMD         run remotely before CMD to stop the old process
#   -e, --exclude PATTERN  extra exclude pattern (repeatable)
#   -B, --background       run CMD in the background, output to deploy.log
#                          (no terminal: sudo in CMD needs NOPASSWD on the remote)
#   -s, --sync-only        sync only, do not run CMD
#   -n, --dry-run          only list the files that would change (skips the local build,
#                          so files it would produce may show as missing or deleted)
#       --no-delete        keep remote files that do not exist locally
#       --show             print the final settings and exit
#   -h, --help             show this help
#
# Config sources (later ones override earlier ones):
#   built-in defaults < ~/.config/deploy/config < <project>/.deploy.conf
#   < <project>/.deploy.<target>.conf < DEPLOY_* env vars < command-line options
#
# Excludes: built-in list + <project>/.deployignore (rsync syntax, one rule per line)
#   With USE_GITIGNORE=1, the project's .gitignore is applied too.

set -euo pipefail

die() {
  echo "deploy: $*" >&2
  exit 1
}
# Help text comes from the header comment (found by marker, not by line number)
usage() { awk '/^# deploy — /{f=1} f && !/^#/{exit} f{sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------- built-in defaults ----------
PROJECT_DIR="$(pwd)"
HOST=""
USER_NAME=""
PORT=""
KEY=""
REMOTE_DIR=""
BUILD_CMD=""
RUN_CMD=""
STOP_CMD=""
BACKGROUND=0
DELETE=1
USE_GITIGNORE=0
EXCLUDES=(.git/ .svn/ .hg/ .vscode/ .idea/ __pycache__/ '*.pyc' venv/ .venv/
  node_modules/ .DS_Store Thumbs.db '.deploy*.conf' .deployignore)

# ---------- pre-scan: find only -h and the target name, to decide which config files to read ----------
TARGET=""
args=("$@")
for ((k = 0; k < ${#args[@]}; k++)); do
  case "${args[k]}" in
  -h | --help)
    usage
    exit 0
    ;;
  -H | --host | -u | --user | -p | --port | -i | --key | -d | --dir | -b | --build | -c | --cmd | -S | --stop | -e | --exclude) ((k++)) || true ;;
  -*) ;;
  *) TARGET="${args[k]}" ;;
  esac
done

# ---------- read config files (bash syntax, sourced: only use files you trust) ----------
load() {
  [[ -f "$1" ]] || return 0
  # shellcheck disable=SC1090 # config paths are only known at runtime
  source "$1"
  LOADED+=("$1")
}
LOADED=()
load "${XDG_CONFIG_HOME:-$HOME/.config}/deploy/config"
load "$PROJECT_DIR/.deploy.conf"
if [[ -n "$TARGET" ]]; then
  [[ -f "$PROJECT_DIR/.deploy.$TARGET.conf" ]] || die "cannot find .deploy.$TARGET.conf"
  load "$PROJECT_DIR/.deploy.$TARGET.conf"
fi

# ---------- environment variables ----------
HOST="${DEPLOY_HOST:-$HOST}"
USER_NAME="${DEPLOY_USER:-$USER_NAME}"
PORT="${DEPLOY_PORT:-$PORT}"
KEY="${DEPLOY_KEY:-$KEY}"
REMOTE_DIR="${DEPLOY_DIR:-$REMOTE_DIR}"
BUILD_CMD="${DEPLOY_BUILD:-$BUILD_CMD}"
RUN_CMD="${DEPLOY_CMD:-$RUN_CMD}"
STOP_CMD="${DEPLOY_STOP:-$STOP_CMD}"

# ---------- command-line options ----------
SYNC_ONLY=0
DRY_RUN=0
SHOW=0
need() { [[ $# -ge 2 && -n "$2" ]] || die "$1 requires an argument"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
  -H | --host)
    need "$@"
    HOST="$2"
    shift 2
    ;;
  -u | --user)
    need "$@"
    USER_NAME="$2"
    shift 2
    ;;
  -p | --port)
    need "$@"
    PORT="$2"
    shift 2
    ;;
  -i | --key)
    need "$@"
    KEY="$2"
    shift 2
    ;;
  -d | --dir)
    need "$@"
    REMOTE_DIR="$2"
    shift 2
    ;;
  -b | --build)
    need "$@"
    BUILD_CMD="$2"
    shift 2
    ;;
  -c | --cmd)
    need "$@"
    RUN_CMD="$2"
    shift 2
    ;;
  -S | --stop)
    need "$@"
    STOP_CMD="$2"
    shift 2
    ;;
  --no-build)
    BUILD_CMD=""
    shift
    ;;
  -e | --exclude)
    need "$@"
    EXCLUDES+=("$2")
    shift 2
    ;;
  -B | --background)
    BACKGROUND=1
    shift
    ;;
  -s | --sync-only)
    SYNC_ONLY=1
    shift
    ;;
  -n | --dry-run)
    DRY_RUN=1
    SYNC_ONLY=1
    shift
    ;;
  --no-delete)
    DELETE=0
    shift
    ;;
  --show)
    SHOW=1
    shift
    ;;
  -*) die "unknown option: $1 (see --help)" ;;
  *) shift ;; # target name, handled earlier
  esac
done

# ---------- resolve final values ----------
[[ -n "$HOST" ]] || die "no host given: use -H, DEPLOY_HOST, or HOST=... in .deploy.conf"
if [[ "$HOST" == *@* ]]; then
  SSH_TARGET="$HOST"
elif [[ -n "$USER_NAME" ]]; then
  SSH_TARGET="$USER_NAME@$HOST"
else SSH_TARGET="$HOST"; fi # let ~/.ssh/config decide the user

PROJECT_NAME="$(basename "$PROJECT_DIR")"
REMOTE_DIR="${REMOTE_DIR:-~/$PROJECT_NAME}"

SSH_OPTS=(-o ConnectTimeout=10)
[[ -n "$PORT" ]] && SSH_OPTS+=(-p "$PORT")
[[ -n "$KEY" ]] && SSH_OPTS+=(-i "$KEY")
# Make rsync use the same ssh options
RSYNC_SSH="ssh$(printf ' %q' "${SSH_OPTS[@]}")"

# A leading ~ in the remote path is left for the remote shell to expand; the rest is quoted
remote_path() {
  # shellcheck disable=SC2088 # ~ is passed verbatim to the remote, deliberately not expanded locally
  case "$1" in
  "~") printf '~' ;;
  "~/"*) printf '~/%q' "${1#\~/}" ;;
  *) printf '%q' "$1" ;;
  esac
}
RDIR="$(remote_path "$REMOTE_DIR")"

# Run a script on the remote with bash; a first argument of -t allocates a tty (so Ctrl+C and
# interactive input work). The script travels base64-encoded in the arguments (not via stdin, so it
# works with -t); the remote login shell (sh/bash/zsh/fish) only sees plain ASCII, and bash parses the content.
remote_bash() {
  local opts=("${SSH_OPTS[@]}") b64
  if [[ "$1" == -t ]]; then
    opts=(-t "${opts[@]}")
    shift
  fi
  # base64 | tr instead of GNU-only -w0, so it also works on macOS
  b64="$(printf '%s\n' "$1" | base64 | tr -d '\n')"
  # shellcheck disable=SC2029 # the remote command is meant to be built locally
  ssh "${opts[@]}" "$SSH_TARGET" "exec bash -c 'eval \"\$(printf %s $b64 | base64 -d)\"'"
}

# Turn rsync --itemize-changes codes (e.g. <f+++++++++) into one readable line per file:
#   + new / ~ update / * attrs (only permissions, owner, etc. changed) / - delete, then a summary line.
# Directories themselves are not listed (their files are); unrecognized lines are printed as is.
print_changes() {
  local color=0
  [[ -t 1 ]] && color=1
  awk -v color="$color" -v dry="$DRY_RUN" '
    BEGIN {
      if (color) { G = "\033[32m"; Y = "\033[33m"; C = "\033[36m"; R = "\033[31m"; N = "\033[0m" }
      split("c:content s:size t:time p:perms o:owner g:group a:ACL x:xattr", kv, " ")
      for (i in kv) { split(kv[i], p, ":"); name[p[1]] = p[2] }
    }
    /^\*deleting / {
      path = $0; sub(/^\*deleting +/, "", path)
      printf "  %s- delete%s  %s\n", R, N, path; del++; next
    }
    !/^[<>ch.][fdLDS][^ ]{9} / { print; next }
    {
      code = substr($0, 1, 11); path = substr($0, 13)
      act = substr(code, 1, 1); type = substr(code, 2, 1); attrs = substr(code, 3)
      if (type == "d") next
      if (attrs ~ /^\++$/) { printf "  %s+ new%s     %s\n", G, N, path; add++; next }
      if (act != ".")      { printf "  %s~ update%s  %s\n", Y, N, path; upd++; next }
      what = ""
      for (i = 1; i <= length(attrs); i++) {
        ch = substr(attrs, i, 1)
        if (ch in name) what = what (what == "" ? "" : ", ") name[ch]
      }
      printf "  %s* attrs%s   %s (%s)\n", C, N, path, what; att++
    }
    END {
      if (add + upd + att + del == 0) s = "no changes"
      else s = sprintf("%d new, %d updated, %d attrs, %d deleted", add, upd, att, del)
      if (dry) s = s " (dry run, nothing synced)"
      print "  " s
    }'
}

RSYNC_ARGS=(-az --human-readable --itemize-changes -e "$RSYNC_SSH")
((DELETE)) && RSYNC_ARGS+=(--delete --filter 'P /deploy.log') # protect the remote background-run log
((DRY_RUN)) && RSYNC_ARGS+=(--dry-run)
for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do RSYNC_ARGS+=(--exclude "$x"); done
[[ -f "$PROJECT_DIR/.deployignore" ]] && RSYNC_ARGS+=(--exclude-from "$PROJECT_DIR/.deployignore")
((USE_GITIGNORE)) && [[ -f "$PROJECT_DIR/.gitignore" ]] && RSYNC_ARGS+=(--filter ':- .gitignore')

if ((SHOW)); then
  cat <<EOF
Config files : ${LOADED[*]:-(none)}
Target       : ${TARGET:-(default)}
SSH          : $SSH_TARGET ${SSH_OPTS[*]}
Local dir    : $PROJECT_DIR/
Remote dir   : $REMOTE_DIR
Local build  : ${BUILD_CMD:-(none)}
Stop command : ${STOP_CMD:-(none)}
Remote run   : ${RUN_CMD:-(none)}$( ((BACKGROUND)) && echo "  [background, log: deploy.log]")
Delete extra : $( ((DELETE)) && echo yes || echo no)
Excludes     : ${EXCLUDES[*]:-}$([[ -f .deployignore ]] && echo " + .deployignore")$( ((USE_GITIGNORE)) && echo " + .gitignore")
EOF
  exit 0
fi

command -v rsync >/dev/null || die "rsync is not installed locally"

# Before connecting, make sure the host key is already in known_hosts.
# In a terminal ssh asks whether to trust it; without one (cron, CI, an agent) ssh only says
# "Host key verification failed" with no hint why, so give a clear error here first.
# The lookup name matches ssh's: the HostKeyAlias if set, else HostName ([host]:port for a non-22 port).
# If the ssh config cannot be read or needs no check, don't block; leave it to ssh.
check_host_key() {
  local cfg k v name="" alias="" port="" strict="" f
  local files=() more=()
  cfg="$(ssh -G "${SSH_OPTS[@]}" "$SSH_TARGET" 2>/dev/null)" || return 0
  while read -r k v; do
    case "$k" in
    hostname) name="$v" ;;
    hostkeyalias) alias="$v" ;;
    port) port="$v" ;;
    stricthostkeychecking) strict="$v" ;;
    knownhostscommand) [[ "$v" == none ]] || return 0 ;; # keys come from an external command; cannot check
    userknownhostsfile | globalknownhostsfile)
      read -r -a more <<<"$v"
      files+=("${more[@]}")
      ;;
    esac
  done <<<"$cfg"
  [[ -n "$name" ]] || return 0
  case "$strict" in false | no | off | accept-new) return 0 ;; esac

  if [[ -n "$alias" && "$alias" != none ]]; then
    name="$alias"
  elif [[ -n "$port" && "$port" != 22 ]]; then
    name="[$name]:$port"
  fi
  for f in ${files[@]+"${files[@]}"}; do
    f="${f/#\~/$HOME}"
    [[ -r "$f" ]] && ssh-keygen -F "$name" -f "$f" >/dev/null 2>&1 && return 0
  done

  if (: </dev/tty) 2>/dev/null; then
    info "first connection to $SSH_TARGET ($name is not in known_hosts); ssh will ask you to confirm the host key fingerprint"
    return 0
  fi
  die "host key for $SSH_TARGET is not in known_hosts (looked up as: $name), and there is no terminal for ssh to ask.
Run this in a terminal first, verify the fingerprint and type yes, then deploy again:
  $RSYNC_SSH $SSH_TARGET true"
}
check_host_key

# Background mode has no terminal, so sudo cannot ask for a password there and the run would
# fail out of sight in deploy.log. If CMD uses sudo, check before building or stopping anything.
# `sudo -n -l` passes when sudo works for this user without a password (at least for some commands).
sudo_word='(^|[^[:alnum:]_-])sudo([^[:alnum:]_-]|$)'
if ((BACKGROUND)) && ! ((SYNC_ONLY)) && [[ "$RUN_CMD" =~ $sudo_word ]]; then
  remote_bash "sudo -n -l >/dev/null 2>&1" ||
    die "CMD uses sudo, but sudo on $SSH_TARGET needs a password and background mode (-B) has no terminal to ask for it.
Run without -B, or allow these commands without a password (NOPASSWD) in the remote sudoers."
fi

# ---------- 1. local build ----------
if [[ -n "$BUILD_CMD" ]] && ! ((DRY_RUN)); then
  info "local build: $BUILD_CMD"
  (cd "$PROJECT_DIR" && bash -c "$BUILD_CMD")
fi

# ---------- 2. sync ----------
info "syncing $PROJECT_DIR/ → $SSH_TARGET:$REMOTE_DIR/"
if ((DRY_RUN)); then
  # Change nothing on the remote; rsync only reports what it would create
  [[ -n "$BUILD_CMD" ]] &&
    info "dry run skips the local build: files it would produce may show as '- delete' or be missing below"
else
  remote_bash "mkdir -p $RDIR"
fi
rsync "${RSYNC_ARGS[@]}" "$PROJECT_DIR/" "$SSH_TARGET:$REMOTE_DIR/" | print_changes

if ((DRY_RUN)); then
  info "dry run done: nothing synced, built or run"
  exit 0
elif ((SYNC_ONLY)) || [[ -z "$RUN_CMD" ]]; then
  info "done (sync only)"
  exit 0
fi

# ---------- 3. stop the old process ----------
if [[ -n "$STOP_CMD" ]]; then
  info "stopping old process: $STOP_CMD"
  # Wrap the user command in newlines (a trailing comment, ; or & cannot break the syntax)
  # and run it in a subshell, so an exit or failure inside does not abort the deploy, but say so.
  # With a local terminal, allocate a tty so sudo can ask for a password (it reads /dev/tty, not stdin).
  stop_script="cd $RDIR || exit 1
(
$STOP_CMD
) </dev/null || echo \"deploy: warning: stop command failed (exit \$?), continuing\" >&2"
  if [[ -t 0 ]]; then remote_bash -t "$stop_script"; else remote_bash "$stop_script"; fi
fi

# ---------- 4. run ----------
if ((BACKGROUND)); then
  info "running in background on remote: $RUN_CMD"
  # Parsed by the remote bash, so %q quoting is safe
  remote_bash "cd $RDIR || exit 1
nohup bash -c $(printf %q "$RUN_CMD") > deploy.log 2>&1 < /dev/null &
printf 'PID %s, log: %s\\n' \"\$!\" $(printf %q "$REMOTE_DIR/deploy.log")"
else
  info "running on remote: $RUN_CMD"
  # -t lets Ctrl+C stop the remote program too; if cd fails, nothing runs.
  # This is the last command, so deploy's exit code is the remote program's exit code
  remote_bash -t "cd $RDIR || exit 1
$RUN_CMD"
fi

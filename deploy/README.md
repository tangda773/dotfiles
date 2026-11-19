# deploy

`deploy` is a generic rsync deploy script. It syncs the project directory you are in to a remote Linux machine (a Pi or any host you can SSH into), and can then build or run it there.

The flow:

1. **Local build** (optional): run `BUILD_CMD` locally before syncing, e.g. to cross-compile.
2. **Sync**: rsync the project to the remote directory. By default, remote files that do not exist locally are deleted.
3. **Stop the old process** (optional): run `STOP_CMD` on the remote; a failure prints a warning but does not abort the deploy.
4. **Run** (optional): run `RUN_CMD` in the remote directory, in the foreground or background.

Without `RUN_CMD`, deploy only syncs.

## Installation

This directory is a home-manager module, already imported in `home.nix`:

```nix
imports = [ ./deploy ];
```

After `home-manager switch` (or `nh home switch`) the `deploy` command is available. rsync, ssh and the other dependencies come from Nix, so nothing else needs to be installed on the system.

To change the script, edit `deploy/deploy.sh` and switch again. The build runs shellcheck and fails on any warning.

On machines without Nix, install the script directly:

```sh
install -m 755 deploy/deploy.sh ~/.local/bin/deploy
```

## Quick start

Create `.deploy.conf` in the project root:

```bash
HOST=space-a                 # a Host alias from ~/.ssh/config works
REMOTE_DIR="~/apps/myapp"    # must be quoted, see below
RUN_CMD="make && ./myapp"
```

Then, from the project root:

```sh
deploy --show     # check the final settings first
deploy -n         # list what would change without syncing
deploy            # sync and run
```

`deploy` uses **the current directory** as the project directory, so run it from the project root.

### Sync output

Each changed file is printed on one line, followed by a summary:

```
  + new     src/main.go
  ~ update  bin/app
  * attrs   run.sh (perms)
  - delete  old/stale.txt
  1 new, 1 updated, 1 attrs, 1 deleted (dry run, nothing synced)
```

| Line | Meaning |
|---|---|
| `+ new` | new file |
| `~ update` | content updated |
| `* attrs` | content unchanged; only metadata (permissions, owner, …) changed — the changed fields are listed in parentheses |
| `- delete` | deleted on the remote |

Directories themselves are not listed, only the files in them.

### First connection to a new host

Before connecting, `deploy` checks that the host key is already in `known_hosts`. It looks the host up under the same name ssh does: the `HostKeyAlias` if one is set, otherwise the HostName, written as `[host]:port` for a non-22 port. So a new alias counts as a new host even if its IP is already trusted.

- **In a terminal**: deploy notes that this is a first connection, then ssh asks whether to trust the fingerprint. Verify it and type `yes`.
- **Without a terminal** (cron, CI, an agent): deploy stops before building or syncing and prints the command to run by hand first, for example:

  ```
  deploy: host key for space-a is not in known_hosts (looked up as: space-a), and there is no terminal for ssh to ask.
  Run this in a terminal first, verify the fingerprint and type yes, then deploy again:
    ssh -o ConnectTimeout=10 space-a true
  ```

The check is skipped when `StrictHostKeyChecking` is `no` or `accept-new`, or when `KnownHostsCommand` is used.

## Options

```
deploy [options] [target]
```

| Option | Description |
|---|---|
| `-H, --host HOST` | remote host; `user@host` also works |
| `-u, --user USER` | SSH user |
| `-p, --port PORT` | SSH port |
| `-i, --key FILE` | SSH private key |
| `-d, --dir DIR` | remote directory, default `~/<project dir name>` |
| `-b, --build CMD` | run locally **before** syncing |
| `--no-build` | skip the local build and use what is already built |
| `-c, --cmd CMD` | run remotely **after** syncing |
| `-S, --stop CMD` | stop command run remotely before `CMD` |
| `-e, --exclude PATTERN` | extra exclude pattern; can be repeated |
| `-B, --background` | run in the background; output goes to `deploy.log` on the remote |
| `-s, --sync-only` | sync only, do not run |
| `-n, --dry-run` | only list what would change; changes nothing on the remote and skips the local build, so files the build would produce may show as deleted |
| `--no-delete` | keep remote files that do not exist locally |
| `--show` | print the final settings and exit without connecting |
| `-h, --help` | show help |

**Target**: if given, `.deploy.<target>.conf` is read. For example, `deploy pi2` reads `.deploy.pi2.conf`; it is an error if that file does not exist.

## Config sources and precedence

Settings can come from several places; later ones override earlier ones:

```
built-in defaults
  < ~/.config/deploy/config          shared by all projects
  < <project>/.deploy.conf           this project's defaults
  < <project>/.deploy.<target>.conf  only when a target is given
  < DEPLOY_* environment variables
  < command-line options
```

`deploy --show` prints the values finally used and which config files were read.

### Config file format

Config files are **bash**; the script `source`s them, so:

- Write `NAME=value` with no spaces around `=`.
- Quote values containing spaces, e.g. `RUN_CMD="make && ./app"`.
- **Quote a leading `~` in paths**, e.g. `REMOTE_DIR="~/apps/x"`. Unquoted, bash expands it **locally** to your local home (e.g. `/home/kuangtatang/apps/x`), which puts files in the wrong place when the remote user differs. The same goes for `-d` and `DEPLOY_DIR`: write `-d '~/apps/x'`. In `deploy --show`, the remote directory should read `~/...`.
- The file is executed as code, so **only use config files you trust**. Do not `deploy` someone else's project without reading its `.deploy*.conf` first.

### Variables

| Variable | Env var | Option | Default | Description |
|---|---|---|---|---|
| `HOST` | `DEPLOY_HOST` | `-H` | (required) | remote host: an IP, hostname, `user@host` or SSH alias |
| `USER_NAME` | `DEPLOY_USER` | `-u` | empty | SSH user; when empty, `~/.ssh/config` decides |
| `PORT` | `DEPLOY_PORT` | `-p` | empty | SSH port; when empty, `~/.ssh/config` decides |
| `KEY` | `DEPLOY_KEY` | `-i` | empty | SSH private key path |
| `REMOTE_DIR` | `DEPLOY_DIR` | `-d` | `~/<project dir name>` | remote directory; a leading `~` is expanded on the remote |
| `BUILD_CMD` | `DEPLOY_BUILD` | `-b` | empty | run in the local project directory before syncing |
| `RUN_CMD` | `DEPLOY_CMD` | `-c` | empty | run in the remote directory after syncing; when empty, only sync |
| `STOP_CMD` | `DEPLOY_STOP` | `-S` | empty | run in the remote directory before `RUN_CMD`; a failure prints a warning and the deploy continues |
| `BACKGROUND` | — | `-B` | `0` | `1` runs in the background |
| `DELETE` | — | `--no-delete` | `1` | `0` keeps remote files that do not exist locally |
| `USE_GITIGNORE` | — | — | `0` | `1` also applies the project's `.gitignore` excludes |
| `EXCLUDES` | — | `-e` | see below | exclude list (bash array) |

`BACKGROUND`, `DELETE`, `USE_GITIGNORE` and `EXCLUDES` have no environment variable; set them in a config file or on the command line.

## Excludes

Three sets of exclude rules are applied together:

1. **Built-in list**: `.git/ .svn/ .hg/ .vscode/ .idea/ __pycache__/ *.pyc venv/ .venv/ node_modules/ .DS_Store Thumbs.db .deploy*.conf .deployignore`
2. **`<project>/.deployignore`**: rsync exclude syntax, one rule per line.
3. **`.gitignore`**: only with `USE_GITIGNORE=1`.

To add excludes in a config file, use `+=`, otherwise you replace the built-in list:

```bash
EXCLUDES+=(build/ '*.log')     # correct: append
EXCLUDES=(build/)              # replaces the whole built-in list
```

### Warning: remote files are deleted by default

Syncing uses `--delete` by default, so **any file in the remote directory that does not exist locally is deleted**, including:

- files built on the remote, e.g. `app` or `build/` produced by `RUN_CMD="make && ./app"`;
- data, databases, uploads and so on created on the remote by your program.

The exception is `deploy.log` in the remote directory, written by background runs; it is protected automatically.

Excluded files are never deleted, so add anything you want to keep to `.deployignore`:

```
build/
data/
```

Or set `DELETE=0` / use `--no-delete`. Before the first deploy into an existing directory, run `deploy -n` to see what would change.

## Examples

### Shared defaults: `~/.config/deploy/config`

home-manager generates this file from `deploy/default.nix`, as a read-only symlink. To change it, edit `xdg.configFile."deploy/config".text` in `default.nix` and switch again.

```bash
USER_NAME=space
USE_GITIGNORE=1
```

### One project, several targets

```bash
# .deploy.conf: shared by all targets
REMOTE_DIR="~/apps/sensor"
RUN_CMD="python3 main.py"
STOP_CMD="pkill -f 'python3 main.py'"
BACKGROUND=1
```

```bash
# .deploy.pi1.conf
HOST=10.10.10.21
```

```bash
# .deploy.pi2.conf
HOST=10.10.10.22
PORT=2222
```

```sh
deploy pi1     # deploy to pi1
deploy pi2     # deploy to pi2
```

`.deploy*.conf` is in the built-in exclude list, so it is never synced to the remote.

### Cross-compile locally, run remotely

```bash
# .deploy.conf
HOST=space-a
BUILD_CMD="GOOS=linux GOARCH=arm64 go build -o bin/app ."
RUN_CMD="./bin/app"
STOP_CMD="pkill -x app"
```

### One-off overrides via env vars or options

```sh
DEPLOY_HOST=10.10.10.30 deploy          # use another host
deploy -c 'pytest -q' -d '~/tmp/test'   # different command and remote directory
deploy -s                               # sync only this time
```

## Foreground and background runs

- **Foreground** (default): runs via `ssh -t`, so output shows in your terminal and Ctrl+C also stops the remote program. `STOP_CMD` also gets a tty when deploy runs in a terminal, so `sudo` in either can ask for a password.
- **Background** (`-B` or `BACKGROUND=1`): runs under `nohup` on the remote, writes output to `<REMOTE_DIR>/deploy.log`, and prints the PID. To follow the output:

  ```sh
  ssh space-a 'tail -f ~/apps/myapp/deploy.log'
  ```

  The remote script always runs under bash, so it does not matter whether the remote user's login shell is sh, dash, zsh or fish.

  A background program is not stopped automatically, so pair it with `STOP_CMD` to stop the old one before the next deploy.

  A background run has no terminal, so `sudo` in it cannot ask for a password. If `RUN_CMD` uses `sudo`, deploy first checks that sudo works without a password on the remote (`sudo -n -l`) and stops before building if it does not; allow the commands with `NOPASSWD` in the remote sudoers, or run in the foreground.

## Tests

`test-deploy.sh` tests sync, stop and run end to end with a fake `ssh` that runs commands in a fake remote home directory on the local machine, so no real remote is needed:

```sh
./test-deploy.sh                       # remote login shells: whichever of bash/dash/zsh/fish is on PATH
SHELLS="bash dash" ./test-deploy.sh
DEPLOY_BASH="bash --posix" ./test-deploy.sh
```

If dash or fish is missing, use `nix shell nixpkgs#dash nixpkgs#fish -c ./test-deploy.sh`.

The host key check tests need `setsid` and `ssh-keygen`; they are skipped if either is missing.

#!/usr/bin/env bash
# deploy — 通用 rsync 部署腳本：同步專案到遠端機器（Pi 或任何 Linux），再建置 / 執行。
#
# 安裝一次即可在任何專案使用：
#   install -m 755 deploy.sh ~/.local/bin/deploy
#   （或用 home-manager：見 deploy/default.nix）
#
# 用法：
#   deploy [選項] [目標名稱]
#
#   目標名稱（可省略）會讀取 .deploy.<名稱>.conf，例如 `deploy pi2`
#
# 選項：
#   -H, --host HOST        遠端主機（也可寫 user@host）
#   -u, --user USER        SSH 使用者
#   -p, --port PORT        SSH 連接埠
#   -i, --key FILE         SSH 私鑰
#   -d, --dir DIR          遠端目錄（預設 ~/<專案資料夾名>）
#   -b, --build CMD        同步「前」在本機執行（例：交叉編譯）
#   -c, --cmd CMD          同步「後」在遠端執行（例：make && ./app）
#   -S, --stop CMD         執行前先在遠端執行的停止指令
#   -e, --exclude PATTERN  額外排除（可重複）
#   -B, --background       遠端在背景執行，輸出寫到 deploy.log
#   -s, --sync-only        只同步，不執行
#   -n, --dry-run          只顯示會變動的檔案
#       --no-delete        不刪除遠端多出的檔案
#       --show             印出最終設定後結束
#       --self-update[=SRC] 更新 deploy 腳本本身後結束（見下方）
#   -h, --help             顯示說明
#
# 自我更新（--self-update）：
#   SRC 可以是 https URL、檔案路徑，或含 deploy.sh 的 git repo 資料夾。
#   沒給 SRC 時用設定裡的 SELF_UPDATE_SRC；兩者都沒有、但腳本本身
#   位在 git repo 裡（例如用 symlink 安裝）時，就在那個 repo 做 git pull。
#   更新前會先檢查語法，舊版備份成 <腳本>.bak。
#
# 設定來源（後者覆蓋前者）：
#   內建預設 < ~/.config/deploy/config < <專案>/.deploy.conf
#   < <專案>/.deploy.<目標>.conf < 環境變數 DEPLOY_* < 命令列選項
#
# 排除規則：內建清單 + <專案>/.deployignore（rsync 語法，每行一條）
#   若設 USE_GITIGNORE=1，也會套用專案的 .gitignore。

set -euo pipefail

die() {
  echo "deploy: $*" >&2
  exit 1
}
# 說明文字取自檔頭註解（用標記找，包成 nix 套件後行號會變也沒關係）
usage() { awk '/^# deploy — /{f=1} f && !/^#/{exit} f{sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------- 內建預設 ----------
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
SELF_UPDATE_SRC=""
EXCLUDES=(.git/ .svn/ .hg/ .vscode/ .idea/ __pycache__/ '*.pyc' venv/ .venv/
  node_modules/ .DS_Store Thumbs.db '.deploy*.conf' .deployignore)

# ---------- 先掃描：只找出 -h 與目標名稱，好決定要讀哪些設定檔 ----------
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

# ---------- 讀設定檔（是 bash 語法，會被 source，請只放自己信任的檔） ----------
load() {
  [[ -f "$1" ]] || return 0
  # shellcheck disable=SC1090 # 設定檔路徑在執行時才決定
  source "$1"
  LOADED+=("$1")
}
LOADED=()
load "${XDG_CONFIG_HOME:-$HOME/.config}/deploy/config"
load "$PROJECT_DIR/.deploy.conf"
if [[ -n "$TARGET" ]]; then
  [[ -f "$PROJECT_DIR/.deploy.$TARGET.conf" ]] || die "找不到 .deploy.$TARGET.conf"
  load "$PROJECT_DIR/.deploy.$TARGET.conf"
fi

# ---------- 環境變數 ----------
HOST="${DEPLOY_HOST:-$HOST}"
USER_NAME="${DEPLOY_USER:-$USER_NAME}"
PORT="${DEPLOY_PORT:-$PORT}"
KEY="${DEPLOY_KEY:-$KEY}"
REMOTE_DIR="${DEPLOY_DIR:-$REMOTE_DIR}"
BUILD_CMD="${DEPLOY_BUILD:-$BUILD_CMD}"
RUN_CMD="${DEPLOY_CMD:-$RUN_CMD}"
STOP_CMD="${DEPLOY_STOP:-$STOP_CMD}"
SELF_UPDATE_SRC="${DEPLOY_SELF_UPDATE_SRC:-$SELF_UPDATE_SRC}"

# ---------- 自我更新 ----------
self_update() {
  local src="$1" self dir tmp
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  dir="$(dirname "$self")"

  # 由 Nix / home-manager 安裝：檔案在唯讀的 /nix/store，要從 dotfiles 更新
  if [[ "$self" == /nix/store/* ]]; then
    die "這份 deploy 由 Nix/home-manager 管理（$self）。請改 dotfiles 裡的 deploy.sh，再執行 home-manager switch。"
  fi

  # 沒有來源：腳本本身在 git repo 裡就直接 pull
  if [[ -z "$src" ]]; then
    if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
      info "git pull：$dir"
      git -C "$dir" pull --ff-only
      exit 0
    fi
    die "沒有更新來源：用 --self-update=來源，或在 ~/.config/deploy/config 設 SELF_UPDATE_SRC=..."
  fi

  [[ -w "$dir" ]] || die "沒有寫入權限：$dir"
  # 暫存檔放同一個資料夾，最後用 mv 原子替換（不會改到正在執行的檔案內容）
  tmp="$(mktemp "$self.new.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT

  case "$src" in
  http://* | https://*)
    info "下載 $src"
    curl -fsSL "$src" -o "$tmp" || die "下載失敗"
    ;;
  *)
    if [[ -d "$src" ]]; then
      if git -C "$src" rev-parse --is-inside-work-tree &>/dev/null; then
        info "git pull：$src"
        git -C "$src" pull --ff-only
      fi
      src="$src/deploy.sh"
    fi
    [[ -f "$src" ]] || die "找不到 $src"
    cp "$src" "$tmp"
    ;;
  esac

  [[ -s "$tmp" ]] || die "新版是空檔，取消更新"
  head -n1 "$tmp" | grep -q '^#!.*bash' || die "新版不像是 bash 腳本，取消更新"
  bash -n "$tmp" || die "新版語法錯誤，取消更新"

  if cmp -s "$tmp" "$self"; then
    info "已經是最新版"
    exit 0
  fi

  cp -p "$self" "$self.bak"
  chmod 755 "$tmp"
  mv -f "$tmp" "$self"
  trap - EXIT
  info "已更新：$self（舊版：$self.bak）"
  exit 0
}

# ---------- 命令列選項 ----------
SYNC_ONLY=0
DRY_RUN=0
SHOW=0
need() { [[ $# -ge 2 && -n "$2" ]] || die "$1 需要參數"; }
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
  --self-update) self_update "$SELF_UPDATE_SRC" ;;
  --self-update=*) self_update "${1#*=}" ;;
  -*) die "未知選項：$1（看 --help）" ;;
  *) shift ;; # 目標名稱，前面已處理
  esac
done

# ---------- 整理最終值 ----------
[[ -n "$HOST" ]] || die "沒有指定主機：用 -H、DEPLOY_HOST 或在 .deploy.conf 寫 HOST=..."
if [[ "$HOST" == *@* ]]; then
  SSH_TARGET="$HOST"
elif [[ -n "$USER_NAME" ]]; then
  SSH_TARGET="$USER_NAME@$HOST"
else SSH_TARGET="$HOST"; fi # 交給 ~/.ssh/config 決定使用者

PROJECT_NAME="$(basename "$PROJECT_DIR")"
REMOTE_DIR="${REMOTE_DIR:-~/$PROJECT_NAME}"

SSH_OPTS=(-o ConnectTimeout=10)
[[ -n "$PORT" ]] && SSH_OPTS+=(-p "$PORT")
[[ -n "$KEY" ]] && SSH_OPTS+=(-i "$KEY")
# 讓 rsync 使用同一組 ssh 參數
RSYNC_SSH="ssh$(printf ' %q' "${SSH_OPTS[@]}")"

# 遠端路徑開頭的 ~ 交給遠端 shell 展開，其餘部分加引號
remote_path() {
  # shellcheck disable=SC2088 # ~ 要原樣傳給遠端，故意不在本機展開
  case "$1" in
  "~") printf '~' ;;
  "~/"*) printf '~/%q' "${1#\~/}" ;;
  *) printf '%q' "$1" ;;
  esac
}
RDIR="$(remote_path "$REMOTE_DIR")"

# 在遠端用 bash 執行一段腳本；第一個參數是 -t 時配置 tty（Ctrl+C、互動輸入才正常）。
# 腳本以 base64 放在參數裡（不走 stdin，才能和 -t 並用），遠端登入 shell
# （sh/bash/zsh/fish）只看到純 ASCII，實際內容一律交給 bash 解析。
remote_bash() {
  local opts=("${SSH_OPTS[@]}") b64
  if [[ "$1" == -t ]]; then
    opts=(-t "${opts[@]}")
    shift
  fi
  # base64 | tr 而不用 GNU 專屬的 -w0，macOS 也能用
  b64="$(printf '%s\n' "$1" | base64 | tr -d '\n')"
  # shellcheck disable=SC2029 # 遠端指令本來就要在本機組好再送出
  ssh "${opts[@]}" "$SSH_TARGET" "exec bash -c 'eval \"\$(printf %s $b64 | base64 -d)\"'"
}

RSYNC_ARGS=(-az --human-readable --itemize-changes -e "$RSYNC_SSH")
((DELETE)) && RSYNC_ARGS+=(--delete --filter 'P /deploy.log') # 保護遠端背景執行的 log
((DRY_RUN)) && RSYNC_ARGS+=(--dry-run)
for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do RSYNC_ARGS+=(--exclude "$x"); done
[[ -f "$PROJECT_DIR/.deployignore" ]] && RSYNC_ARGS+=(--exclude-from "$PROJECT_DIR/.deployignore")
((USE_GITIGNORE)) && [[ -f "$PROJECT_DIR/.gitignore" ]] && RSYNC_ARGS+=(--filter ':- .gitignore')

if ((SHOW)); then
  cat <<EOF
設定檔     : ${LOADED[*]:-(無)}
目標       : ${TARGET:-(預設)}
SSH        : $SSH_TARGET ${SSH_OPTS[*]}
本機目錄   : $PROJECT_DIR/
遠端目錄   : $REMOTE_DIR
本機建置   : ${BUILD_CMD:-(無)}
停止指令   : ${STOP_CMD:-(無)}
遠端執行   : ${RUN_CMD:-(無)}$( ((BACKGROUND)) && echo "  [背景，log: deploy.log]")
刪除多餘檔 : $( ((DELETE)) && echo 是 || echo 否)
排除       : ${EXCLUDES[*]:-}$([[ -f .deployignore ]] && echo " + .deployignore")$( ((USE_GITIGNORE)) && echo " + .gitignore")
EOF
  exit 0
fi

command -v rsync >/dev/null || die "本機沒有安裝 rsync"

# ---------- 1. 本機建置 ----------
if [[ -n "$BUILD_CMD" ]] && ! ((DRY_RUN)); then
  info "本機建置：$BUILD_CMD"
  (cd "$PROJECT_DIR" && bash -c "$BUILD_CMD")
fi

# ---------- 2. 同步 ----------
info "同步 $PROJECT_DIR/ → $SSH_TARGET:$REMOTE_DIR/"
remote_bash "mkdir -p $RDIR"
rsync "${RSYNC_ARGS[@]}" "$PROJECT_DIR/" "$SSH_TARGET:$REMOTE_DIR/"

if ((SYNC_ONLY)) || [[ -z "$RUN_CMD" ]]; then
  info "完成（只同步）"
  exit 0
fi

# ---------- 3. 停止舊程式 ----------
if [[ -n "$STOP_CMD" ]]; then
  info "停止舊程式：$STOP_CMD"
  # 換行包住使用者指令（結尾的註解、; 、& 都不會破壞語法），
  # 放在子 shell 裡，裡面的 exit 或失敗都不會中止部署
  remote_bash "cd $RDIR || exit 1
(
$STOP_CMD
) </dev/null || true"
fi

# ---------- 4. 執行 ----------
if ((BACKGROUND)); then
  info "遠端背景執行：$RUN_CMD"
  # 在遠端 bash 內解析，%q 產生的引號可以安全使用
  remote_bash "cd $RDIR || exit 1
nohup bash -c $(printf %q "$RUN_CMD") > deploy.log 2>&1 < /dev/null &
printf 'PID %s，log：%s\\n' \"\$!\" $(printf %q "$REMOTE_DIR/deploy.log")"
else
  info "遠端執行：$RUN_CMD"
  # -t 讓 Ctrl+C 也能停掉遠端程式；cd 失敗就不執行任何指令。
  # 這是最後一個指令，deploy 的結束碼就是遠端程式的結束碼
  remote_bash -t "cd $RDIR || exit 1
$RUN_CMD"
fi

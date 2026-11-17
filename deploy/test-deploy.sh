#!/usr/bin/env bash
# test-deploy.sh — 用假的 ssh 在本機端到端測試 deploy.sh（不需要真的遠端機器）
#
# 用法：
#   ./test-deploy.sh                       # 測 deploy.sh，登入 shell 用 PATH 裡有的 bash/dash/zsh/fish
#   SHELLS="bash dash" ./test-deploy.sh    # 指定要測的遠端登入 shell
#   DEPLOY_BASH="bash --posix" ./test-deploy.sh   # 用指定的 bash 跑 deploy.sh 本身
#   DEPLOY=/path/to/deploy.sh ./test-deploy.sh
#
# 假 ssh 的做法：略過 -t/-o/-p/-i/-l 等選項，取出主機名稱，剩下的參數用空白
# 串起來（跟真的 ssh 一樣），在假遠端家目錄裡用 $FAKE_SHELL -c 執行。
# rsync 的 -e 也會呼叫這個假 ssh，所以同步也是端到端在本機完成。

# shellcheck disable=SC2016 # 測試資料故意用單引號，$變數要原樣送到遠端
# shellcheck disable=SC2088 # ~ 要原樣寫進設定檔，交給遠端展開
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${DEPLOY:-$HERE/deploy.sh}"
read -r -a DEPLOY_BASH_CMD <<<"${DEPLOY_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-deploy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------- 假 ssh ----------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o | -p | -i | -l) shift 2 ;;
  -*) shift ;;
  *)
    shift # 主機名稱
    break
    ;;
  esac
done
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

# 每個案例：全新的假遠端家目錄與本機專案
setup() {
  REMOTE_HOME="$WORK/remote-$1-$FAKE_SHELL"
  PROJ="$WORK/proj-$1-$FAKE_SHELL/myproj"
  rm -rf "$REMOTE_HOME" "${PROJ%/*}"
  mkdir -p "$REMOTE_HOME" "$PROJ"
  echo hello >"$PROJ/hello.txt"
  export FAKE_REMOTE_HOME="$REMOTE_HOME"
  # 用設定檔寫入，順便測 source 進來的值
  printf 'HOST=fakehost\nREMOTE_DIR=%q\n' '~/app' >"$PROJ/.deploy.conf"
}
conf() { printf '%s=%q\n' "$1" "$2" >>"$PROJ/.deploy.conf"; }

# 執行 deploy，結果放在 $OUT 與 $RC
run_deploy() {
  OUT="$(cd "$PROJ" && env -u DEPLOY_HOST XDG_CONFIG_HOME="$WORK/xdg" \
    "${DEPLOY_BASH_CMD[@]}" "$DEPLOY" "$@" 2>&1)"
  RC=$?
}

check() { # check 名稱 條件結果(0/1) 失敗時的說明
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

# 整行比對：避免比對到 deploy 印出的「遠端執行：<指令>」那一行
has() { grep -qxF -- "$1" <<<"$OUT"; }
has_in() { grep -qxF -- "$2" <<<"$1"; }
wait_for() { # wait_for 檔案 字串：最多等 10 秒
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_file() { # wait_file 檔案：最多等 10 秒
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

check8() { # 第 8 項的輸出是否正確（$1 是要檢查的文字）
  local t="$1"
  has_in "$t" "你好 世界" && has_in "$t" 'single "dq" $notexpanded' &&
    has_in "$t" "home=$REMOTE_HOME" && has_in "$t" 'heredoc 中文 $x'
}

for FAKE_SHELL in $SHELLS; do
  export FAKE_SHELL
  echo "== 遠端登入 shell：$FAKE_SHELL"

  setup 1
  conf STOP_CMD 'touch stopped # 註解'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/stopped" ]] && has ran
  check "1 STOP 結尾有註解" $? "rc=$RC"

  setup 2
  conf STOP_CMD $'touch s1\ntouch s2\n'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/s1" && -f "$REMOTE_HOME/app/s2" ]] && has ran
  check "2 STOP 多行（結尾換行）" $? "rc=$RC"

  setup 3
  conf STOP_CMD 'touch s3;'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/app/s3" ]] && has ran
  check "3 STOP 結尾有分號" $? "rc=$RC"

  setup 4
  conf STOP_CMD 'touch s4 &'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran && wait_file "$REMOTE_HOME/app/s4"
  check "4 STOP 結尾有 &" $? "rc=$RC"

  setup 5a
  conf STOP_CMD 'false'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "5a STOP 失敗（false）" $? "rc=$RC"

  setup 5b
  conf STOP_CMD 'exit 1'
  conf RUN_CMD 'echo ran'
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "5b STOP 失敗（exit 1）" $? "rc=$RC"

  setup 6
  conf RUN_CMD $'set -e\necho step1\nfalse\necho step2'
  run_deploy
  [[ $RC != 0 ]] && has step1 && ! has step2
  check "6 RUN 多行 set -e 中途失敗" $? "rc=$RC"

  setup 7
  conf RUN_CMD 'echo a; exit 3'
  run_deploy
  [[ $RC == 3 ]] && has a
  check "7 RUN exit 3 → deploy 結束碼 3" $? "rc=$RC"

  setup 8
  conf RUN_CMD "$RUN8"
  run_deploy
  [[ $RC == 0 ]] && check8 "$OUT"
  check "8 RUN 中文/引號/\$變數/heredoc" $? "rc=$RC"

  setup 9
  conf RUN_CMD "$RUN8"$'\nsleep 5'
  conf BACKGROUND 1
  start=$SECONDS
  run_deploy
  took=$((SECONDS - start))
  [[ $RC == 0 && $took -lt 4 ]] && wait_for "$REMOTE_HOME/app/deploy.log" 'heredoc 中文' &&
    check8 "$(cat "$REMOTE_HOME/app/deploy.log")"
  check "9 背景模式（log 正確、立即返回）" $? "rc=$RC took=${took}s log=$(cat "$REMOTE_HOME/app/deploy.log" 2>/dev/null | tr '\n' '/')"

  setup 10
  : >"$REMOTE_HOME/blocker" # 一般檔案擋住，mkdir -p 一定失敗
  printf 'REMOTE_DIR=%q\n' '~/blocker/sub' >>"$PROJ/.deploy.conf"
  conf STOP_CMD 'touch STOP_RAN'
  conf RUN_CMD 'touch RUN_RAN'
  run_deploy
  found="$(find "$REMOTE_HOME" -name '*_RAN' | tr '\n' ' ')"
  ok=1
  [[ $RC != 0 && -z "$found" ]] && ok=0
  check "10 遠端目錄無法建立 → 不執行" "$ok" "rc=$RC found=$found"

  # 10b：cd 失敗（STOP 把遠端目錄刪掉），RUN 的第二個指令也不能在錯的目錄執行
  setup 10b
  conf STOP_CMD 'cd ~ && rm -rf ~/app'
  conf RUN_CMD 'touch RUN_RAN_A; touch RUN_RAN_B'
  run_deploy
  found="$(find "$REMOTE_HOME" -name 'RUN_RAN_*' | tr '\n' ' ')"
  [[ $RC != 0 && -z "$found" ]]
  check "10b cd 失敗 → RUN 的 a; b 都不執行" $? "rc=$RC found=$found"

  setup 11
  printf 'REMOTE_DIR=%q\n' '~/my app' >>"$PROJ/.deploy.conf"
  conf RUN_CMD 'pwd'
  run_deploy
  [[ $RC == 0 && -f "$REMOTE_HOME/my app/hello.txt" ]] && has "$REMOTE_HOME/my app"
  check "11 REMOTE_DIR 含空白" $? "rc=$RC"

  setup 12
  conf RUN_CMD 'echo bg'
  conf BACKGROUND 1
  run_deploy
  wait_for "$REMOTE_HOME/app/deploy.log" bg
  run_deploy -s
  [[ $RC == 0 && -f "$REMOTE_HOME/app/deploy.log" ]]
  check "12 再次部署不刪 deploy.log" $? "rc=$RC"

  # 額外：EXCLUDES 設成空陣列（bash 3.2 下空陣列在 set -u 會出錯）
  setup 13
  conf RUN_CMD 'echo ran'
  echo 'EXCLUDES=()' >>"$PROJ/.deploy.conf"
  run_deploy
  [[ $RC == 0 ]] && has ran
  check "13 EXCLUDES=() 空陣列" $? "rc=$RC"
done

echo
echo "通過 $PASS，失敗 $FAIL"
# 機器可讀的結果（給報表用）
if [[ -n "${RESULTS_FILE:-}" ]]; then printf '%s\n' "${RESULTS[@]}" >"$RESULTS_FILE"; fi
[[ $FAIL == 0 ]]

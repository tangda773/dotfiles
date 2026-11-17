# deploy

`deploy` 是一個通用的 rsync 部署腳本。它把目前所在的專案資料夾同步到遠端 Linux 機器（Pi 或任何能 SSH 的主機），然後可以在遠端建置或執行。

一般流程：

1. **本機建置**（可選）：同步前在本機執行 `BUILD_CMD`，例如交叉編譯。
2. **同步**：用 rsync 把專案同步到遠端目錄，預設會刪掉遠端多出來的檔案。
3. **停止舊程式**（可選）：在遠端執行 `STOP_CMD`，失敗也不會中斷。
4. **執行**（可選）：在遠端目錄裡執行 `RUN_CMD`，可以在前景或背景執行。

沒有設定 `RUN_CMD` 時，只會同步。

## 安裝

這個資料夾是一個 home-manager 模組，`home.nix` 已經匯入：

```nix
imports = [ ./deploy ];
```

執行 `home-manager switch`（或 `nh home switch`）後就會有 `deploy` 指令。rsync、ssh、git 等依賴都由 Nix 提供，系統不必另外安裝。

要修改腳本時，改 `deploy/deploy.sh` 後再 switch 一次。build 時會跑 shellcheck，有警告就會 build 失敗。用 Nix 安裝的版本放在唯讀的 `/nix/store`，所以 `--self-update` 會直接拒絕，並提示你走這個流程。

不用 Nix 的機器可以直接安裝腳本：

```sh
install -m 755 deploy/deploy.sh ~/.local/bin/deploy
```

## 快速開始

在專案根目錄建立 `.deploy.conf`：

```bash
HOST=space-a                 # 可以用 ~/.ssh/config 裡的 Host 別名
REMOTE_DIR="~/apps/myapp"         # 要加引號，見下方說明
RUN_CMD="make && ./myapp"
```

然後在專案根目錄執行：

```sh
deploy --show     # 先確認最終設定
deploy -n         # 只看會變動哪些檔案，不實際同步
deploy            # 同步並執行
```

`deploy` 以**目前所在的資料夾**作為專案目錄，所以要在專案根目錄執行。

## 指令選項

```
deploy [選項] [目標名稱]
```

| 選項 | 說明 |
|---|---|
| `-H, --host HOST` | 遠端主機，也可以寫成 `user@host` |
| `-u, --user USER` | SSH 使用者 |
| `-p, --port PORT` | SSH 連接埠 |
| `-i, --key FILE` | SSH 私鑰 |
| `-d, --dir DIR` | 遠端目錄，預設 `~/<專案資料夾名>` |
| `-b, --build CMD` | 同步**前**在本機執行 |
| `-c, --cmd CMD` | 同步**後**在遠端執行 |
| `-S, --stop CMD` | 執行前先在遠端執行的停止指令 |
| `-e, --exclude PATTERN` | 額外排除的檔案，可以重複指定 |
| `-B, --background` | 在遠端背景執行，輸出寫到遠端的 `deploy.log` |
| `-s, --sync-only` | 只同步，不執行 |
| `-n, --dry-run` | 只顯示會變動的檔案；不會跑本機建置，也不會執行 |
| `--no-delete` | 不刪除遠端多出來的檔案 |
| `--show` | 印出最終設定後結束，不連線 |
| `--self-update[=SRC]` | 更新腳本本身，見[自我更新](#自我更新) |
| `-h, --help` | 顯示說明 |

**目標名稱**：如果有給，會讀取 `.deploy.<目標名稱>.conf`。例如 `deploy pi2` 會讀 `.deploy.pi2.conf`；找不到這個檔案時會直接報錯。

## 設定來源與優先順序

設定可以來自多個地方，後面的會覆蓋前面的：

```
內建預設
  < ~/.config/deploy/config          所有專案共用
  < <專案>/.deploy.conf               這個專案的預設
  < <專案>/.deploy.<目標>.conf        指定目標時才讀
  < 環境變數 DEPLOY_*
  < 命令列選項
```

用 `deploy --show` 可以看到最後採用的值，以及實際讀了哪些設定檔。

### 設定檔格式

設定檔是 **bash 語法**，腳本會直接 `source` 它們，所以：

- 寫法是 `變數=值`，等號兩邊不能有空格。
- 值裡有空格時要加引號，例如 `RUN_CMD="make && ./app"`。
- **路徑開頭的 `~` 要加引號**，例如 `REMOTE_DIR="~/apps/x"`。沒加引號時，bash 會在**本機**展開成你本機的家目錄（例如 `/home/kuangtatang/apps/x`），遠端的使用者不同時就會放錯位置。命令列的 `-d` 和環境變數 `DEPLOY_DIR` 也一樣，要寫成 `-d '~/apps/x'`。用 `deploy --show` 檢查時，遠端目錄應該顯示 `~/...`。
- 檔案內容會被當成程式碼執行，**只放你信任的設定檔**。不要 `deploy` 別人給的專案，除非你看過裡面的 `.deploy*.conf`。

### 可用變數

| 變數 | 環境變數 | 對應選項 | 預設 | 說明 |
|---|---|---|---|---|
| `HOST` | `DEPLOY_HOST` | `-H` | （必填） | 遠端主機；可以是 IP、主機名、`user@host` 或 SSH 別名 |
| `USER_NAME` | `DEPLOY_USER` | `-u` | 空 | SSH 使用者；空的時候交給 `~/.ssh/config` 決定 |
| `PORT` | `DEPLOY_PORT` | `-p` | 空 | SSH 連接埠；空的時候交給 `~/.ssh/config` 決定 |
| `KEY` | `DEPLOY_KEY` | `-i` | 空 | SSH 私鑰路徑 |
| `REMOTE_DIR` | `DEPLOY_DIR` | `-d` | `~/<專案資料夾名>` | 遠端目錄，開頭的 `~` 會在遠端展開 |
| `BUILD_CMD` | `DEPLOY_BUILD` | `-b` | 空 | 同步前在本機專案目錄執行 |
| `RUN_CMD` | `DEPLOY_CMD` | `-c` | 空 | 同步後在遠端目錄執行；空的時候只同步 |
| `STOP_CMD` | `DEPLOY_STOP` | `-S` | 空 | 執行前在遠端目錄執行，失敗會被忽略 |
| `BACKGROUND` | — | `-B` | `0` | 設為 `1` 時在背景執行 |
| `DELETE` | — | `--no-delete` | `1` | 設為 `0` 時不刪除遠端多出來的檔案 |
| `USE_GITIGNORE` | — | — | `0` | 設為 `1` 時也套用專案的 `.gitignore` 排除規則 |
| `EXCLUDES` | — | `-e` | 見下方 | 排除清單（bash 陣列） |
| `SELF_UPDATE_SRC` | `DEPLOY_SELF_UPDATE_SRC` | — | 空 | `--self-update` 的預設來源 |

`BACKGROUND`、`DELETE`、`USE_GITIGNORE` 和 `EXCLUDES` 沒有對應的環境變數，只能在設定檔或命令列設定。

## 排除檔案

有三種排除規則，會一起套用：

1. **內建清單**：`.git/ .svn/ .hg/ .vscode/ .idea/ __pycache__/ *.pyc venv/ .venv/ node_modules/ .DS_Store Thumbs.db .deploy*.conf .deployignore`
2. **`<專案>/.deployignore`**：rsync 排除語法，每行一條規則。
3. **`.gitignore`**：只有設定 `USE_GITIGNORE=1` 時才會套用。

在設定檔裡追加排除規則時，要用 `+=`，不然會蓋掉內建清單：

```bash
EXCLUDES+=(build/ '*.log')     # 正確：追加
EXCLUDES=(build/)              # 會把內建清單整個換掉
```

### 注意：預設會刪除遠端檔案

同步時預設帶 `--delete`，遠端目錄裡**本機沒有的檔案都會被刪掉**，包括：

- 遠端建置產生的檔案，例如 `RUN_CMD="make && ./app"` 產生的 `app`、`build/`。
- 程式在遠端產生的資料、資料庫、上傳檔案等。

背景執行寫在遠端目錄的 `deploy.log` 是例外，會自動保護，不會被刪掉。

被排除的檔案不會被刪，所以要保留的東西就加進 `.deployignore`：

```
build/
data/
```

或者乾脆設定 `DELETE=0`、使用 `--no-delete`。第一次部署到既有目錄前，建議先用 `deploy -n` 確認會變動哪些檔案。

## 範例

### 共用預設：`~/.config/deploy/config`

這個檔案由 home-manager 從 `deploy/default.nix` 產生，是唯讀的 symlink。要修改的話，改 `default.nix` 裡的 `xdg.configFile."deploy/config".text`，再 switch 一次。

```bash
USER_NAME=space
USE_GITIGNORE=1
```

### 一個專案、多個目標

```bash
# .deploy.conf：所有目標共用
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
deploy pi1     # 部署到 pi1
deploy pi2     # 部署到 pi2
```

`.deploy*.conf` 已經在內建排除清單裡，不會被同步到遠端。

### 本機交叉編譯，再到遠端執行

```bash
# .deploy.conf
HOST=space-a
BUILD_CMD="GOOS=linux GOARCH=arm64 go build -o bin/app ."
RUN_CMD="./bin/app"
STOP_CMD="pkill -x app"
```

### 用環境變數或命令列臨時覆蓋

```sh
DEPLOY_HOST=10.10.10.30 deploy          # 換一台主機
deploy -c 'pytest -q' -d '~/tmp/test'   # 換執行指令和遠端目錄
deploy -s                               # 這次只同步
```

## 前景與背景執行

- **前景**（預設）：用 `ssh -t` 執行，輸出直接顯示在終端機，按 Ctrl+C 也會停掉遠端程式。
- **背景**（`-B` 或 `BACKGROUND=1`）：用 `nohup` 在遠端執行，輸出寫到 `<REMOTE_DIR>/deploy.log`，並印出 PID。要看輸出的話，可以執行：

  ```sh
  ssh space-a 'tail -f ~/apps/myapp/deploy.log'
  ```

  遠端腳本一律交給 bash 執行，所以遠端使用者的登入 shell 是 sh、dash、zsh 或 fish 都沒關係。

  背景執行的程式不會自動停止，所以通常要搭配 `STOP_CMD` 在下次部署前停掉舊程式。

## 自我更新

```sh
deploy --self-update=SRC
```

`SRC` 可以是 https URL、檔案路徑，或包含 `deploy.sh` 的 git repo 資料夾。沒有給 `SRC` 時，會使用設定裡的 `SELF_UPDATE_SRC`。如果兩者都沒有，但腳本本身位在 git repo 裡（例如用 symlink 安裝），就在那個 repo 裡執行 `git pull`。

更新前會檢查新版是 bash 腳本、語法正確，舊版會備份成 `<腳本>.bak`。

用 Nix/home-manager 安裝的版本不能自我更新，請改 `deploy/deploy.sh` 後再 switch。

## 測試

`test-deploy.sh` 用一個假的 `ssh`（在本機的假遠端家目錄裡執行指令）端到端測試同步、停止與執行，不需要真的遠端機器：

```sh
./test-deploy.sh                       # 遠端登入 shell 用 PATH 裡有的 bash/dash/zsh/fish
SHELLS="bash dash" ./test-deploy.sh
DEPLOY_BASH="bash --posix" ./test-deploy.sh
```

缺少 dash 或 fish 時，可以用 `nix shell nixpkgs#dash nixpkgs#fish -c ./test-deploy.sh`。

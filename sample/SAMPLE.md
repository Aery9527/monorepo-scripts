# sample — 消費端 `scripts/` 範例

本目錄是一個**消費端 repo `scripts/` 目錄的完整範例**：包含轉呼叫本工具集的轉發 shim，以及
消費端自有的通用維運腳本。假設的架構是工具集掛在消費端 root 的 `monorepo-scripts/`：

```
<consumer-root>/
├── monorepo-scripts/     ← 本工具集（git submodule）
├── scripts/              ← 對應本目錄的內容
└── .gitmodules
```

<a id="sample-nav"></a>

- [這裡是什麼](#what)
- [收錄的腳本](#list)
- [前置條件](#prereq)
- [安全行為](#safety)
- [設計要點](#design)
- [取用方式](#usage)

<a id="what"></a>

## 這裡是什麼

消費端 repo 的 `scripts/` 通常同時放三種東西：

| 種類 | 說明 | 是否收錄於本目錄 |
|------|------|------------------|
| 轉發 shim | 由 [link-scripts](../link-scripts.sh) 產生，轉呼叫工具集腳本 | **是**，工具集現有 7 組的產出快照 |
| 消費端自有的通用維運腳本 | 只依賴 git 與 shell，換一個 monorepo 也能直接用 | **是** |
| 消費端專屬腳本 | 與該專案的語言、框架、模組名稱綁定 | 否 |

自有腳本部分已通過與工具集相同的檢驗：不引用任何特定 repo、語言或模組名稱，也不 source
工具集的 lib，複製到任何 monorepo 的 `scripts/` 都能直接執行。外部相依只有 `git`，`.sh` 版另用
到 `dirname`（Git Bash / Linux / macOS 皆已內建），`.ps1` 版只用 PowerShell 內建功能。

[link-scripts](../link-scripts.sh) 不會掃到本目錄：它只處理工具集根目錄的 `*.sh` 與 `*.ps1`，
不遞迴進子目錄。因此這裡的同名 shim 不會被誤認為工具集的公開入口，`normalize-git-eol.ps1`
也不會被當成缺少 `.sh` 對應版本的孤兒檔。

[返回開頭](#sample-nav)

---

<a id="list"></a>

## 收錄的腳本

### 轉發 shim（工具集的公開入口）

| shim | 轉呼叫 |
|------|--------|
| `delete-branch.sh` / `.ps1` | [../delete-branch.sh](../delete-branch.sh) |
| `merge-branch.sh` / `.ps1` | [../merge-branch.sh](../merge-branch.sh) |
| `push-branch.sh` / `.ps1` | [../push-branch.sh](../push-branch.sh) |
| `switch-branch.sh` / `.ps1` | [../switch-branch.sh](../switch-branch.sh) |
| `sync-remote-branches.sh` / `.ps1` | [../sync-remote-branches.sh](../sync-remote-branches.sh) |
| `update-branch.sh` / `.ps1` | [../update-branch.sh](../update-branch.sh) |
| `root-fastpath-commit.sh` / `.ps1` | [../root-fastpath-commit.sh](../root-fastpath-commit.sh) |

內容與 [link-scripts](../link-scripts.sh) 的實際產出逐位元相同，只是預先產生好放在這裡。
`link-scripts` 自己不會有 shim（它是產生器，必須從工具集目錄直接執行）。

**這組 shim 是快照，不是活連結。** 工具集增刪工具後本目錄必須一併更新；消費端則是重跑
`link-scripts` 就會自動同步。取用方式見[下方](#usage)。

### 消費端自有腳本

| 腳本 | 平台 | 用途 |
|------|------|------|
| [rollback.sh](rollback.sh) / [rollback.ps1](rollback.ps1) | 跨平台 | 一次取消 root 與所有 submodule 的本地變更 |
| [normalize-git-eol.ps1](normalize-git-eol.ps1) | 僅 Windows | 對齊 root 與所有 submodule 的換行設定 |

`normalize-git-eol` 只有 `.ps1` 而沒有 `.sh`，這是刻意的：它處理的 `core.autocrlf`、`core.eol`
只在 Windows 上有實際作用，在 Linux/macOS 執行等同無操作。工具集根目錄「每個工具都有成對
`.ps1` 與 `.sh`」的規範不適用於本目錄。

[返回開頭](#sample-nav)

---

<a id="prereq"></a>

## 前置條件

| 項目 | 需求 | 原因 |
|------|------|------|
| Git | 2.22 以上 | [rollback](rollback.sh) 顯示分支名稱使用 `git branch --show-current`；版本過舊只會讓該欄顯示空白，不會中止執行 |
| Bash | 4 以上 | `rollback.sh` 使用 `mapfile`；腳本會自行檢查並給出明確錯誤 |
| PowerShell | 5.1 以上 | `.ps1` 以 UTF-8 BOM 儲存，PowerShell 5.1 需要 BOM 才能正確讀取中文 |
| repo 結構 | 根目錄有 `.gitmodules` | 兩支腳本都以 submodule 清單為工作對象；找不到時直接報錯並印出解析到的 root |

與工具集相同的最低版本要求，理由見[工具集說明](../README.md)。

[返回開頭](#sample-nav)

---

<a id="safety"></a>

## 安全行為

| 腳本／模式 | 副作用 | 可逆 | 防護 |
|------------|--------|------|------|
| [rollback](rollback.sh) `[1] Reset` | 各 repo `git reset --hard HEAD`，丟棄已追蹤檔案的變更 | **否** | 選單選擇 + `y` 確認兩道；非互動環境直接取消 |
| [rollback](rollback.sh) `[2] Reset + Clean` | 上述再加 `git clean -fd`，刪除 untracked 檔案與目錄 | **否** | 同上 |
| [rollback](rollback.sh) `[3] Clean only` | 各 repo `git clean -fd` | **否** | 同上 |
| [normalize-git-eol](normalize-git-eol.ps1) 預設 | 寫入 root 與各 submodule 的 `.git/config`；`-Renormalize` 預設開啟，會執行 `git add --renormalize .` 把換行修正結果放進 index | 是（設定可改回；index 可 `git reset`） | 無互動確認，執行前自行確認 |
| [normalize-git-eol](normalize-git-eol.ps1) `-ApplyGlobal` | 另外寫入**使用者全域** git config（`core.autocrlf` / `core.eol` / `core.safecrlf`），影響本機所有 repo | 是（可改回或刪除該設定） | 無互動確認；只有明確加上旗標才會執行 |

兩支腳本都不接觸 remote：不 fetch、不 push、不改動任何 remote 分支。

[返回開頭](#sample-nav)

---

<a id="design"></a>

## 設計要點

寫消費端腳本時，以下四點決定了它是「只在你這個 repo 能跑」還是「換一個 monorepo 也能跑」。

### repo root 由 git 決定，不由目錄深度決定

腳本以 `git rev-parse --show-toplevel` 取得 repo root，而不是取腳本所在目錄的上一層。用上一層
會把「腳本必須放在 root 的下一層」變成隱性契約，一旦目錄結構調整，得到的只會是看不出真因的
「找不到 `.gitmodules`」。

工具集本身另有[三段式解析](../README.md)，因為它可能是消費端的 submodule；消費端腳本住在自己
的 repo 內，單一 `--show-toplevel` 就已足夠且更直接。

### 只對「自己的 worktree」動手

`.gitmodules` 有登記但尚未 `git submodule update --init` 的 submodule，在檔案系統上只是一個空目錄。
對它執行 `git -C <該目錄> rev-parse --show-toplevel` 會沿目錄往上找到 **superproject**，於是：

```
git -C lib/not-inited reset --hard HEAD    # 實際重置的是 root，不是那個 submodule
```

這種破壞靜默且不可逆。兩支腳本都先確認目標路徑是它自己的 worktree root，否則列為「略過」並計入
`Skipped`，不會在使用者不知情的狀況下打到 root。

### submodule 路徑要分兩步取

`git config --file .gitmodules --get-regexp path` 的每一行是 `<鍵> <值>`，但 submodule 名稱預設等於
它的路徑，路徑含空白時**鍵本身就含空白**：

```
submodule.lib/my dep.path lib/my dep
```

用 `awk '{print $2}'` 或 `cut -d' ' -f2-` 按空格切都會取錯。改成先用 `--name-only` 取鍵，再逐一
`--get <鍵>` 取值，才不受空白影響。

### 互動輸入失敗即取消

選單迴圈必須處理「讀不到輸入」：在非互動環境下不處理會變成無限迴圈刷「無效選擇」。
`rollback.sh` 以 `read` 的回傳值判斷，`rollback.ps1` 以 `[Console]::IsInputRedirected` 提前擋下，
兩者都選擇取消而非猜測使用者意圖 —— 這是不可逆操作的正確預設。

[返回開頭](#sample-nav)

---

<a id="usage"></a>

## 取用方式

### 建立新的消費端 repo

```bash
git submodule add <this-repo-url> monorepo-scripts
mkdir -p scripts
cp monorepo-scripts/sample/*.sh monorepo-scripts/sample/*.ps1 scripts/
chmod +x scripts/*.sh
```

`SAMPLE.md` 不要複製，它是本目錄的說明文件。

**shim 的相對路徑寫死在檔案內**（`../monorepo-scripts/<name>.sh`），所以上面這組檔案只在
工具集掛載於 root 的 `monorepo-scripts/` 時可直接使用。改掛在別的位置（例如
`tools/monorepo-scripts`）時，複製後**必須**再跑一次產生器覆寫路徑：

```bash
./tools/monorepo-scripts/link-scripts.sh
```

任何情況下重跑 `link-scripts` 都是安全且推薦的：它會依實際掛載位置重算路徑、補上工具集
新增的工具、並以 `git update-index --add --chmod=+x` 把 `.sh` 標記為可執行。

### 只取自有腳本

自有腳本不含任何寫死路徑，複製過去即可執行，不需要改路徑，也不需要 source 本工具集的 lib。

```bash
cp monorepo-scripts/sample/rollback.sh  scripts/
cp monorepo-scripts/sample/rollback.ps1 scripts/
chmod +x scripts/rollback.sh
```

### 檔案格式與命名

`.sh` 必須是 LF 換行（CRLF 會在 Linux/macOS 造成 `bad interpreter`），自有腳本的 `.ps1` 必須保留
UTF-8 BOM（shim 是純 ASCII，無 BOM，與產生器輸出一致）。消費端 repo 的 `.gitattributes` 加上
`* text=auto eol=lf` 可一併解決前者。

**自有腳本**的檔名嚴禁與工具集根目錄的腳本同名。[link-scripts](../link-scripts.sh) 只憑檔案內的
`AUTO-GENERATED` marker 辨識自己產生的 shim：帶 marker 的同名檔會被直接覆寫（shim 因此安全），
不帶 marker 的同名檔則判定為 collision，在寫入任何檔案前整批 `exit 1`。

[返回開頭](#sample-nav)

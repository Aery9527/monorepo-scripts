#!/bin/bash

# ===========================================
# Git Rollback（消費端腳本範例）
# 取消 root 和所有 git submodule 的本地變更
#
# 用法:
#   ./scripts/rollback.sh    互動式選單（唯一入口，無參數模式）
#
# 本檔示範「消費端自有腳本」：住在消費端 repo 的 scripts/ 下，不 source 工具集的
# lib，完全自我完備。設計理由與前置條件見同目錄的 SAMPLE.md。
# ===========================================

set -e  # 遇到錯誤立即退出

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 下方以 mapfile 讀取 submodule 清單，需要 Bash 4 以上。缺少時的原生錯誤是
# "mapfile: command not found"，看不出真因，提前擋下。
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERROR: 本腳本需要 Bash 4 以上版本（目前偵測到：${BASH_VERSION:-未知}）。" >&2
    echo "       macOS 內建 /bin/bash 常年停留在 3.2，請改用 Homebrew 安裝的較新版 bash。" >&2
    exit 1
fi

# 解析 repo root。消費端腳本住在自己的 repo 內，直接問 git 即可；
# 不可用 dirname "$SCRIPT_DIR"，那會把「腳本必須放在 root 的下一層」變成隱性契約，
# 一旦目錄結構調整只會得到看不出真因的「找不到 .gitmodules」。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || PROJECT_ROOT=""
if [ -z "$PROJECT_ROOT" ]; then
    echo -e "${RED}ERROR: $SCRIPT_DIR 不在任何 git repo 內，無法解析 repo root${NC}" >&2
    exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
cd "$PROJECT_ROOT"

# 確認 $1 是「它自己的」git worktree root。
# 未初始化的 submodule 只是個空目錄，git 會沿著目錄往上找到 superproject —— 此時
# git reset --hard 會打在 root 上而不是該 submodule，靜默且不可逆，必須先擋下。
# 用 -ef 比對實體 inode：git 回傳 C:/... 而 pwd 回傳 /c/...，字串比對會誤判。
is_own_worktree() {
    local path="$1" top
    [ -d "$path" ] || return 1
    top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    [ "$top" -ef "$path" ]
}

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Rollback${NC}"
echo -e "${CYAN}==========================================${NC}"
echo

# 取得所有 submodule 路徑。submodule 名稱預設等於路徑，路徑含空白時「鍵」本身就含空白，
# 因此不能用 awk/cut 按空格切 key 與 value —— 改成先取 key 再逐一 --get 取值。
mapfile -t SUBMODULES < <(
    git config --file .gitmodules --name-only --get-regexp path |
    while IFS= read -r cfg_key; do
        git config --file .gitmodules --get "$cfg_key"
    done
)

if [ ${#SUBMODULES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No submodules found in this repository${NC}"
    echo -e "${RED}       解析到的 repo root: $PROJECT_ROOT${NC}"
    exit 1
fi

echo -e "${BLUE}Found submodules:${NC}"
root_current=$(git branch --show-current 2>/dev/null)
echo -e "  - ${CYAN}root${NC} ($root_current)"
for submodule in "${SUBMODULES[@]}"; do
    if is_own_worktree "$PROJECT_ROOT/$submodule"; then
        current=$(git -C "$PROJECT_ROOT/$submodule" branch --show-current 2>/dev/null)
        echo "  - $submodule ($current)"
    else
        echo -e "  - $submodule ${YELLOW}(未初始化，將略過)${NC}"
    fi
done
echo

# 顯示操作選單
echo -e "${RED}==========================================${NC}"
echo -e "${RED}選擇 rollback 操作：${NC}"
echo -e "${RED}==========================================${NC}"
echo
echo -e "  ${CYAN}[1]${NC} Reset changes        - 還原所有已追蹤檔案的變更 (git reset --hard HEAD)"
echo -e "  ${CYAN}[2]${NC} Reset + Clean        - 還原變更並移除 untracked 檔案/目錄 (git reset --hard HEAD && git clean -fd)"
echo -e "  ${CYAN}[3]${NC} Clean only           - 僅移除 untracked 檔案/目錄 (git clean -fd)"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${RED}==========================================${NC}"

while true; do
    # read 失敗代表 stdin 已結束（非互動執行）。不處理會讓選單無限迴圈刷「無效選擇」。
    if ! read -r -p "請輸入選擇 (1-3/c): " choice; then
        echo
        echo -e "${YELLOW}非互動環境，無法讀取選擇。Operation cancelled.${NC}"
        exit 0
    fi

    case "$choice" in
        [Cc])
            echo -e "${YELLOW}Operation cancelled.${NC}"
            exit 0
            ;;
        1)
            OPERATION="reset"
            OP_DESC="Reset all tracked file changes (git reset --hard HEAD)"
            break
            ;;
        2)
            OPERATION="reset_clean"
            OP_DESC="Reset changes + remove untracked files (git reset --hard HEAD && git clean -fd)"
            break
            ;;
        3)
            OPERATION="clean"
            OP_DESC="Remove untracked files (git clean -fd)"
            break
            ;;
        *)
            echo -e "${RED}無效選擇，請輸入 1-3 或 c${NC}"
            ;;
    esac
done

echo
echo -e "${RED}==========================================${NC}"
echo -e "${RED}  ⚠  WARNING: This action cannot be undone!${NC}"
echo -e "${RED}  $OP_DESC${NC}"
echo -e "${RED}  Applies to: root and ALL submodules${NC}"
echo -e "${RED}==========================================${NC}"
echo

if ! read -r -p "確認要執行此操作？(y/N): " confirm; then
    confirm=""
    echo
fi
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 0
fi
echo

# 執行 rollback
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_REPOS=()

set +e

do_rollback() {
    local repo_path="$1"
    local repo_name="$2"

    echo -e "${BLUE}Processing ${CYAN}$repo_name${BLUE}...${NC}"

    # 不是自己的 worktree 就略過：這裡若放行，git 會往上找到 superproject 而把
    # reset --hard 打在 root 上。
    if ! is_own_worktree "$repo_path"; then
        echo -e "${YELLOW}  - 略過：$repo_name 未初始化或不是獨立的 git worktree${NC}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    if [ "$OPERATION" = "reset" ] || [ "$OPERATION" = "reset_clean" ]; then
        git -C "$repo_path" reset --hard HEAD 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}  ✗ ERROR: git reset --hard HEAD failed${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$repo_name")
            return
        fi
    fi

    if [ "$OPERATION" = "clean" ] || [ "$OPERATION" = "reset_clean" ]; then
        git -C "$repo_path" clean -fd 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}  ✗ ERROR: git clean -fd failed${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$repo_name")
            return
        fi
    fi

    echo -e "${GREEN}  ✓ Done${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
}

# 先處理 submodule 再處理 root：root 的 clean -fd 不會誤刪 submodule 內容，
# 但先做 root 會讓中途失敗時的狀態更難判讀。
for submodule in "${SUBMODULES[@]}"; do
    do_rollback "$PROJECT_ROOT/$submodule" "$submodule"
done

do_rollback "$PROJECT_ROOT" "root"

# 顯示結果
echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Summary${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}  Successful: $SUCCESS_COUNT${NC}"
echo -e "${YELLOW}  Skipped:    $SKIP_COUNT${NC}"
echo -e "${RED}  Failed:     $FAIL_COUNT${NC}"

if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    echo
    echo -e "${RED}Failed repositories:${NC}"
    for failed in "${FAILED_REPOS[@]}"; do
        echo -e "  ${RED}✗ $failed${NC}"
    done
    exit 1
fi

echo
echo -e "${GREEN}✓ All repositories rolled back successfully!${NC}"
echo

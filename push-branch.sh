#!/bin/bash

# ===========================================
# Git Submodule Push Branch
# 一次對 root 和所有 git submodule 執行 push
# ===========================================

set -e  # 遇到錯誤立即退出

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 切換到專案根目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/repo-aliases.sh"
PROJECT_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$PROJECT_ROOT")"
load_repo_alias_map "$PROJECT_ROOT"
cd "$PROJECT_ROOT"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Submodule Push Branch${NC}"
echo -e "${CYAN}==========================================${NC}"
echo

# 取得所有 submodule 路徑（cut 保留空白後的完整值；mapfile 逐行讀入陣列，避免遍歷時被字詞分割）
mapfile -t SUBMODULES < <(git config --file .gitmodules --get-regexp path | cut -d' ' -f2-)

if [ ${#SUBMODULES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No submodules found in this repository${NC}"
    echo -e "${RED}       解析到的 repo root: $PROJECT_ROOT${NC}"
    exit 1
fi

echo -e "${BLUE}Found submodules:${NC}"
root_current=$(git branch --show-current)
echo -e "  - ${CYAN}root${NC} ($root_current)"
for submodule in "${SUBMODULES[@]}"; do
    current=$(cd "$PROJECT_ROOT/$submodule" && git branch --show-current 2>/dev/null) || current=""
    echo "  - $submodule ($current)"
done
echo

# -----------------------------------------------------------------------
# Push Status Table
# -----------------------------------------------------------------------
DARKGRAY='\033[1;30m'

_pb_collect_row() {
    local repo_name="$1" repo_path="$2"
    local short branch upstream ahead upstream_disp hint ahead_n
    short=$(repo_short_name "$repo_name")
    branch=$(git -C "$repo_path" branch --show-current 2>/dev/null) || branch=""
    upstream=$(git -C "$repo_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || upstream=""
    if [ -z "$upstream" ]; then
        ahead="--"
        upstream_disp="(無 upstream)"
        hint="no_upstream"
    else
        ahead_n=$(git -C "$repo_path" rev-list '@{upstream}..HEAD' --count 2>/dev/null) || ahead_n=""
        if [[ "$ahead_n" =~ ^[0-9]+$ ]]; then ahead="+$ahead_n"; else ahead="--"; fi
        upstream_disp="$upstream"
        if [ "$ahead_n" = "0" ]; then hint="synced"; else hint="needs_push"; fi
    fi
    if [ ${#short}  -gt $((pb_name_w   - 2)) ]; then pb_name_w=$((${#short}  + 2)); fi
    if [ ${#branch} -gt $((pb_branch_w - 2)) ]; then pb_branch_w=$((${#branch} + 2)); fi
    pb_rows+=("${short}|${branch}|${ahead}|${upstream_disp}|${hint}")
}

pb_name_w=8
pb_branch_w=14
pb_rows=()
_pb_collect_row "root" "$PROJECT_ROOT"
for submodule in "${SUBMODULES[@]}"; do
    _pb_collect_row "$submodule" "$PROJECT_ROOT/$submodule"
done

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   Push 狀態 — 各 repo 目前分支${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "${DARKGRAY}  +N = 本地領先 N 個 commit（待 push）   -- = 無 upstream${NC}"
echo
pb_header=$(printf "  %-*s %-*s %7s  %s" "$pb_name_w" "名稱" "$pb_branch_w" "Branch" "Ahead" "Upstream")
echo -e "${BLUE}${pb_header}${NC}"
pb_sep_len=$((pb_name_w + pb_branch_w + 7 + 14))
pb_sep=$(printf '%*s' "$pb_sep_len" '' | tr ' ' '-')
echo -e "${DARKGRAY}  ${pb_sep}${NC}"
for pb_row in "${pb_rows[@]}"; do
    IFS='|' read -r pb_short pb_branch pb_ahead pb_upstream pb_hint <<< "$pb_row"
    pb_line=$(printf "  %-*s %-*s %7s  %s" "$pb_name_w" "$pb_short" "$pb_branch_w" "$pb_branch" "$pb_ahead" "$pb_upstream")
    if   [[ "$pb_hint" == "no_upstream" ]]; then echo -e "${YELLOW}${pb_line}${NC}"
    elif [[ "$pb_hint" == "synced"      ]]; then echo -e "${GREEN}${pb_line}${NC}"
    else                                         echo -e "${CYAN}${pb_line}${NC}"
    fi
done
echo

# 顯示選單
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}選擇操作：${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "  ${CYAN}[1]${NC} Push — 推送本地 commit 到遠端 (git push)"
echo -e "  ${CYAN}[2]${NC} Push 並設定 upstream (git push -u $REMOTE <branch>)"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${BLUE}==========================================${NC}"

# 讀取使用者輸入
while true; do
    read -p "請輸入選擇 (1-2/c): " choice

    case "$choice" in
        [Cc])
            echo -e "${YELLOW}Operation cancelled.${NC}"
            exit 0
            ;;
        1)
            OPERATION="push"
            OP_DESC="Pushing"
            GIT_CMD="git push"
            break
            ;;
        2)
            OPERATION="push-upstream"
            OP_DESC="Pushing with upstream"
            break
            ;;
        *)
            echo -e "${RED}無效選擇，請輸入 1、2 或 c${NC}"
            ;;
    esac
done

echo
echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}$OP_DESC root and all submodules...${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo

# 確認操作
read -p "確認要執行此操作？(y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 0
fi
echo

# 執行操作
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_REPOS=()

# 關閉 set -e 以便處理錯誤
set +e

# 先處理 root repository
echo -e "${BLUE}Processing ${CYAN}root${BLUE}...${NC}"
cd "$PROJECT_ROOT"

if [ "$OPERATION" = "push-upstream" ]; then
    CURRENT_BRANCH=$(git branch --show-current)
    git push -u "$REMOTE" "$CURRENT_BRANCH" 2>&1
    result=$?
else
    $GIT_CMD 2>&1
    result=$?
fi

if [ $result -eq 0 ]; then
    echo -e "${GREEN}  ✓ $OP_DESC successful${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    echo -e "${RED}  ✗ ERROR: $OP_DESC failed${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_REPOS+=("root")
fi

# 處理 submodules
for submodule in "${SUBMODULES[@]}"; do
    echo -e "${BLUE}Processing ${CYAN}$submodule${BLUE}...${NC}"

    sub_path="$PROJECT_ROOT/$submodule"
    # 用 .git 是否存在判斷 submodule 是否已初始化；不可用 `git -C` 探測，
    # 因為空目錄會被 git 往上層目錄尋根，誤判為已初始化的父層 repo。
    if [ ! -e "$sub_path/.git" ]; then
        echo -e "${RED}  ✗ ERROR: submodule directory missing/uninitialized: $submodule${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("$submodule (missing/uninitialized submodule)")
        continue
    fi

    if [ "$OPERATION" = "push-upstream" ]; then
        CURRENT_BRANCH=$(git -C "$sub_path" branch --show-current)
        git -C "$sub_path" push -u "$REMOTE" "$CURRENT_BRANCH" 2>&1
        result=$?
    else
        git -C "$sub_path" push 2>&1
        result=$?
    fi

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}  ✓ $OP_DESC successful${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}  ✗ ERROR: $OP_DESC failed${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("$submodule")
    fi
done

# 顯示結果
echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Summary${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}  Successful: $SUCCESS_COUNT${NC}"
echo -e "${RED}  Failed: $FAIL_COUNT${NC}"

if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    echo
    echo -e "${RED}Failed repositories:${NC}"
    for failed in "${FAILED_REPOS[@]}"; do
        echo -e "  ${RED}✗ $failed${NC}"
    done
    exit 1
fi

echo
echo -e "${GREEN}✓ All repositories pushed successfully!${NC}"
echo

#!/bin/bash

# ===========================================
# Git Submodule Branch Switcher
# 一次切換 root 和所有 git submodule 到相同的 branch
#
# 用法:
#   ./monorepo-scripts/switch-branch.sh              互動式選單
#   ./monorepo-scripts/switch-branch.sh <branch>     非互動：直接切換到指定分支
# ===========================================

set -e  # 遇到錯誤立即退出

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
GRAY='\033[90m'

# Load repo alias lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/repo-aliases.sh"
PROJECT_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$PROJECT_ROOT")"
load_repo_alias_map "$PROJECT_ROOT"

# Helper: 切換完成後，若當前 branch 缺 upstream 但 <remote>/<branch> 存在，自動補 tracking。
# 解決 "git checkout -b develop"（無來源）會留下無 upstream 本地 branch 的痼疾，
# 避免之後 git pull 出現 "no tracking information" 錯誤。
ensure_upstream() {
    local cur_branch
    cur_branch=$(git branch --show-current 2>/dev/null)
    [ -z "$cur_branch" ] && return 0

    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        return 0
    fi

    if git show-ref --verify --quiet "refs/remotes/$REMOTE/$cur_branch" 2>/dev/null; then
        if git branch --set-upstream-to="$REMOTE/$cur_branch" "$cur_branch" --quiet >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ upstream 已自動補上 -> $REMOTE/$cur_branch${NC}"
        fi
    fi
    return 0
}

# Helper: run git checkout and surface clear error if blocked by untracked files
do_checkout() {
    local checkout_err exit_code
    checkout_err=$(git "$@" 2>&1)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        if echo "$checkout_err" | grep -q "untracked working tree"; then
            echo -e "${RED}  ✗ ERROR: Checkout blocked — untracked files would be overwritten by target branch:${NC}"
            echo "$checkout_err" | grep -v "^$" | while IFS= read -r line; do
                echo -e "    ${RED}$line${NC}"
            done
            echo -e "${YELLOW}      Fix: move or remove the conflicting untracked files, then retry.${NC}"
        else
            echo -e "${RED}  ✗ ERROR: Failed to checkout (${*})${NC}"
            [ -n "$checkout_err" ] && echo -e "    ${RED}${checkout_err}${NC}"
        fi
    fi
    return $exit_code
}

# 解析命令列參數
NON_INTERACTIVE=false
TARGET_BRANCH=""
CREATE_IF_NOT_EXISTS=false
FETCH_MODE=0

if [ -n "${1:-}" ]; then
    NON_INTERACTIVE=true
    TARGET_BRANCH="$1"
    CREATE_IF_NOT_EXISTS=true
    FETCH_MODE=0
fi

# 切換到專案根目錄
cd "$PROJECT_ROOT"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Submodule Branch Switcher${NC}"
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
root_current=$(git branch --show-current 2>/dev/null)
echo -e "  - ${CYAN}root${NC} ($root_current)"
for submodule in "${SUBMODULES[@]}"; do
    current=$(cd "$PROJECT_ROOT/$submodule" && git branch --show-current 2>/dev/null) || current=""
    echo "  - $submodule ($current)"
done
echo

if [ "$NON_INTERACTIVE" = false ]; then
# 詢問使用者要使用本地分支還是遠端分支
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}Select operation mode:${NC}"
echo -e "${CYAN}==========================================${NC}"
echo

echo -e "  ${GREEN}[1]${NC} 僅使用本地分支（不 fetch）"
echo -e "  ${GREEN}[2]${NC} 先 fetch 遠端分支（建議）"
echo

echo -e "  ${YELLOW}[c]${NC} 取消"
echo

echo -e "${CYAN}==========================================${NC}"

while true; do
    read -p "請輸入選擇 (1-2/c): " mode_choice

    if [ "$mode_choice" = "c" ] || [ "$mode_choice" = "C" ]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    elif [ "$mode_choice" = "1" ]; then
        echo -e "${GREEN}✓ Using local branches only${NC}"
        FETCH_MODE=0
        echo
        break
    elif [ "$mode_choice" = "2" ]; then
        echo -e "${GREEN}✓ Fetching remote branches...${NC}"
        FETCH_MODE=1
        echo

        # Fetch all remotes for root and each submodule
        echo -e "  Fetching ${CYAN}root${NC}..."
        git fetch --all --quiet || {
            echo -e "${RED}ERROR: Failed to fetch in root${NC}"
            exit 1
        }
        for submodule in "${SUBMODULES[@]}"; do
            echo -e "  Fetching ${CYAN}$submodule${NC}..."
            (cd "$submodule" && git fetch --all --quiet) || {
                echo -e "${RED}ERROR: Failed to fetch in $submodule${NC}"
                exit 1
            }
        done
        echo -e "${GREEN}✓ Fetch completed${NC}"
        echo
        break
    else
        echo -e "${RED}無效選擇，請輸入 1、2 或 c${NC}"
    fi
done
fi  # end NON_INTERACTIVE fetch selection

# ---------------------------------------------------------------------------
# Branch Audit Matrix — 顯示各分支在各 repo 的分佈狀態
# ---------------------------------------------------------------------------
if [ "$NON_INTERACTIVE" = false ]; then
    SW_TMPFILE=$(mktemp)
    sw_audit_cleanup() { rm -f "$SW_TMPFILE"; }
    trap sw_audit_cleanup EXIT INT TERM

    SW_REPOS_LIST=("root" "${SUBMODULES[@]}")

    for repo in "${SW_REPOS_LIST[@]}"; do
        if [ "$repo" = "root" ]; then
            sw_rpath="$PROJECT_ROOT"
        else
            sw_rpath="$PROJECT_ROOT/$repo"
        fi
        sw_cur_b=$(git -C "$sw_rpath" branch --show-current 2>/dev/null || echo "")
        echo "CUR|${repo}|${sw_cur_b}" >> "$SW_TMPFILE"
        git -C "$sw_rpath" branch --format='%(refname:short)' 2>/dev/null | \
            grep -v '^$' | while IFS= read -r b; do echo "L|${repo}|${b}"; done >> "$SW_TMPFILE"
        # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
        git -C "$sw_rpath" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" 2>/dev/null |
            grep -v '^HEAD$' | grep -v '^$' | sort -u |
            while IFS= read -r b; do echo "R|${repo}|${b}"; done >> "$SW_TMPFILE"
    done

    SW_ALL_BRANCHES=$(grep '^[LR]|' "$SW_TMPFILE" | cut -d'|' -f3 | sort -u)
    if [ -n "$SW_ALL_BRANCHES" ]; then
        SW_B_COL=24
        while IFS= read -r b; do
            if [ -z "$b" ]; then continue; fi
            blen=$(( ${#b} + 2 ))
            if [ $blen -gt $SW_B_COL ]; then SW_B_COL=$blen; fi
        done <<< "$SW_ALL_BRANCHES"

        SW_R_COL=6
        for repo in "${SW_REPOS_LIST[@]}"; do
            sn=$(repo_short_name "$repo")
            rcol=$(( ${#sn} + 2 ))
            if [ $rcol -gt $SW_R_COL ]; then SW_R_COL=$rcol; fi
        done

        echo -e "${BLUE}==========================================${NC}"
        echo -e "${BLUE}   Branch Audit — 各分支分佈狀態${NC}"
        echo -e "${BLUE}==========================================${NC}"
        echo

        echo -e "${GRAY}  v=local+remote   L=local-only   R=remote-only   -=不存在${NC}"
        echo -e "${GRAY}  （青字列 = 目前所在 branch）${NC}"
        echo

        sw_hdr=$(printf "  %-${SW_B_COL}s" "Branch")
        for repo in "${SW_REPOS_LIST[@]}"; do
            sn=$(repo_short_name "$repo")
            sw_hdr="${sw_hdr}$(printf "%${SW_R_COL}s" "$sn")"
        done
        echo -e "${BLUE}${sw_hdr}${NC}"

        sw_total_w=$(( SW_B_COL ))
        for repo in "${SW_REPOS_LIST[@]}"; do sw_total_w=$(( sw_total_w + SW_R_COL )); done
        echo -e "${GRAY}  $(printf "%${sw_total_w}s" "" | tr ' ' '-')${NC}"

        while IFS= read -r branch; do
            if [ -z "$branch" ]; then continue; fi
            sw_line=$(printf "  %-${SW_B_COL}s" "$branch")
            sw_is_cur=false
            sw_is_issue=false
            for repo in "${SW_REPOS_LIST[@]}"; do
                if grep -qF "L|${repo}|${branch}" "$SW_TMPFILE" 2>/dev/null; then has_l=1; else has_l=0; fi
                if grep -qF "R|${repo}|${branch}" "$SW_TMPFILE" 2>/dev/null; then has_r=1; else has_r=0; fi
                sw_repo_cur=$(grep "^CUR|${repo}|" "$SW_TMPFILE" | cut -d'|' -f3)
                if [ "$sw_repo_cur" = "$branch" ]; then sw_is_cur=true; fi
                if [ $has_l -eq 1 ] && [ $has_r -eq 1 ]; then
                    cell="v"
                elif [ $has_l -eq 1 ]; then
                    cell="L"; sw_is_issue=true
                elif [ $has_r -eq 1 ]; then
                    cell="R"; sw_is_issue=true
                else
                    cell="-"
                fi
                sw_line="${sw_line}$(printf "%${SW_R_COL}s" "$cell")"
            done
            if [ "$sw_is_cur" = true ]; then
                echo -e "${CYAN}${sw_line}${NC}"
            elif [ "$sw_is_issue" = true ]; then
                echo -e "${YELLOW}${sw_line}${NC}"
            else
                echo -e "${GREEN}${sw_line}${NC}"
            fi
        done <<< "$SW_ALL_BRANCHES"
        echo
    fi

    trap - EXIT INT TERM
    rm -f "$SW_TMPFILE"
fi

if [ "$NON_INTERACTIVE" = false ]; then
# 直接使用 audit matrix 已收集的 SW_ALL_BRANCHES（全 repo 所有 branch 的 union）
sorted_branches=()
while IFS= read -r b; do
    [ -n "$b" ] && sorted_branches+=("$b")
done <<< "$SW_ALL_BRANCHES"

echo -e "${GREEN}✓ Found ${#sorted_branches[@]} 個分支（有缺失的 repo 切換時將自動建立本地 branch）${NC}"
echo

# 顯示選單
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}選擇要切換的目標分支：${NC}"
echo -e "${BLUE}==========================================${NC}"
echo

idx=1
for branch in "${sorted_branches[@]}"; do
    echo -e "  ${CYAN}[$idx]${NC} $branch"
    ((idx++))
done
echo

echo -e "  ${CYAN}[e]${NC} 輸入自訂分支名稱（若不存在將自動建立）"
echo

echo -e "  ${YELLOW}[c]${NC} 取消"
echo

echo -e "${BLUE}==========================================${NC}"

# 讀取使用者輸入
while true; do
    read -p "請輸入選擇 (1-${#sorted_branches[@]}/e/c): " choice

    if [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    elif [ "$choice" = "e" ] || [ "$choice" = "E" ]; then
        # 使用者選擇輸入自訂分支名稱
        read -p "輸入新分支名稱：" custom_branch
        if [ -z "$custom_branch" ]; then
            echo -e "${RED}ERROR: Branch name cannot be empty${NC}"
            continue
        fi
        TARGET_BRANCH="$custom_branch"
        CREATE_IF_NOT_EXISTS=true
        break
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#sorted_branches[@]}" ]; then
            TARGET_BRANCH="${sorted_branches[$((choice-1))]}"
            CREATE_IF_NOT_EXISTS=true
            break
        fi
    fi
    echo -e "${RED}無效選擇，請輸入 1 到 ${#sorted_branches[@]} 的數字、e 或 c${NC}"
done
fi  # end NON_INTERACTIVE branch selection

echo

echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}Switching root and all submodules to: ${CYAN}$TARGET_BRANCH${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo

# 確認操作
if [ "$NON_INTERACTIVE" = false ]; then
    read -p "確認要執行此操作？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi
fi
echo

# 執行分支切換
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_REPOS=()

# 先切換 root repository
echo -e "${BLUE}Switching ${CYAN}root${BLUE}...${NC}"
cd "$PROJECT_ROOT"

# 檢查是否有未提交的變更
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${RED}  ✗ ERROR: root has uncommitted changes${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_REPOS+=("root (uncommitted changes)")
    echo -e "${RED}Aborting due to error.${NC}"
else
    # 偵測 skip-worktree 標記的檔案（git diff/status 會略過，但 checkout 不會）
    SW_LIST=$(git ls-files -v 2>/dev/null | grep '^S ' | cut -c3- | tr '\n' ' ')
    if [ -n "$SW_LIST" ]; then
        echo -e "${YELLOW}  ! WARNING: root has skip-worktree files: ${SW_LIST}${NC}"
        echo -e "${YELLOW}    These are hidden from git status but may block checkout.${NC}"
        echo -e "${YELLOW}    Fix: git update-index --no-skip-worktree <file> && git checkout -- <file>${NC}"
    fi
    # 偵測 untracked 檔案（僅提示，不 block）
    UNTRACKED_LIST=$(git ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$UNTRACKED_LIST" ]; then
        echo -e "${GRAY}  ! INFO: root has untracked files (will be ignored during switch):${NC}"
        echo "$UNTRACKED_LIST" | while IFS= read -r f; do echo -e "${GRAY}      $f${NC}"; done
        echo -e "${GRAY}      Safe unless the target branch has committed files at the same paths.${NC}"
    fi
    # 檢查分支是否存在（本地或遠端）
    if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" 2>/dev/null; then
        # 本地分支存在，直接切換
        if do_checkout checkout "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Switched to existing local branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root (checkout failed)")
            echo -e "${RED}Aborting due to error.${NC}"
        fi
    elif git show-ref --verify --quiet "refs/remotes/$REMOTE/$TARGET_BRANCH" 2>/dev/null; then
        # 遠端分支存在，建立追蹤分支；若本地已存在則 fallback 到 plain checkout
        if git checkout -b "$TARGET_BRANCH" "$REMOTE/$TARGET_BRANCH" --quiet 2>/dev/null || do_checkout checkout "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Switched to remote tracking branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root (checkout failed)")
            echo -e "${RED}Aborting due to error.${NC}"
        fi
    elif [ "$CREATE_IF_NOT_EXISTS" = true ]; then
        # 分支不存在，建立新分支
        if do_checkout checkout -b "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Created and switched to new branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root (create branch failed)")
            echo -e "${RED}Aborting due to error.${NC}"
        fi
    else
        echo -e "${YELLOW}  ! Branch $TARGET_BRANCH does not exist in root${NC}"
        read -p "是否要建立此分支？(y/N): " create_branch
        if [[ "$create_branch" =~ ^[Yy]$ ]]; then
            if do_checkout checkout -b "$TARGET_BRANCH" --quiet; then
                echo -e "${GREEN}  ✓ Created and switched to new branch${NC}"
                ensure_upstream
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                CREATE_IF_NOT_EXISTS=true
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAILED_REPOS+=("root (create branch failed)")
                echo -e "${RED}Aborting due to error.${NC}"
            fi
        else
            echo -e "${RED}  ✗ ERROR: Branch $TARGET_BRANCH does not exist${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root (branch not found)")
            echo -e "${RED}Aborting due to error.${NC}"
        fi
    fi
fi

# 如果 root 切換失敗，中斷
if [ $FAIL_COUNT -gt 0 ]; then
    echo

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}   Summary${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}  Successful: $SUCCESS_COUNT${NC}"
    echo -e "${RED}  Failed: $FAIL_COUNT${NC}"
    echo

    echo -e "${RED}Failed repositories:${NC}"
    for failed in "${FAILED_REPOS[@]}"; do
        echo -e "  ${RED}✗ $failed${NC}"
    done
    exit 1
fi

# 切換 submodules
for submodule in "${SUBMODULES[@]}"; do
    echo -e "${BLUE}Switching ${CYAN}$submodule${BLUE}...${NC}"

    sub_path="$PROJECT_ROOT/$submodule"
    # 用 .git 是否存在判斷 submodule 是否已初始化。光靠 cd 成功與否不夠：
    # 未初始化的 submodule 仍是存在的空目錄，cd 進去不會失敗，但目錄內任何
    # git 指令都會往上層目錄尋根，誤判為已初始化的父層 repo。
    if [ ! -e "$sub_path/.git" ] || ! cd "$sub_path" 2>/dev/null; then
        echo -e "${RED}  ✗ ERROR: $submodule directory missing/uninitialized${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("$submodule (missing/uninitialized submodule)")
        cd "$PROJECT_ROOT"
        break
    fi

    # 檢查是否有未提交的變更
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo -e "${RED}  ✗ ERROR: $submodule has uncommitted changes${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("$submodule (uncommitted changes)")
        cd "$PROJECT_ROOT"
        echo -e "${RED}Aborting due to error.${NC}"
        break
    fi

    # 偵測 skip-worktree 標記的檔案（git diff/status 會略過，但 checkout 不會）
    SW_LIST=$(git ls-files -v 2>/dev/null | grep '^S ' | cut -c3- | tr '\n' ' ')
    if [ -n "$SW_LIST" ]; then
        echo -e "${YELLOW}  ! WARNING: $submodule has skip-worktree files: ${SW_LIST}${NC}"
        echo -e "${YELLOW}    These are hidden from git status but may block checkout.${NC}"
        echo -e "${YELLOW}    Fix: git update-index --no-skip-worktree <file> && git checkout -- <file>${NC}"
    fi
    # 偵測 untracked 檔案（僅提示，不 block）
    UNTRACKED_LIST=$(git ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$UNTRACKED_LIST" ]; then
        echo -e "${GRAY}  ! INFO: $submodule has untracked files (will be ignored during switch):${NC}"
        echo "$UNTRACKED_LIST" | while IFS= read -r f; do echo -e "${GRAY}      $f${NC}"; done
        echo -e "${GRAY}      Safe unless the target branch has committed files at the same paths.${NC}"
    fi

    # 檢查分支是否存在（本地或遠端）
    if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" 2>/dev/null; then
        # 本地分支存在，直接切換
        if do_checkout checkout "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Switched to existing local branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule (checkout failed)")
            cd "$PROJECT_ROOT"
            echo -e "${RED}Aborting due to error.${NC}"
            break
        fi
    elif git show-ref --verify --quiet "refs/remotes/$REMOTE/$TARGET_BRANCH" 2>/dev/null; then
        # 遠端分支存在，建立追蹤分支；若本地已存在則 fallback 到 plain checkout
        if git checkout -b "$TARGET_BRANCH" "$REMOTE/$TARGET_BRANCH" --quiet 2>/dev/null || do_checkout checkout "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Switched to remote tracking branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule (checkout failed)")
            cd "$PROJECT_ROOT"
            echo -e "${RED}Aborting due to error.${NC}"
            break
        fi
    elif [ "$CREATE_IF_NOT_EXISTS" = true ]; then
        # 分支不存在，建立新分支
        if do_checkout checkout -b "$TARGET_BRANCH" --quiet; then
            echo -e "${GREEN}  ✓ Created and switched to new branch${NC}"
            ensure_upstream
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule (create branch failed)")
            cd "$PROJECT_ROOT"
            echo -e "${RED}Aborting due to error.${NC}"
            break
        fi
    else
        echo -e "${YELLOW}  ! Branch $TARGET_BRANCH does not exist in $submodule${NC}"
        read -p "是否要建立此分支？(y/N): " create_branch
        if [[ "$create_branch" =~ ^[Yy]$ ]]; then
            if do_checkout checkout -b "$TARGET_BRANCH" --quiet; then
                echo -e "${GREEN}  ✓ Created and switched to new branch${NC}"
                ensure_upstream
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                CREATE_IF_NOT_EXISTS=true
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAILED_REPOS+=("$submodule (create branch failed)")
                cd "$PROJECT_ROOT"
                echo -e "${RED}Aborting due to error.${NC}"
                break
            fi
        else
            echo -e "${RED}  ✗ ERROR: Branch $TARGET_BRANCH does not exist${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule (branch not found)")
            cd "$PROJECT_ROOT"
            echo -e "${RED}Aborting due to error.${NC}"
            break
        fi
    fi

    cd "$PROJECT_ROOT"
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

echo -e "${GREEN}✓ Root and all submodules switched to branch: $TARGET_BRANCH${NC}"
echo

# 顯示當前 root 和各 submodule 的分支狀態
echo -e "${BLUE}Current branch status:${NC}"
root_current=$(cd "$PROJECT_ROOT" && git branch --show-current)
echo -e "  ${CYAN}root${NC}: $root_current"
for submodule in "${SUBMODULES[@]}"; do
    current=$(cd "$PROJECT_ROOT/$submodule" && git branch --show-current)
    echo -e "  ${CYAN}$submodule${NC}: $current"
done

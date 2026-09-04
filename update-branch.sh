#!/bin/bash

# ===========================================
# Git Submodule Update Branch
# 一次對 root 和所有 git submodule 執行 fetch 或 pull
# ===========================================

set -e  # 遇到錯誤立即退出

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 解決 `git fetch <remote> <branch>:<branch>` 在本地新建 branch 但不設 upstream 的痼疾。
# 在指定 repo path 上，若 Branch 本地存在、無 upstream，且 <remote>/<Branch> 存在 → 自動補 tracking。
ensure_repo_upstream_on_branch() {
    local repo_path="$1" branch="$2"
    [ -z "$branch" ] && return 0

    if ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        return 0
    fi

    if git -C "$repo_path" rev-parse --abbrev-ref "$branch@{upstream}" >/dev/null 2>&1; then
        return 0
    fi

    if ! git -C "$repo_path" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" 2>/dev/null; then
        return 0
    fi

    if git -C "$repo_path" branch --set-upstream-to="$REMOTE/$branch" "$branch" --quiet >/dev/null 2>&1; then
        echo -e "${GREEN}    ✓ upstream 自動補上 -> $REMOTE/$branch${NC}"
    fi
    return 0
}

# detached-HEAD 輔助函式，對應 update-branch.ps1 的 Get-RepoCurrentBranch／Test-RepoLocalBranchExists／
# Test-RepoRemoteBranchExists／Get-PreferredRepoBranch／Ensure-RepoAttachedToBranch。
# 讓 pull 操作在 submodule/root 處於 detached HEAD 時能自動判斷並切回正確分支。
repo_current_branch() {
    git -C "$1" branch --show-current 2>/dev/null
}

repo_local_branch_exists() {
    local repo_path="$1" branch="$2"
    [ -n "$branch" ] || { echo false; return; }
    git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" && echo true || echo false
}

repo_remote_branch_exists() {
    local repo_path="$1" branch="$2"
    [ -n "$branch" ] || { echo false; return; }
    git -C "$repo_path" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" && echo true || echo false
}

# 依 submodule path 找出 .gitmodules 中對應的 section name（[submodule "NAME"] 的 NAME
# 未必等於 path），輸出該 NAME 供呼叫端查詢 submodule.<NAME>.branch。
resolve_gitmodules_section_by_path() {
    local gitmodules_file="$1" target_path="$2"
    local line key val name
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%% *}"
        val="${line#* }"
        name="${key#submodule.}"
        name="${name%.path}"
        if [ "$val" = "$target_path" ]; then
            echo "$name"
            return 0
        fi
    done < <(git config --file "$gitmodules_file" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    return 1
}

# 判斷 detached HEAD 時該切回哪個 branch，優先順序：
# .gitmodules 的 submodule.<name>.branch 設定 → 唯一本地 branch → 唯一 remote-tracking branch。
get_preferred_repo_branch() {
    local repo_name="$1" repo_path="$2" root_branch="$3"
    local current
    current="$(repo_current_branch "$repo_path")"
    [ -n "$current" ] && { echo "$current"; return; }

    if [ "$repo_name" != "root" ]; then
        # .gitmodules 一律位於 repo 根目錄（$PROJECT_ROOT），與 submodule 巢狀深度無關；
        # section name 未必等於 path，需先反查對應的 section name 才能查詢 branch 設定。
        local gitmodules_file="$PROJECT_ROOT/.gitmodules"
        local section configured
        section="$(resolve_gitmodules_section_by_path "$gitmodules_file" "$repo_name")"
        if [ -n "$section" ]; then
            configured="$(git config --file "$gitmodules_file" --get "submodule.$section.branch" 2>/dev/null)" || true
        fi
        if [ -n "$configured" ]; then
            if [ "$configured" = "." ]; then
                if [ -n "$root_branch" ] && { [ "$(repo_local_branch_exists "$repo_path" "$root_branch")" = "true" ] || [ "$(repo_remote_branch_exists "$repo_path" "$root_branch")" = "true" ]; }; then
                    echo "$root_branch"; return
                fi
            elif [ "$(repo_local_branch_exists "$repo_path" "$configured")" = "true" ] || [ "$(repo_remote_branch_exists "$repo_path" "$configured")" = "true" ]; then
                echo "$configured"; return
            fi
        fi
    fi

    local local_branches
    local_branches="$(git -C "$repo_path" for-each-ref --format='%(refname:short)' --points-at HEAD refs/heads 2>/dev/null)"
    if [ "$(echo "$local_branches" | grep -c .)" = "1" ]; then echo "$local_branches"; return; fi

    local remote_branches
    remote_branches="$(git -C "$repo_path" for-each-ref --format='%(refname:short)' --points-at HEAD "refs/remotes/$REMOTE" 2>/dev/null | grep -v "^$REMOTE_RE$" | grep -v "^$REMOTE_RE/HEAD$" | sed "s#^$REMOTE_RE/##")"
    if [ "$(echo "$remote_branches" | grep -c .)" = "1" ]; then echo "$remote_branches"; return; fi

    echo ""
}

# 若 repo 目前 attached 到某分支，直接回傳；否則嘗試自動切回 get_preferred_repo_branch 判斷出的目標分支。
# 輸出格式：success|branch|auto_attached|message（pipe 分隔，供呼叫端 IFS 拆解，模擬 .ps1 的 PSCustomObject）。
ensure_repo_attached_to_branch() {
    local repo_name="$1" repo_path="$2" root_branch="$3"
    local current
    current="$(repo_current_branch "$repo_path")"
    if [ -n "$current" ]; then
        echo "true|$current|false|"
        return
    fi

    local target
    target="$(get_preferred_repo_branch "$repo_name" "$repo_path" "$root_branch")"
    if [ -z "$target" ]; then
        echo "false||false|detached HEAD，且無法自動判斷要切回哪個 branch"
        return
    fi

    if [ "$(repo_local_branch_exists "$repo_path" "$target")" = "true" ]; then
        git -C "$repo_path" checkout "$target" --quiet 2>/dev/null
    elif [ "$(repo_remote_branch_exists "$repo_path" "$target")" = "true" ]; then
        git -C "$repo_path" checkout -b "$target" "$REMOTE/$target" --quiet 2>/dev/null || git -C "$repo_path" checkout "$target" --quiet 2>/dev/null
    else
        echo "false|$target|false|detached HEAD，但找不到可切換的 branch '$target'"
        return
    fi

    if [ $? -ne 0 ]; then
        echo "false|$target|false|detached HEAD，切換到 branch '$target' 失敗"
        return
    fi
    echo "true|$target|true|"
}

# 對單一 repo 更新所有有 upstream 的本地分支，對應 update-branch.ps1 的 Invoke-PullAllBranches。
# 執行前先確保 HEAD 已 attach 到分支：detached HEAD 時若不先切回，底下的分支 ref 雖會前進，
# 但實際 checkout 出來的工作目錄仍停在舊 commit，等同於白做。
invoke_pull_all_branches() {
    local repo_name="$1" repo_path="$2" root_branch="$3"

    local attach_ok attach_branch attach_auto attach_msg
    IFS='|' read -r attach_ok attach_branch attach_auto attach_msg <<< "$(ensure_repo_attached_to_branch "$repo_name" "$repo_path" "$root_branch")"
    if [ "$attach_ok" != "true" ]; then
        echo -e "${RED}  [X] ERROR: $attach_msg${NC}"
        return 1
    fi
    if [ "$attach_auto" = "true" ]; then
        echo -e "${GREEN}  [OK] Detached HEAD 已切換到 $attach_branch${NC}"
    fi

    git -C "$repo_path" fetch --all --prune --quiet || { echo -e "${RED}  [X] ERROR: fetch 失敗${NC}"; return 1; }

    local cur_branch all_branches ok_count=0 fail_branches=()
    cur_branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    all_branches="$(git -C "$repo_path" branch --format '%(refname:short)' 2>/dev/null)"

    while IFS= read -r b; do
        [ -z "$b" ] && continue
        git -C "$repo_path" rev-parse --abbrev-ref "${b}@{upstream}" >/dev/null 2>&1 || continue

        if [ "$b" = "$cur_branch" ]; then
            git -C "$repo_path" pull --ff-only --quiet
        else
            git -C "$repo_path" fetch "$REMOTE" "${b}:${b}" --quiet 2>/dev/null
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}    [OK] $b${NC}"
            ok_count=$((ok_count + 1))
        else
            echo -e "${YELLOW}    [!] $b — 更新失敗（可能需要 merge）${NC}"
            fail_branches+=("$b")
        fi
    done <<< "$all_branches"

    if [ "$ok_count" -eq 0 ] && [ "${#fail_branches[@]}" -eq 0 ]; then
        echo -e "${DARKGRAY}  [--] 無有效 upstream 分支，略過${NC}"
    else
        local msg="  已更新 $ok_count 個分支"
        [ "${#fail_branches[@]}" -gt 0 ] && msg+="，${#fail_branches[@]} 個失敗"
        if [ "${#fail_branches[@]}" -gt 0 ]; then echo -e "${YELLOW}${msg}${NC}"; else echo -e "${GREEN}${msg}${NC}"; fi
    fi

    [ "${#fail_branches[@]}" -eq 0 ]
}

# 切換到專案根目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/repo-aliases.sh"
PROJECT_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$PROJECT_ROOT")"
REMOTE_RE="$(remote_name_regex "$REMOTE")"
load_repo_alias_map "$PROJECT_ROOT"
cd "$PROJECT_ROOT"
MODE="${1:-}"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Submodule Update Branch${NC}"
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
# Branch Status Table
# -----------------------------------------------------------------------
DARKGRAY='\033[1;30m'

_ub_collect_row() {
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
    if [ ${#short}  -gt $((ub_name_w   - 2)) ]; then ub_name_w=$((${#short}  + 2)); fi
    if [ ${#branch} -gt $((ub_branch_w - 2)) ]; then ub_branch_w=$((${#branch} + 2)); fi
    ub_rows+=("${short}|${branch}|${ahead}|${upstream_disp}|${hint}")
}

ub_name_w=8
ub_branch_w=14
ub_rows=()
_ub_collect_row "root" "$PROJECT_ROOT"
for submodule in "${SUBMODULES[@]}"; do
    _ub_collect_row "$submodule" "$PROJECT_ROOT/$submodule"
done

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   Branch 狀態 — 各 repo 目前分支${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "${DARKGRAY}  +N=本地領先  --=無 upstream  (behind 資訊需 fetch 後才準確)${NC}"
echo
ub_header=$(printf "  %-*s %-*s %7s  %s" "$ub_name_w" "名稱" "$ub_branch_w" "Branch" "Ahead" "Upstream")
echo -e "${BLUE}${ub_header}${NC}"
ub_sep_len=$((ub_name_w + ub_branch_w + 7 + 14))
ub_sep=$(printf '%*s' "$ub_sep_len" '' | tr ' ' '-')
echo -e "${DARKGRAY}  ${ub_sep}${NC}"
for ub_row in "${ub_rows[@]}"; do
    IFS='|' read -r ub_short ub_branch ub_ahead ub_upstream ub_hint <<< "$ub_row"
    ub_line=$(printf "  %-*s %-*s %7s  %s" "$ub_name_w" "$ub_short" "$ub_branch_w" "$ub_branch" "$ub_ahead" "$ub_upstream")
    if   [[ "$ub_hint" == "no_upstream" ]]; then echo -e "${YELLOW}${ub_line}${NC}"
    elif [[ "$ub_hint" == "synced"      ]]; then echo -e "${GREEN}${ub_line}${NC}"
    else                                         echo -e "${CYAN}${ub_line}${NC}"
    fi
done
echo

NEED_BRANCH=false

if [ -n "$MODE" ]; then
    case "$MODE" in
        pull)      OPERATION="pull";     OP_DESC="Pulling";       GIT_ARGS="pull" ;;
        fetch)     OPERATION="fetch";    OP_DESC="Fetching";      GIT_ARGS="fetch --all" ;;
        pull-all)  OPERATION="pull-all"; OP_DESC="Pull 所有分支" ;;
        *)
            echo -e "${RED}Invalid mode: '$MODE'. Supported: pull, fetch, pull-all${NC}"
            exit 1
            ;;
    esac
else
    # 顯示選單
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}選擇操作：${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo
    echo -e "  ${CYAN}[1]${NC} Fetch — 更新遠端追蹤分支 (git fetch --all)"
    echo -e "  ${CYAN}[2]${NC} Fetch 指定分支"
    echo -e "  ${CYAN}[3]${NC} Pull — 取得並合併當前分支的遠端變更 (git pull)"
    echo -e "  ${CYAN}[4]${NC} 將指定分支同步到本地 (git fetch $REMOTE branch:branch)"
    echo -e "  ${CYAN}[5]${NC} Pull 所有分支 — 更新所有有 upstream 的本地分支"
    echo
    echo -e "  ${YELLOW}[c]${NC} 取消"
    echo
    echo -e "${BLUE}==========================================${NC}"

    # 讀取使用者輸入
    while true; do
        read -p "請輸入選擇 (1-5/c): " choice

        case "$choice" in
            [Cc])
                echo -e "${YELLOW}Operation cancelled.${NC}"
                exit 0
                ;;
            1)
                OPERATION="fetch"
                OP_DESC="Fetching"
                GIT_ARGS="fetch --all"
                NEED_BRANCH=false
                break
                ;;
            2)
                OPERATION="fetch"
                OP_DESC="Fetching"
                NEED_BRANCH=true
                break
                ;;
            3)
                OPERATION="pull"
                OP_DESC="Pulling"
                GIT_ARGS="pull"
                NEED_BRANCH=false
                break
                ;;
            4)
                OPERATION="update"
                OP_DESC="Updating"
                NEED_BRANCH=true
                break
                ;;
            5)
                OPERATION="pull-all"
                OP_DESC="Pull 所有分支"
                NEED_BRANCH=false
                break
                ;;
            *)
                echo -e "${RED}無效選擇，請輸入 1-5 或 c${NC}"
                ;;
        esac
    done
fi

# 如果需要指定分支，則取得分支清單並讓使用者選擇
if [ "$NEED_BRANCH" = true ]; then
    echo
    echo -e "${BLUE}Fetching remote branches...${NC}"
    git fetch --all --quiet 2>&1

    # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
    # strip=3 直接剝掉 refs/remotes/<remote>/，含斜線的 feature/foo 不會被截斷。
    BRANCHES=$(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" | grep -v '^HEAD$' | sort -u)

    if [ -z "$BRANCHES" ]; then
        echo -e "${RED}ERROR: No remote branches found${NC}"
        exit 1
    fi

    echo
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}選擇要 $OPERATION 的分支：${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo

    # 將分支轉為陣列
    mapfile -t BRANCH_ARRAY <<< "$BRANCHES"

    # 顯示分支選單
    for i in "${!BRANCH_ARRAY[@]}"; do
        echo -e "  ${CYAN}[$((i+1))]${NC} ${BRANCH_ARRAY[$i]}"
    done
    echo
    echo -e "  ${CYAN}[e]${NC} 輸入自訂分支名稱"
    echo -e "  ${YELLOW}[c]${NC} 取消"
    echo
    echo -e "${BLUE}==========================================${NC}"

    # 讀取分支選擇
    while true; do
        read -p "請輸入選擇 (1-${#BRANCH_ARRAY[@]}/e/c): " branch_choice

        if [[ "$branch_choice" =~ ^[Cc]$ ]]; then
            echo -e "${YELLOW}Operation cancelled.${NC}"
            exit 0
        elif [[ "$branch_choice" =~ ^[Ee]$ ]]; then
            read -p "輸入分支名稱：" TARGET_BRANCH
            if [ -z "$TARGET_BRANCH" ]; then
                echo -e "${RED}分支名稱不可為空${NC}"
                continue
            fi
            break
        elif [[ "$branch_choice" =~ ^[0-9]+$ ]] && [ "$branch_choice" -ge 1 ] && [ "$branch_choice" -le "${#BRANCH_ARRAY[@]}" ]; then
            TARGET_BRANCH="${BRANCH_ARRAY[$((branch_choice-1))]}"
            break
        else
            echo -e "${RED}無效選擇，請重新輸入。${NC}"
        fi
    done

    # 設定 Git 指令
    if [ "$OPERATION" = "fetch" ]; then
        GIT_ARGS="fetch $REMOTE $TARGET_BRANCH"
    elif [ "$OPERATION" = "update" ]; then
        GIT_ARGS="fetch $REMOTE $TARGET_BRANCH:$TARGET_BRANCH"
    else
        GIT_ARGS="pull $REMOTE $TARGET_BRANCH"
    fi

    OP_DESC="$OP_DESC branch '$TARGET_BRANCH'"
fi

echo
echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}$OP_DESC root and all submodules...${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo

# 確認操作
if [ -z "$MODE" ]; then
    read -p "確認要執行此操作？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi
fi
echo

# 執行操作
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_REPOS=()

# 關閉 set -e 以便處理錯誤
set +e

# detached HEAD 自動切回時，root 目前分支需先解出，供 submodule 的 "." 設定參照；
# pull 與 pull-all 皆需要判斷 attach 目標，故在分流之前統一計算。
ROOT_RESOLVED_BRANCH="$(repo_current_branch "$PROJECT_ROOT")"
if [ -z "$ROOT_RESOLVED_BRANCH" ]; then
    ROOT_RESOLVED_BRANCH="$(get_preferred_repo_branch "root" "$PROJECT_ROOT" "")"
fi

if [ "$OPERATION" = "pull-all" ]; then
    # Pull 所有有 upstream 的本地分支（每個 repo 各自處理，與 pull/fetch 的單分支流程互斥）
    for submodule in "${SUBMODULES[@]}"; do
        echo -e "${BLUE}Processing ${CYAN}$submodule${BLUE}...${NC}"
        sub_path="$PROJECT_ROOT/$submodule"
        # 用 .git 是否存在判斷 submodule 是否已初始化；不可用 `git -C` 探測，
        # 因為空目錄會被 git 往上層目錄尋根，誤判為已初始化的父層 repo。
        if [ ! -e "$sub_path/.git" ]; then
            echo -e "${RED}  [X] ERROR: submodule directory missing/uninitialized: $submodule${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule (missing/uninitialized submodule)")
            continue
        fi
        if invoke_pull_all_branches "$submodule" "$sub_path" "$ROOT_RESOLVED_BRANCH"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule")
        fi
    done

    echo -e "${BLUE}Processing ${CYAN}root${BLUE}...${NC}"
    if invoke_pull_all_branches "root" "$PROJECT_ROOT" "$ROOT_RESOLVED_BRANCH"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("root")
    fi
else
    # 先處理 submodules
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

        if [ "$OPERATION" = "pull" ]; then
            IFS='|' read -r attach_ok attach_branch attach_auto attach_msg <<< "$(ensure_repo_attached_to_branch "$submodule" "$sub_path" "$ROOT_RESOLVED_BRANCH")"
            if [ "$attach_ok" != "true" ]; then
                echo -e "${RED}  [X] ERROR: $attach_msg${NC}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAILED_REPOS+=("$submodule")
                continue
            fi
            if [ "$attach_auto" = "true" ]; then
                echo -e "${GREEN}  [OK] Detached HEAD 已切換到 $attach_branch${NC}"
            fi
        fi

        git -C "$sub_path" $GIT_ARGS 2>&1
        result=$?

        if [ $result -eq 0 ]; then
            echo -e "${GREEN}  ✓ $OP_DESC successful${NC}"
            if [ "$OPERATION" = "update" ]; then
                ensure_repo_upstream_on_branch "$sub_path" "$TARGET_BRANCH"
            fi
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "${RED}  ✗ ERROR: $OP_DESC failed${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("$submodule")
        fi
    done

    # 最後處理 root repository
    echo -e "${BLUE}Processing ${CYAN}root${BLUE}...${NC}"

    if [ "$OPERATION" = "pull" ]; then
        IFS='|' read -r attach_ok attach_branch attach_auto attach_msg <<< "$(ensure_repo_attached_to_branch "root" "$PROJECT_ROOT" "$ROOT_RESOLVED_BRANCH")"
        if [ "$attach_ok" != "true" ]; then
            echo -e "${RED}  [X] ERROR: $attach_msg${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root")
            result=1
        else
            if [ "$attach_auto" = "true" ]; then
                echo -e "${GREEN}  [OK] Detached HEAD 已切換到 $attach_branch${NC}"
            fi
            git -C "$PROJECT_ROOT" $GIT_ARGS 2>&1
            result=$?
        fi
    else
        git -C "$PROJECT_ROOT" $GIT_ARGS 2>&1
        result=$?
    fi

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}  ✓ $OP_DESC successful${NC}"
        if [ "$OPERATION" = "update" ]; then
            ensure_repo_upstream_on_branch "$PROJECT_ROOT" "$TARGET_BRANCH"
        fi
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}  ✗ ERROR: $OP_DESC failed${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("root")
    fi
fi

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
echo -e "${GREEN}✓ All repositories updated successfully!${NC}"
echo

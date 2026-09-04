#!/bin/bash

# ===========================================
# Git Submodule Branch Merge
# 一次將選擇的分支 merge 進 root 和所有 git submodule 的當前分支
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
# 當指定 branch 在本地存在、無 upstream，且 <remote>/<branch> 存在 → 自動補 tracking。
ensure_upstream_on_branch() {
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

# 切換到專案根目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/repo-aliases.sh"
source "$SCRIPT_DIR/lib/root-fastpath.sh"
PROJECT_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$PROJECT_ROOT")"
load_repo_alias_map "$PROJECT_ROOT"
cd "$PROJECT_ROOT"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Submodule Branch Merge${NC}"
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
ROOT_BRANCH=$(git branch --show-current)
echo -e "  - ${CYAN}root${NC} ($ROOT_BRANCH)"

declare -A SUBMODULE_BRANCHES
ALL_SAME=true
for submodule in "${SUBMODULES[@]}"; do
    branch=$(cd "$PROJECT_ROOT/$submodule" && git branch --show-current 2>/dev/null) || branch=""
    SUBMODULE_BRANCHES[$submodule]=$branch
    echo "  - $submodule ($branch)"
    if [ "$branch" != "$ROOT_BRANCH" ]; then
        ALL_SAME=false
    fi
done
echo

if [ "$ALL_SAME" = false ]; then
    echo -e "${YELLOW}⚠ WARNING: Not all repositories are on the same branch!${NC}"
    echo -e "  Please make sure all repositories are on the same branch before merging."
    echo
    read -p "是否仍要繼續？(y/N): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi
    echo
fi


SOURCE_BRANCH="$ROOT_BRANCH"
TARGET_BRANCH="$ROOT_BRANCH"

# ---------------------------------------------------------------------------
# Load merge direction rules (whitelist / blacklist per repo+source_branch)
# ---------------------------------------------------------------------------
declare -A MERGE_RULES_MODE
declare -A MERGE_RULES_TARGETS
MERGE_RULES_FILE="${PROJECT_ROOT}/scripts/config/merge-direction-rules.txt"
if [ -f "$MERGE_RULES_FILE" ]; then
    while IFS= read -r ruleline; do
        ruleline="${ruleline#"${ruleline%%[![:space:]]*}"}"   # trim leading spaces
        [[ -z "$ruleline" || "${ruleline:0:1}" == "#" ]] && continue
        read -ra rp <<< "$ruleline"
        [ "${#rp[@]}" -lt 3 ] && continue
        rule_key="${rp[0]}|${rp[2]}"
        MERGE_RULES_MODE["$rule_key"]="${rp[1]}"
        MERGE_RULES_TARGETS["$rule_key"]="${rp[*]:3}"
    done < "$MERGE_RULES_FILE"
fi

# Returns 0 (allowed) or 1 (blocked)
is_merge_allowed() {
    local repo="$1" src="$2" target="$3"
    local key="${repo}|${src}"
    [ -z "${MERGE_RULES_MODE[$key]+x}" ] && return 0  # no rule = allowed
    local mode="${MERGE_RULES_MODE[$key]}"
    local targets="${MERGE_RULES_TARGETS[$key]}"
    if [ "$mode" = "allow" ]; then
        [ -z "$targets" ] && return 1  # empty whitelist = blocked
        for t in $targets; do [ "$t" = "$target" ] && return 0; done
        return 1
    elif [ "$mode" = "deny" ]; then
        [ -z "$targets" ] && return 0  # empty blacklist = no restriction
        for t in $targets; do [ "$t" = "$target" ] && return 1; done
        return 0
    fi
    return 0
}
echo -e "${BLUE}Target branch (current):${NC} $TARGET_BRANCH"
echo

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

    if [[ "$mode_choice" =~ ^[Cc]$ ]]; then
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

        # Fetch all remotes
        echo -e "  Fetching ${CYAN}root${NC}..."
        # --no-recurse-submodules: 每個 submodule 下面已經有獨立的 fetch 迴圈處理，
        # root 這一步不需要靠 git 預設的 on-demand 遞迴去抓 gitlink 指到的 submodule commit——
        # 一旦某個 gitlink 壞掉（指向 submodule 遠端已不可達的 commit），會連帶讓 root fetch 直接失敗。
        git fetch --all --quiet --no-recurse-submodules || {
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

# ---------------------------------------------------------------------------
# Branch Audit Matrix — 顯示各分支在各 repo 的分佈狀態
# ---------------------------------------------------------------------------
DARK='\033[0;90m'
mg_tmpfile="${PROJECT_ROOT}/.mg_branch_audit_$$"
mg_repos_names=("root")
mg_repos_paths=("$PROJECT_ROOT")
for submodule in "${SUBMODULES[@]}"; do
    mg_repos_names+=("$submodule")
    mg_repos_paths+=("$PROJECT_ROOT/$submodule")
done

for i in "${!mg_repos_names[@]}"; do
    repo="${mg_repos_names[$i]}"
    rpath="${mg_repos_paths[$i]}"
    while IFS= read -r b; do
        if [ -n "$b" ]; then echo "local|${repo}|${b}" >> "$mg_tmpfile"; fi
    done < <(git -C "$rpath" branch --format='%(refname:short)' 2>/dev/null | grep -v '^$')
    # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
    while IFS= read -r b; do
        if [ -n "$b" ] && [ "$b" != "HEAD" ]; then echo "remote|${repo}|${b}" >> "$mg_tmpfile"; fi
    done < <(git -C "$rpath" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" 2>/dev/null)
done
mg_all_branches=()
if [ -f "$mg_tmpfile" ]; then
    while IFS= read -r b; do
        mg_all_branches+=("$b")
    done < <(cut -d'|' -f3 "$mg_tmpfile" 2>/dev/null | sort -u)
fi
mg_max_sn=4
for repo in "${mg_repos_names[@]}"; do
    sn="$(repo_short_name "$repo")"
    if [ "${#sn}" -gt "$mg_max_sn" ]; then mg_max_sn="${#sn}"; fi
done
mg_rcol=$((mg_max_sn + 2))
if [ "$mg_rcol" -lt 6 ]; then mg_rcol=6; fi
mg_max_b=22
for b in "${mg_all_branches[@]}"; do
    if [ "${#b}" -gt "$mg_max_b" ]; then mg_max_b="${#b}"; fi
done
mg_bcol=$((mg_max_b + 2))
if [ "$mg_bcol" -lt 24 ]; then mg_bcol=24; fi
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   Branch Audit — 各分支分佈狀態${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "${DARK}  v=local+remote   L=local-only   R=remote-only   -=不存在${NC}"
echo -e "${DARK}  （藍字列 = merge 目標 branch；請選擇來源 branch）${NC}"
echo
mg_hdr="  $(printf "%-${mg_bcol}s" "Branch")"
for repo in "${mg_repos_names[@]}"; do
    sn="$(repo_short_name "$repo")"
    mg_hdr+="$(printf "%${mg_rcol}s" "$sn")"
done
echo -e "${BLUE}${mg_hdr}${NC}"
mg_sep_len=$((mg_bcol + ${#mg_repos_names[@]} * mg_rcol))
mg_sep="  $(printf '%*s' "$mg_sep_len" '' | tr ' ' '-')"
echo -e "${DARK}${mg_sep}${NC}"
for b in "${mg_all_branches[@]}"; do
    mg_line="  $(printf "%-${mg_bcol}s" "$b")"
    mg_issue=false
    for repo in "${mg_repos_names[@]}"; do
        has_local=false
        has_remote=false
        if grep -q "^local|${repo}|${b}$" "$mg_tmpfile" 2>/dev/null; then has_local=true; fi
        if grep -q "^remote|${repo}|${b}$" "$mg_tmpfile" 2>/dev/null; then has_remote=true; fi
        if $has_local && $has_remote; then
            mg_line+="$(printf "%${mg_rcol}s" "v")"
        elif $has_local; then
            mg_line+="$(printf "%${mg_rcol}s" "L")"
            mg_issue=true
        elif $has_remote; then
            mg_line+="$(printf "%${mg_rcol}s" "R")"
            mg_issue=true
        else
            mg_line+="$(printf "%${mg_rcol}s" "-")"
        fi
    done
    if [ "$b" = "$TARGET_BRANCH" ]; then
        echo -e "${CYAN}${mg_line}${NC}"
    elif $mg_issue; then
        echo -e "${YELLOW}${mg_line}${NC}"
    else
        echo -e "${GREEN}${mg_line}${NC}"
    fi
done
echo
rm -f "$mg_tmpfile"

# 收集 root 和所有 submodule 的分支並找出共同分支
echo -e "${YELLOW}Collecting common branches...${NC}"
declare -A branch_count
total_repos=$((${#SUBMODULES[@]} + 1))

# 收集 root 的分支
# 不用 git branch -a：它會混入其他 remote 的分支，且本地分支與 refs/remotes/<remote>/HEAD
# 都會被算成同一個裸名字，無法區分。改用 for-each-ref 分別精確列舉兩個 ref 命名空間。
# 分開取值並各自檢查 exit code：pipeline 中間指令失敗不會被 set -e 攔到，
# 末端的 sort 仍會成功，會把「列舉失敗」誤判成「沒有共同分支」。
mg_heads="$(git for-each-ref --format='%(refname:strip=2)' refs/heads)" || {
    echo -e "${RED}ERROR: 無法列舉 root 的本地分支${NC}"; exit 1; }
mg_rem="$(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE")" || {
    echo -e "${RED}ERROR: 無法列舉 root 的遠端分支（remote: $REMOTE）${NC}"; exit 1; }
branches=$(printf '%s\n%s\n' "$mg_heads" "$mg_rem" | grep -v '^HEAD$' | grep -v '^$' | sort -u)
for branch in $branches; do
    if [ -n "$branch" ] && [ "$branch" != "$TARGET_BRANCH" ]; then
        current_count=${branch_count[$branch]:-0}
        branch_count[$branch]=$((current_count + 1))
    fi
done

for submodule in "${SUBMODULES[@]}"; do
    mg_sub_heads="$(git -C "$submodule" for-each-ref --format='%(refname:strip=2)' refs/heads)" || {
        echo -e "${RED}ERROR: 無法列舉 $submodule 的本地分支${NC}"; exit 1; }
    mg_sub_rem="$(git -C "$submodule" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE")" || {
        echo -e "${RED}ERROR: 無法列舉 $submodule 的遠端分支（remote: $REMOTE）${NC}"; exit 1; }
    branches=$(printf '%s\n%s\n' "$mg_sub_heads" "$mg_sub_rem" | grep -v '^HEAD$' | grep -v '^$' | sort -u)""
    for branch in $branches; do
        if [ -n "$branch" ] && [ "$branch" != "$TARGET_BRANCH" ]; then
            current_count=${branch_count[$branch]:-0}
            branch_count[$branch]=$((current_count + 1))
        fi
    done
done

# 找出共同分支
common_branches=()
for branch in "${!branch_count[@]}"; do
    if [ "${branch_count[$branch]}" -eq "$total_repos" ]; then
        common_branches+=("$branch")
    fi
done

# 排序
IFS=$'\n' sorted_branches=($(sort <<<"${common_branches[*]}")); unset IFS

echo -e "${GREEN}✓ Found ${#sorted_branches[@]} available source branches${NC}"
echo

# 顯示選單
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}選擇要 merge 的來源分支：${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "  Current branch: ${CYAN}$TARGET_BRANCH${NC}"
echo -e "  Will merge: ${YELLOW}[source]${NC} -> ${CYAN}$TARGET_BRANCH${NC}"
echo

idx=1
for branch in "${sorted_branches[@]}"; do
    echo -e "  ${CYAN}[$idx]${NC} $branch"
    ((idx++))
done
echo
echo -e "  ${YELLOW}[e]${NC} 輸入自訂分支名稱"
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${BLUE}==========================================${NC}"

# 讀取使用者輸入
while true; do
    read -p "請輸入選擇 (1-${#sorted_branches[@]}/e/c): " choice

    if [[ "$choice" =~ ^[Cc]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi

    if [[ "$choice" =~ ^[Ee]$ ]]; then
        read -p "輸入來源分支名稱：" custom_branch
        if [ -z "$custom_branch" ]; then
            echo -e "${RED}ERROR: Branch name cannot be empty${NC}"
            continue
        fi
        SOURCE_BRANCH="$custom_branch"
        break
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#sorted_branches[@]}" ]; then
        SOURCE_BRANCH="${sorted_branches[$((choice-1))]}"
        break
    fi

    echo -e "${RED}無效選擇，請輸入 1 到 ${#sorted_branches[@]} 的數字、e 或 c${NC}"
done

echo
echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}Merge Plan:${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo -e "  Source: ${CYAN}$SOURCE_BRANCH${NC}"
echo -e "  Target: ${CYAN}$TARGET_BRANCH${NC}"
echo -e "  Action: Merge ${CYAN}$SOURCE_BRANCH${NC} into current branch ${CYAN}$TARGET_BRANCH${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo

# 確認操作
read -p "確認要執行此操作？(y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 0
fi
echo

# 檢查是否有未提交的變更
echo -e "${YELLOW}Checking for uncommitted changes...${NC}"
HAS_CHANGES=false

if ! git diff --quiet || ! git diff --cached --quiet; then
    HAS_CHANGES=true
fi

for submodule in "${SUBMODULES[@]}"; do
    if ! (cd "$submodule" && git diff --quiet && git diff --cached --quiet); then
        HAS_CHANGES=true
    fi
done

if [ "$HAS_CHANGES" = true ]; then
    echo -e "${RED}✗ ERROR: There are uncommitted changes in one or more repositories.${NC}"
    echo -e "  Please commit or stash your changes before merging."
    exit 1
fi
echo -e "${GREEN}✓ No uncommitted changes${NC}"
echo

# 關閉 set -e 以便處理錯誤
set +e

# 執行 merge
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIPPED_COUNT=0
FAILED_REPOS=()
SKIPPED_REPOS=()
SKIPPED_SUB_NAMES=()

# 如果有 fetch，先更新本地 source branch 到遠端最新版本
if [ $FETCH_MODE -eq 1 ]; then
    echo -e "${YELLOW}Updating local source branch to remote version...${NC}"
    echo

    # 更新 root 的 source branch
    echo -e "  Updating ${CYAN}root${NC}..."
    cd "$PROJECT_ROOT"
    # --no-recurse-submodules: 同上，避免壞掉的 gitlink 讓這裡的 fetch/pull 也失敗。
    if ! git fetch --no-recurse-submodules "$REMOTE" "$SOURCE_BRANCH:$SOURCE_BRANCH" 2>/dev/null; then
        # 如果 fetch 失敗，嘗試用 checkout + pull 方式更新
        CURRENT_BRANCH=$(git branch --show-current)
        if git checkout "$SOURCE_BRANCH" 2>/dev/null; then
            git pull --no-recurse-submodules "$REMOTE" "$SOURCE_BRANCH" --ff-only 2>/dev/null || true
            git checkout "$CURRENT_BRANCH" 2>/dev/null
        fi
    fi
    ensure_upstream_on_branch "$PROJECT_ROOT" "$SOURCE_BRANCH"

    # 更新各 submodule 的 source branch
    for submodule in "${SUBMODULES[@]}"; do
        echo -e "  Updating ${CYAN}$submodule${NC}..."
        sub_path="$PROJECT_ROOT/$submodule"
        # 用 .git 是否存在判斷 submodule 是否已初始化；不可用 `git -C` 探測，
        # 因為空目錄會被 git 往上層目錄尋根，誤判為已初始化的父層 repo。
        if [ ! -e "$sub_path/.git" ]; then
            echo -e "${YELLOW}  ⚠ Skipping — submodule directory missing/uninitialized: $submodule${NC}"
            continue
        fi
        if ! git -C "$sub_path" fetch "$REMOTE" "$SOURCE_BRANCH:$SOURCE_BRANCH" 2>/dev/null; then
            CURRENT_BRANCH=$(git -C "$sub_path" branch --show-current)
            if git -C "$sub_path" checkout "$SOURCE_BRANCH" 2>/dev/null; then
                git -C "$sub_path" pull "$REMOTE" "$SOURCE_BRANCH" --ff-only 2>/dev/null || true
                git -C "$sub_path" checkout "$CURRENT_BRANCH" 2>/dev/null
            fi
        fi
        ensure_upstream_on_branch "$sub_path" "$SOURCE_BRANCH"
    done
    echo -e "${GREEN}✓ Source branch updated${NC}"
    echo
fi

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

    SUB_TARGET="${SUBMODULE_BRANCHES[$submodule]}"

    if ! is_merge_allowed "$submodule" "$SOURCE_BRANCH" "$SUB_TARGET"; then
        echo -e "${YELLOW}  [SKIP] Direction rule blocks $SOURCE_BRANCH -> $SUB_TARGET${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        SKIPPED_REPOS+=("$submodule (direction rule: $SOURCE_BRANCH -> $SUB_TARGET)")
        SKIPPED_SUB_NAMES+=("$submodule")
        continue
    fi

    echo -e "  Merging ${CYAN}$SOURCE_BRANCH${NC} into ${CYAN}$SUB_TARGET${NC}..."
    if git -C "$sub_path" merge "$SOURCE_BRANCH" --no-edit; then
        echo -e "${GREEN}  ✓ Merge successful${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}  ✗ ERROR: Merge failed - conflicts detected${NC}"
        echo -e "  Please resolve conflicts manually in $submodule"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_REPOS+=("$submodule (merge conflict)")
    fi
done

# 最後處理 root repository
# submodule 有衝突未解時，root merge 必然失敗且無意義，直接跳過
if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${YELLOW}⚠ Skipping root merge — $FAIL_COUNT submodule(s) have unresolved conflicts.${NC}"
    echo -e "  Resolve submodule conflicts first, then re-run or merge root manually."
else
    echo -e "${BLUE}Processing ${CYAN}root${BLUE}...${NC}"
    cd "$PROJECT_ROOT"

    if ! is_merge_allowed "root" "$SOURCE_BRANCH" "$TARGET_BRANCH"; then
        echo -e "${YELLOW}  [SKIP] Direction rule blocks $SOURCE_BRANCH -> $TARGET_BRANCH in root${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        SKIPPED_REPOS+=("root (direction rule: $SOURCE_BRANCH -> $TARGET_BRANCH)")
    else

    echo -e "  Merging ${CYAN}$SOURCE_BRANCH${NC} into ${CYAN}$TARGET_BRANCH${NC}..."
    if git merge "$SOURCE_BRANCH" --no-edit; then
        echo -e "${GREEN}  ✓ Merge successful${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        # 判斷衝突是否純粹是 submodule gitlink（mode 160000）。
        # 若是，接受每個 submodule 目前的 HEAD（前面已各自 merge 完成）並完成 merge commit；
        # 任何真實檔案衝突一律要求手動處理。
        echo -e "${YELLOW}  [!] Root merge conflict detected, analysing...${NC}"

        HAS_NON_SUBMODULE=false
        declare -A CONFLICTED_PATHS=()   # 去重；同一路徑在 stage 1-3 各出現一次

        while IFS=$'\t' read -r mode_stage file_path; do
            [ -z "$file_path" ] && continue
            mode="${mode_stage%% *}"
            if [ "$mode" != "160000" ]; then
                HAS_NON_SUBMODULE=true
            else
                CONFLICTED_PATHS["$file_path"]=1
            fi
        done < <(git ls-files -u 2>/dev/null)

        if [ "$HAS_NON_SUBMODULE" = true ]; then
            echo -e "${RED}  ✗ ERROR: Real file conflicts in root - please resolve manually${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_REPOS+=("root (merge conflict)")
        else
            echo -e "${YELLOW}  [!] Only submodule ref conflicts detected${NC}"

            # 若 gitlink 衝突涉及被 direction rule skip 的子模組，無法安全自動解衝：
            # auto-resolve 只能取目前工作樹 HEAD（target 端），會靜默丟棄 source 端更新。
            DANGEROUS_CONFLICTS=()
            for path in "${!CONFLICTED_PATHS[@]}"; do
                for skipped in "${SKIPPED_SUB_NAMES[@]}"; do
                    [ "$path" = "$skipped" ] && DANGEROUS_CONFLICTS+=("$path")
                done
            done

            if [ ${#DANGEROUS_CONFLICTS[@]} -gt 0 ]; then
                echo -e "${RED}  ✗ ERROR: Root gitlink conflict for skipped submodule(s): ${DANGEROUS_CONFLICTS[*]}${NC}"
                echo -e "${RED}      Cannot auto-resolve safely - accepting current HEAD would silently drop the source-side pointer update.${NC}"
                echo -e "${RED}      Please abort the merge (git merge --abort) and resolve manually.${NC}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAILED_REPOS+=("root (unsafe gitlink conflict for skipped: ${DANGEROUS_CONFLICTS[*]})")
            else
                echo -e "${YELLOW}  [!] Auto-resolving: accepting current HEAD of each conflicted submodule...${NC}"
                for path in "${!CONFLICTED_PATHS[@]}"; do
                    git add "$path"
                done
                if git commit --no-edit; then
                    echo -e "${GREEN}  ✓ Merge completed - submodule ref conflicts auto-resolved${NC}"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    echo -e "${RED}  ✗ ERROR: Failed to complete merge after auto-resolve${NC}"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                    FAILED_REPOS+=("root (merge commit failed)")
                fi
            fi
        fi
    fi

    fi # end direction-rule check
fi

# 顯示結果
echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Summary${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}  Successful: $SUCCESS_COUNT${NC}"
echo -e "${RED}  Failed: $FAIL_COUNT${NC}"
echo -e "${YELLOW}  Skipped: $SKIPPED_COUNT${NC}"

if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    echo
    echo -e "${RED}Failed repositories:${NC}"
    for failed in "${FAILED_REPOS[@]}"; do
        echo -e "  ${RED}✗ $failed${NC}"
    done
    echo
    echo -e "${YELLOW}⚠ Some merges failed. Please resolve conflicts manually.${NC}"
    exit 1
fi

if [ ${#SKIPPED_REPOS[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}Skipped repositories (direction rules):${NC}"
    for skipped in "${SKIPPED_REPOS[@]}"; do
        echo -e "  ${YELLOW}⊘ $skipped${NC}"
    done
fi

# ---------------------------------------------------------------------------
# Auto-commit root submodule refs via fastpath
# After submodule merges, root's gitlinks lag behind the actual submodule
# HEADs. Probe eligibility silently; only commit when root's dirty state is
# purely submodule refs. Mixed / non-submodule changes require manual commit.
# ---------------------------------------------------------------------------
echo
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   Auto-committing root submodule refs${NC}"
echo -e "${BLUE}==========================================${NC}"

if fastpath_check "$PROJECT_ROOT" >/dev/null 2>&1; then
    fastpath_msg="$(fastpath_build_commit_message)"
    if fastpath_commit "$PROJECT_ROOT" "$fastpath_msg"; then
        echo -e "${GREEN}[OK] Root submodule refs committed${NC}"
    else
        echo -e "${RED}[X] ERROR: Failed to commit root submodule refs${NC}"
        exit 1
    fi
else
    root_dirty="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)"
    if [ -n "$root_dirty" ]; then
        echo
        echo -e "${YELLOW}[!] Root has uncommitted changes that are not pure submodule refs.${NC}"
        echo -e "${YELLOW}    Please commit root manually.${NC}"
    fi
fi

echo
echo -e "${GREEN}✓ All merges completed successfully!${NC}"
echo

# 顯示當前分支狀態
echo -e "${BLUE}Current branch status:${NC}"
root_current=$(cd "$PROJECT_ROOT" && git branch --show-current)
echo -e "  ${CYAN}root${NC}: $root_current"
for submodule in "${SUBMODULES[@]}"; do
    current=$(cd "$PROJECT_ROOT/$submodule" && git branch --show-current)
    echo -e "  ${CYAN}$submodule${NC}: $current"
done
echo
echo -e "${YELLOW}⚠ Remember to push changes after reviewing the merge results.${NC}"

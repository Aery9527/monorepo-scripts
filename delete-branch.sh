#!/bin/bash

# ===========================================
# Git Submodule Branch Delete
# 清點所有 repo 的 branch 狀態後多選刪除
# ===========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DARK_GRAY='\033[0;90m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/repo-aliases.sh"
PROJECT_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$PROJECT_ROOT")"
load_repo_alias_map "$PROJECT_ROOT"
cd "$PROJECT_ROOT"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Git Submodule Branch Delete${NC}"
echo -e "${CYAN}==========================================${NC}"
echo

SUBMODULE_LIST=$(list_initialized_submodule_paths "$PROJECT_ROOT")
if [ -z "$SUBMODULE_LIST" ]; then
    echo -e "${RED}ERROR: No submodules found or .gitmodules not readable${NC}"
    echo -e "${RED}       解析到的 repo root: $PROJECT_ROOT${NC}"
    exit 1
fi

REPO_NAMES=("root")
REPO_PATHS=("$PROJECT_ROOT")
while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    REPO_NAMES+=("$sub")
    REPO_PATHS+=("$PROJECT_ROOT/$sub")
done <<< "$SUBMODULE_LIST"

REPO_COUNT=${#REPO_NAMES[@]}

echo -e "${BLUE}Found $REPO_COUNT repositories:${NC}"
for i in "${!REPO_NAMES[@]}"; do
    branch=$(git -C "${REPO_PATHS[$i]}" branch --show-current 2>/dev/null) || branch=""
    echo -e "  - ${CYAN}${REPO_NAMES[$i]}${NC} ($branch)"
done
echo

PROTECTED_BRANCHES=("main" "master" "develop")
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null)

# 快速清除模式：字面上的「只留目前分支」——不比照下方互動式多選對 main/master/develop 的保護。
# 唯一的安全網是逐分支確認「已完整推送」才刪，且要求所有 repo 先在同一分支才能執行，
# 避免各 submodule 目前所在分支不同時，誤判、砍到其他 repo 正在使用的分支。
quick_clean_mode() {
    echo
    echo -e "${BLUE}[快速清除模式] 檢查所有 repo 是否位於同一分支...${NC}"

    # root 若為 detached HEAD，CURRENT_BRANCH 是空字串；每個 submodule 若也 detached，
    # git branch --show-current 同樣回空字串，會讓下面逐一比對全部相等而誤判為「一致」，
    # 進而把所有本地具名分支都當成候選——必須在比對前先擋掉這個情況。
    if [ -z "$CURRENT_BRANCH" ]; then
        echo -e "${RED}[X] root 目前為 detached HEAD，無法判斷「目前分支」，快速清除模式已中止。${NC}"
        return 1
    fi

    local i b mismatch=0
    for i in "${!REPO_NAMES[@]}"; do
        b=$(git -C "${REPO_PATHS[$i]}" branch --show-current 2>/dev/null) || b=""
        if [ "$b" != "$CURRENT_BRANCH" ]; then
            echo -e "  ${RED}[X] ${REPO_NAMES[$i]}: 位於 '${b:-<detached HEAD>}'，與 root 的 '$CURRENT_BRANCH' 不一致${NC}"
            mismatch=1
        fi
    done
    if [ $mismatch -eq 1 ]; then
        echo -e "${RED}[X] 各 repo 分支不一致，為避免砍錯分支，快速清除模式已中止。請先讓所有 repo 切到同一分支再重試。${NC}"
        return 1
    fi
    echo -e "${GREEN}[OK] 所有 repo 皆位於 '$CURRENT_BRANCH'${NC}"
    echo

    # --prune 是必要的，不只是最佳實踐：若遠端已刪除某分支但本地 remote-tracking ref
    # 未被清掉，下面的 rev-parse 仍會成功、ahead 仍可能算出 0，導致「已刪除的遠端分支」被
    # 誤判為「已推送」而砍掉本地僅存的副本。
    echo -e "${BLUE}Fetching $REMOTE（強制執行，並 --prune 避免用到已過期的遠端分支快取）...${NC}"
    local FETCH_OK=()
    set +e
    for i in "${!REPO_NAMES[@]}"; do
        if git -C "${REPO_PATHS[$i]}" fetch "$REMOTE" --prune --quiet 2>/dev/null; then
            FETCH_OK[$i]=1
        else
            FETCH_OK[$i]=0
            echo -e "  ${YELLOW}[!] WARNING: Fetch had errors for ${REPO_NAMES[$i]}，該 repo 的分支將一律標記為無法確認${NC}"
        fi
    done
    set -e
    echo

    local PLAN_REPO=() PLAN_BRANCH=() PLAN_PATH=() PLAN_ACTION=() PLAN_REASON=()
    local repo_name repo_path ahead branch_list
    for i in "${!REPO_NAMES[@]}"; do
        repo_name="${REPO_NAMES[$i]}"
        repo_path="${REPO_PATHS[$i]}"

        # 用指令替換 + here-string 取代 process substitution：process substitution 的
        # 結束碼進不了主流程，git 失敗會被靜默吞掉、該 repo 悄悄變成「沒有候選分支」；
        # 這裡改為明確判斷成功與否，失敗就整個 repo 略過並警示。
        if branch_list="$(git -C "$repo_path" branch --format='%(refname:short)' 2>/dev/null)"; then
            :
        else
            echo -e "  ${YELLOW}[!] WARNING: 無法列出 $repo_name 的本地分支，已略過該 repo${NC}"
            continue
        fi

        while IFS= read -r b; do
            [ -z "$b" ] && continue
            [ "$b" = "$CURRENT_BRANCH" ] && continue

            if [ "${FETCH_OK[$i]}" != "1" ]; then
                PLAN_REPO+=("$repo_name"); PLAN_BRANCH+=("$b"); PLAN_PATH+=("$repo_path")
                PLAN_ACTION+=("SKIP"); PLAN_REASON+=("該 repo fetch 失敗，無法確認推送狀態")
                continue
            fi

            # 用完整 ref 路徑（refs/remotes/<remote>/<b>、refs/heads/<b>）取代 <remote>/<b> 這種
            # 簡寫，避免 git 的 DWIM 解析在極端命名巧合下（例如本地剛好有一條叫
            # <remote>/<b> 的分支）解析到非預期的 ref。
            if ! git -C "$repo_path" rev-parse --verify --quiet "refs/remotes/$REMOTE/$b" >/dev/null 2>&1; then
                PLAN_REPO+=("$repo_name"); PLAN_BRANCH+=("$b"); PLAN_PATH+=("$repo_path")
                PLAN_ACTION+=("SKIP"); PLAN_REASON+=("無對應遠端分支，視為未推送")
                continue
            fi

            ahead="$(git -C "$repo_path" rev-list --count "refs/remotes/$REMOTE/$b..refs/heads/$b" 2>/dev/null)" || ahead=""
            case "$ahead" in
                ''|*[!0-9]*)
                    PLAN_REPO+=("$repo_name"); PLAN_BRANCH+=("$b"); PLAN_PATH+=("$repo_path")
                    PLAN_ACTION+=("SKIP"); PLAN_REASON+=("無法確認推送狀態，為安全略過")
                    ;;
                0)
                    PLAN_REPO+=("$repo_name"); PLAN_BRANCH+=("$b"); PLAN_PATH+=("$repo_path")
                    PLAN_ACTION+=("DELETE"); PLAN_REASON+=("已完整推送")
                    ;;
                *)
                    PLAN_REPO+=("$repo_name"); PLAN_BRANCH+=("$b"); PLAN_PATH+=("$repo_path")
                    PLAN_ACTION+=("SKIP"); PLAN_REASON+=("領先遠端 $ahead 個 commit，尚未推送")
                    ;;
            esac
        done <<< "$branch_list"
    done

    if [ ${#PLAN_REPO[@]} -eq 0 ]; then
        echo -e "${YELLOW}[!] 除了目前分支 '$CURRENT_BRANCH' 外，沒有其他本地分支。${NC}"
        return 0
    fi

    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}   快速清除計畫（保留：$CURRENT_BRANCH）${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo
    local idx del_count=0
    for idx in "${!PLAN_REPO[@]}"; do
        if [ "${PLAN_ACTION[$idx]}" = "DELETE" ]; then
            echo -e "  ${GREEN}[刪除]${NC} ${PLAN_REPO[$idx]} / ${PLAN_BRANCH[$idx]} — ${PLAN_REASON[$idx]}"
            del_count=$((del_count + 1))
        else
            echo -e "  ${DARK_GRAY}[略過] ${PLAN_REPO[$idx]} / ${PLAN_BRANCH[$idx]} — ${PLAN_REASON[$idx]}${NC}"
        fi
    done
    echo
    echo -e "${CYAN}將刪除 $del_count 個本地分支，略過 $(( ${#PLAN_REPO[@]} - del_count )) 個（未推送或無法確認）${NC}"
    echo

    if [ $del_count -eq 0 ]; then
        echo -e "${YELLOW}[!] 沒有可安全刪除的分支（全部尚未推送），未執行任何刪除。${NC}"
        return 0
    fi

    echo -e "${RED}[!!!] WARNING: 此操作無法復原！${NC}"
    read -rp "確認要刪除以上「已推送」的本地分支？(y/N): " confirm
    if [ "$confirm" != "y" ]; then echo -e "${YELLOW}取消操作。${NC}"; return 0; fi
    echo

    local success_count=0 fail_count=0
    set +e
    for idx in "${!PLAN_REPO[@]}"; do
        [ "${PLAN_ACTION[$idx]}" != "DELETE" ] && continue
        # 直接用產生計畫時就存下的 PLAN_PATH，不再以 repo 顯示名稱回頭查 REPO_NAMES——
        # 避免 .gitmodules 若剛好有 submodule 路徑撞名（例如叫 "root"）時找錯 repo。
        if git -C "${PLAN_PATH[$idx]}" branch -D "${PLAN_BRANCH[$idx]}" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[OK]${NC} ${PLAN_REPO[$idx]} / ${PLAN_BRANCH[$idx]} — 已刪除"
            success_count=$((success_count + 1))
        else
            echo -e "  ${RED}[X]${NC} ${PLAN_REPO[$idx]} / ${PLAN_BRANCH[$idx]} — 刪除失敗"
            fail_count=$((fail_count + 1))
        fi
    done
    set -e

    echo
    echo -e "${CYAN}Summary: 成功 $success_count，失敗 $fail_count${NC}"
    [ $fail_count -gt 0 ] && return 1
    return 0
}

# 選擇工作流程
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}選擇工作流程：${NC}"
echo -e "${CYAN}==========================================${NC}"
echo
echo -e "  ${GREEN}[1]${NC} 互動式多選（清點所有 repo 後勾選要刪除的分支，可含遠端）"
echo -e "  ${GREEN}[2]${NC} 快速清除（保留目前分支，砍光其餘本地分支；自動略過尚未推送的分支）"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${CYAN}==========================================${NC}"

while true; do
    read -rp "請輸入選擇 (1-2/c): " flow_choice
    case "$flow_choice" in
        [Cc]) echo -e "${YELLOW}取消操作。${NC}"; exit 0 ;;
        1) break ;;
        2) quick_clean_mode; exit $? ;;
        *) echo -e "${RED}無效選擇，請輸入 1、2 或 c${NC}" ;;
    esac
done

# Mode selection（互動式多選流程：選擇遠端資訊來源）
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}選擇操作模式：${NC}"
echo -e "${CYAN}==========================================${NC}"
echo
echo -e "  ${GREEN}[1]${NC} 僅使用快取的遠端資訊（不連網）"
echo -e "  ${GREEN}[2]${NC} 先 fetch（建議 — 確保遠端資訊是最新的）"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${CYAN}==========================================${NC}"

while true; do
    read -rp "請輸入選擇 (1-2/c): " mode_choice
    case "$mode_choice" in
        [Cc]) echo -e "${YELLOW}取消操作。${NC}"; exit 0 ;;
        1)
            echo -e "${GREEN}[OK] Using cached remote info${NC}"; echo; break ;;
        2)
            echo -e "${GREEN}[OK] Fetching all remotes (--prune)...${NC}"; echo
            set +e
            for i in "${!REPO_NAMES[@]}"; do
                echo -e "  Fetching ${CYAN}${REPO_NAMES[$i]}${NC}..."
                git -C "${REPO_PATHS[$i]}" fetch --all --prune --quiet 2>/dev/null
                [ $? -ne 0 ] && echo -e "  ${YELLOW}[!] WARNING: Fetch had errors for ${REPO_NAMES[$i]}${NC}"
            done
            set -e
            echo -e "${GREEN}[OK] Fetch completed${NC}"; echo; break ;;
        *) echo -e "${RED}無效選擇，請輸入 1、2 或 c${NC}" ;;
    esac
done

# Collect branch data across all repos
echo -e "${BLUE}Collecting branch data...${NC}"

TMPDIR_DATA=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DATA"' EXIT

set +e
for i in "${!REPO_NAMES[@]}"; do
    repo_name="${REPO_NAMES[$i]}"
    repo_path="${REPO_PATHS[$i]}"
    git -C "$repo_path" branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "local|${repo_name}|${b}" >> "$TMPDIR_DATA/raw.txt"
    done
    # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
    git -C "$repo_path" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" 2>/dev/null |
        grep -v '^HEAD$' | sort -u |
        while IFS= read -r b; do
            [ -z "$b" ] && continue
            echo "remote|${repo_name}|${b}" >> "$TMPDIR_DATA/raw.txt"
        done
done
set -e

if [ ! -f "$TMPDIR_DATA/raw.txt" ]; then
    echo -e "${YELLOW}[!] No branches found.${NC}"; exit 0
fi

# All unique branches excluding protected + current
ALL_BRANCHES_RAW=($(awk -F'|' '{ print $3 }' "$TMPDIR_DATA/raw.txt" | sort -u))

DELETABLE_BRANCHES=()
for b in "${ALL_BRANCHES_RAW[@]}"; do
    skip=0
    [ "$b" = "$CURRENT_BRANCH" ] && skip=1
    for p in "${PROTECTED_BRANCHES[@]}"; do
        [ "$b" = "$p" ] && skip=1 && break
    done
    [ $skip -eq 0 ] && DELETABLE_BRANCHES+=("$b")
done

if [ ${#DELETABLE_BRANCHES[@]} -eq 0 ]; then
    echo -e "${YELLOW}[!] No deletable branches found (all are protected or current).${NC}"
    exit 0
fi

echo -e "${GREEN}[OK] Found ${#DELETABLE_BRANCHES[@]} deletable branches${NC}"
echo

# Short name lookup
declare -a REPO_SHORT
for repo_name in "${REPO_NAMES[@]}"; do
    REPO_SHORT+=("$(repo_short_name "$repo_name")")
done

REPO_COL=6
for short in "${REPO_SHORT[@]}"; do
    len=${#short}
    [ $((len + 2)) -gt $REPO_COL ] && REPO_COL=$((len + 2))
done

BRANCH_COL=24
for b in "${DELETABLE_BRANCHES[@]}"; do
    len=${#b}
    [ $len -gt $BRANCH_COL ] && BRANCH_COL=$((len + 2))
done
IDX_MAX=${#DELETABLE_BRANCHES[@]}
IDX_WIDTH=$(( ${#IDX_MAX} + 3 ))  # "[N] "

# Display matrix table
echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}   Branch Audit — 可刪除分支${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo
echo -e "${DARK_GRAY}  [!] 已排除：main, master, develop 及目前分支 ($CURRENT_BRANCH)${NC}"
echo -e "${DARK_GRAY}  L=僅本地  R=僅遠端  v=本地+遠端  -=不存在${NC}"
echo

header_line=$(printf "  %*s%-${BRANCH_COL}s" "$IDX_WIDTH" "" "Branch")
for short in "${REPO_SHORT[@]}"; do
    header_line+=$(printf "%${REPO_COL}s" "$short")
done
echo -e "${BLUE}${header_line}${NC}"
sep_width=$(( IDX_WIDTH + BRANCH_COL + REPO_COUNT * REPO_COL ))
echo -e "${DARK_GRAY}  $(printf '%*s' "$sep_width" '' | tr ' ' '-')${NC}"

for idx in "${!DELETABLE_BRANCHES[@]}"; do
    b="${DELETABLE_BRANCHES[$idx]}"
    num=$((idx + 1))
    idx_str="[$num]"
    row=$(printf "  %-${IDX_WIDTH}s%-${BRANCH_COL}s" "$idx_str" "$b")

    for i in "${!REPO_NAMES[@]}"; do
        repo_name="${REPO_NAMES[$i]}"
        has_local=0; has_remote=0
        grep -q "^local|${repo_name}|${b}$"  "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_local=1
        grep -q "^remote|${repo_name}|${b}$" "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_remote=1

        if   [ $has_local -eq 0 ] && [ $has_remote -eq 0 ]; then cell=$(printf "%${REPO_COL}s" "-")
        elif [ $has_local -eq 1 ] && [ $has_remote -eq 1 ]; then cell=$(printf "%${REPO_COL}s" "v")
        elif [ $has_local -eq 1 ];                           then cell=$(printf "%${REPO_COL}s" "L")
        else                                                      cell=$(printf "%${REPO_COL}s" "R")
        fi
        row+="$cell"
    done
    echo -e "${GREEN}${row}${NC}"
done

echo

# Branch multi-selection
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}選擇要刪除的分支（可多選）：${NC}"
echo -e "${CYAN}==========================================${NC}"
echo
echo -e "${DARK_GRAY}  輸入編號，多個用逗號分隔（例：1,3,5）${NC}"
echo -e "${DARK_GRAY}  輸入 a 選取全部${NC}"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${CYAN}==========================================${NC}"

SELECTED_BRANCHES=()
while true; do
    read -rp "請輸入選擇: " raw_input
    case "$raw_input" in
        [Cc]) echo -e "${YELLOW}取消操作。${NC}"; exit 0 ;;
        a|A)  SELECTED_BRANCHES=("${DELETABLE_BRANCHES[@]}"); break ;;
        *)
            IFS=',' read -ra nums <<< "$raw_input"
            picked=()
            valid=1
            for n in "${nums[@]}"; do
                n="${n// /}"
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#DELETABLE_BRANCHES[@]}" ]; then
                    picked+=("${DELETABLE_BRANCHES[$((n-1))]}")
                else
                    echo -e "${RED}無效編號：$n（請輸入 1 到 ${#DELETABLE_BRANCHES[@]}）${NC}"
                    valid=0; break
                fi
            done
            if [ $valid -eq 1 ] && [ ${#picked[@]} -gt 0 ]; then
                # deduplicate
                declare -A _seen
                SELECTED_BRANCHES=()
                for b in "${picked[@]}"; do
                    [ -z "${_seen[$b]+x}" ] && SELECTED_BRANCHES+=("$b") && _seen[$b]=1
                done
                unset _seen
                break
            fi
            [ $valid -eq 1 ] && echo -e "${RED}未選擇任何分支，請重新輸入。${NC}"
            ;;
    esac
done

echo
echo -e "${BLUE}已選擇 ${#SELECTED_BRANCHES[@]} 個分支：${NC}"
for b in "${SELECTED_BRANCHES[@]}"; do echo -e "  - ${CYAN}$b${NC}"; done
echo

# Delete scope
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}選擇刪除範圍：${NC}"
echo -e "${CYAN}==========================================${NC}"
echo
echo -e "  ${GREEN}[1]${NC} 僅刪除本地分支"
echo -e "  ${GREEN}[2]${NC} 僅刪除遠端分支"
echo -e "  ${GREEN}[3]${NC} 同時刪除本地與遠端分支"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${CYAN}==========================================${NC}"

DELETE_LOCAL=false
DELETE_REMOTE=false
while true; do
    read -rp "請輸入選擇 (1-3/c): " opt
    case "$opt" in
        [Cc]) echo -e "${YELLOW}取消操作。${NC}"; exit 0 ;;
        1) DELETE_LOCAL=true;  DELETE_REMOTE=false; break ;;
        2) DELETE_LOCAL=false; DELETE_REMOTE=true;  break ;;
        3) DELETE_LOCAL=true;  DELETE_REMOTE=true;  break ;;
        *) echo -e "${RED}無效選擇，請輸入 1、2、3 或 c${NC}" ;;
    esac
done

# Delete plan + confirm
local_yn=$([ "$DELETE_LOCAL"  = true ] && echo "YES" || echo "NO")
remote_yn=$([ "$DELETE_REMOTE" = true ] && echo "YES" || echo "NO")
SUBMODULE_COUNT=$(( REPO_COUNT - 1 ))

echo
echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}   刪除計畫${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo -e "${CYAN}  分支（${#SELECTED_BRANCHES[@]} 個）：$(IFS=', '; echo "${SELECTED_BRANCHES[*]}")${NC}"
echo -e "${CYAN}  刪除本地：$local_yn${NC}"
echo -e "${CYAN}  刪除遠端：$remote_yn${NC}"
echo -e "${YELLOW}  影響範圍：$REPO_COUNT 個 repo（root + $SUBMODULE_COUNT submodules）${NC}"
echo

# Per-repo-per-branch breakdown
echo -e "${BLUE}--- 各 repo 執行明細 ---${NC}"
echo

del_bW=$BRANCH_COL
[ $del_bW -lt 20 ] && del_bW=20
del_rW=$REPO_COL
[ $del_rW -lt 8 ] && del_rW=8

del_hdr=$(printf "  %-${del_bW}s%-${del_rW}s" "分支" "Repo")
del_hdr="${del_hdr}  本地   遠端  動作"
echo -e "${BLUE}${del_hdr}${NC}"
echo -e "${DARK_GRAY}  $(printf '%*s' $(( del_bW + del_rW + 28 )) '' | tr ' ' '-')${NC}"

del_has_local_only_with_remote_scope=0
for b in "${SELECTED_BRANCHES[@]}"; do
    for i in "${!REPO_NAMES[@]}"; do
        repo_name="${REPO_NAMES[$i]}"
        short="${REPO_SHORT[$i]}"
        has_local=0; has_remote=0
        grep -q "^local|${repo_name}|${b}$"  "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_local=1
        grep -q "^remote|${repo_name}|${b}$" "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_remote=1

        local_str=$([ $has_local  -eq 1 ] && echo "[L]" || echo "[-]")
        remote_str=$([ $has_remote -eq 1 ] && echo "[R]" || echo "[-]")

        action=""
        [ "$DELETE_LOCAL"  = true ] && [ $has_local  -eq 1 ] && action="刪本地"
        if [ "$DELETE_REMOTE" = true ] && [ $has_remote -eq 1 ]; then
            [ -n "$action" ] && action="$action + 刪遠端" || action="刪遠端"
        fi
        [ -z "$action" ] && action="SKIP"

        if [ "$DELETE_REMOTE" = true ] && [ $has_remote -eq 0 ] && [ $has_local -eq 1 ]; then
            del_has_local_only_with_remote_scope=1
        fi

        row=$(printf "  %-${del_bW}s%-${del_rW}s  %-5s   %-5s  %s" "$b" "$short" "$local_str" "$remote_str" "$action")
        if [ "$action" = "SKIP" ]; then
            echo -e "${DARK_GRAY}${row}${NC}"
        elif [ "$DELETE_REMOTE" = true ] && [ $has_remote -eq 0 ] && [ $has_local -eq 1 ]; then
            echo -e "${YELLOW}${row}${NC}"
        else
            echo -e "${GREEN}${row}${NC}"
        fi
    done
done
echo

if [ $del_has_local_only_with_remote_scope -eq 1 ]; then
    echo -e "${YELLOW}[!] 警告：部分選定分支僅存在本地（L），沒有遠端副本。${NC}"
    echo -e "${YELLOW}    選擇「刪除遠端」對這些分支毫無影響，本地副本將保留。${NC}"
    echo -e "${YELLOW}    若要同時刪除本地副本，請取消後改選 [3] 同時刪除本地與遠端分支。${NC}"
    echo
fi

echo -e "${YELLOW}==========================================${NC}"
echo -e "${RED}[!!!] WARNING: 此操作無法復原！${NC}"
read -rp "確認要刪除這些分支？(y/N): " confirm
if [ "$confirm" != "y" ]; then echo -e "${YELLOW}取消操作。${NC}"; exit 0; fi
echo

# Execute
success_count=0
fail_count=0
FAILED_LIST=()

set +e
for i in "${!REPO_NAMES[@]}"; do
    repo_name="${REPO_NAMES[$i]}"
    repo_path="${REPO_PATHS[$i]}"

    for b in "${SELECTED_BRANCHES[@]}"; do
        has_local=0; has_remote=0
        grep -q "^local|${repo_name}|${b}$"  "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_local=1
        grep -q "^remote|${repo_name}|${b}$" "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_remote=1

        if [ "$DELETE_LOCAL" = true ]; then
            if [ $has_local -eq 1 ]; then
                git -C "$repo_path" branch -D "$b" 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo -e "  ${GREEN}[OK]${NC} $repo_name / $b — local deleted"
                else
                    echo -e "  ${YELLOW}[!]${NC} $repo_name / $b — local delete failed"
                fi
            else
                echo -e "  ${DARK_GRAY}[-] $repo_name / $b — no local, skipped${NC}"
            fi
        fi

        if [ "$DELETE_REMOTE" = true ]; then
            if [ $has_remote -eq 1 ]; then
                git -C "$repo_path" push "$REMOTE" --delete "$b" 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo -e "  ${GREEN}[OK]${NC} $repo_name / $b — remote deleted"
                    success_count=$((success_count + 1))
                else
                    echo -e "  ${RED}[X]${NC} $repo_name / $b — remote delete failed"
                    fail_count=$((fail_count + 1))
                    FAILED_LIST+=("$repo_name/$b (remote)")
                fi
            else
                echo -e "  ${DARK_GRAY}[-] $repo_name / $b — no remote, skipped${NC}"
            fi
        elif [ "$DELETE_LOCAL" = true ] && [ $has_local -eq 1 ]; then
            success_count=$((success_count + 1))
        fi
    done
done
set -e

echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}   Summary${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}  Successful: $success_count${NC}"
echo -e "${RED}  Failed:     $fail_count${NC}"

if [ ${#FAILED_LIST[@]} -gt 0 ]; then
    echo
    echo -e "${RED}Failed:${NC}"
    for f in "${FAILED_LIST[@]}"; do echo -e "  ${RED}$f${NC}"; done
    exit 1
fi

echo
echo -e "${GREEN}[OK] Branch deletion completed!${NC}"
echo
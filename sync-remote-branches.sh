#!/bin/bash

# ===========================================
# Git Remote Branch Sync Auditor
# 清點所有 repo（root + submodules）的 remote branch 同步狀態
# 找出哪些 branch 在某些 repo 的 remote 缺失，並提供 push 補齊功能
#
# 用法:
#   ./monorepo-scripts/sync-remote-branches.sh
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
echo -e "${CYAN}   Git Remote Branch Sync Auditor${NC}"
echo -e "${CYAN}==========================================${NC}"
echo

# Collect submodule paths from .gitmodules
SUBMODULE_LIST=$(git config --file .gitmodules --get-regexp path 2>/dev/null | cut -d' ' -f2-)
if [ -z "$SUBMODULE_LIST" ]; then
    echo -e "${RED}ERROR: No submodules found or .gitmodules not readable${NC}"
    echo -e "${RED}       解析到的 repo root: $PROJECT_ROOT${NC}"
    exit 1
fi

# Build repo name and path arrays
REPO_NAMES=("root")
REPO_PATHS=("$PROJECT_ROOT")
while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    REPO_NAMES+=("$sub")
    REPO_PATHS+=("$PROJECT_ROOT/$sub")
done <<< "$SUBMODULE_LIST"

REPO_COUNT=${#REPO_NAMES[@]}

# Display repos and current branches
echo -e "${BLUE}Found $REPO_COUNT repositories:${NC}"
for i in "${!REPO_NAMES[@]}"; do
    branch=$(git -C "${REPO_PATHS[$i]}" branch --show-current 2>/dev/null) || branch=""
    echo -e "  - ${CYAN}${REPO_NAMES[$i]}${NC} ($branch)"
done
echo

# -----------------------------------------------------------------------
# Mode selection
# -----------------------------------------------------------------------
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}選擇操作模式：${NC}"
echo -e "${CYAN}==========================================${NC}"
echo
echo -e "  ${GREEN}[1]${NC} 僅清點（使用快取的遠端資訊，不連網）"
echo -e "  ${GREEN}[2]${NC} 先 fetch（建議 — 確保遠端資訊是最新的）"
echo
echo -e "  ${YELLOW}[c]${NC} 取消"
echo
echo -e "${CYAN}==========================================${NC}"

while true; do
    read -rp "請輸入選擇 (1-2/c): " mode_choice
    case "$mode_choice" in
        [Cc])
            echo -e "${YELLOW}Operation cancelled.${NC}"
            exit 0
            ;;
        1)
            echo -e "${GREEN}[OK] Using cached remote info${NC}"
            echo
            break
            ;;
        2)
            echo -e "${GREEN}[OK] Fetching all remotes (--prune)...${NC}"
            echo
            set +e
            for i in "${!REPO_NAMES[@]}"; do
                echo -e "  Fetching ${CYAN}${REPO_NAMES[$i]}${NC}..."
                git -C "${REPO_PATHS[$i]}" fetch --all --prune --quiet 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo -e "  ${YELLOW}[!] WARNING: Fetch had errors for ${REPO_NAMES[$i]}${NC}"
                fi
            done
            set -e
            echo -e "${GREEN}[OK] Fetch completed${NC}"
            echo
            break
            ;;
        *)
            echo -e "${RED}無效選擇，請輸入 1、2 或 c${NC}"
            ;;
    esac
done

# -----------------------------------------------------------------------
# Collect branch status for each repo using temp files
# Format: <branch>|<repo>|L|R   (L/R = 1 or 0)
# -----------------------------------------------------------------------
echo -e "${BLUE}Auditing branch status across all repositories...${NC}"

TMPDIR_DATA=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DATA"' EXIT

set +e
for i in "${!REPO_NAMES[@]}"; do
    repo_name="${REPO_NAMES[$i]}"
    repo_path="${REPO_PATHS[$i]}"

    # Local branches
    git -C "$repo_path" branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "local|${repo_name}|${b}" >> "$TMPDIR_DATA/raw.txt"
    done

    # Remote branches：只列舉設定的 remote。git branch -r 會混入其他 remote，
    # 讓 other/xxx 被當成分支名列進清點結果。
    git -C "$repo_path" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" 2>/dev/null |
        grep -v '^HEAD$' |
        sort -u | while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "remote|${repo_name}|${b}" >> "$TMPDIR_DATA/raw.txt"
    done
done
set -e

# Collect all unique branch names
if [ ! -f "$TMPDIR_DATA/raw.txt" ]; then
    echo -e "${YELLOW}[!] No branches found across any repository.${NC}"
    exit 0
fi

ALL_BRANCHES=($(awk -F'|' '{ print $3 }' "$TMPDIR_DATA/raw.txt" | sort -u))
BRANCH_COUNT=${#ALL_BRANCHES[@]}
echo -e "${GREEN}[OK] Found $BRANCH_COUNT unique branches total${NC}"
echo

# Build short repo names for table header (lib lookup, fallback to last dash-segment)
declare -a REPO_SHORT
for repo_name in "${REPO_NAMES[@]}"; do
    REPO_SHORT+=("$(repo_short_name "$repo_name")")
done

# Column widths
BRANCH_COL=24
for b in "${ALL_BRANCHES[@]}"; do
    len=${#b}
    [ $len -gt $BRANCH_COL ] && BRANCH_COL=$((len + 2))
done
REPO_COL=6
for short in "${REPO_SHORT[@]}"; do
    len=${#short}
    [ $((len + 2)) -gt $REPO_COL ] && REPO_COL=$((len + 2))
done

# -----------------------------------------------------------------------
# Print audit table
# -----------------------------------------------------------------------
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   Branch Audit Report${NC}"
echo -e "${BLUE}==========================================${NC}"
echo
echo -e "${DARK_GRAY}  L=local-only  R=remote-only  v=both(OK)  -=missing${NC}"
echo

# Header row
header_line=$(printf "  %-${BRANCH_COL}s" "Branch")
for short in "${REPO_SHORT[@]}"; do
    header_line+=$(printf "%${REPO_COL}s" "$short")
done
echo -e "${BLUE}${header_line}${NC}"
sep_width=$(( BRANCH_COL + REPO_COUNT * REPO_COL ))
echo -e "${DARK_GRAY}  $(printf '%*s' "$sep_width" '' | tr ' ' '-')${NC}"

MISSING_REMOTE_LIST=()  # "branch|repo_name|repo_path"
MISSING_BOTH_LIST=()    # "branch|repo_name"

for b in "${ALL_BRANCHES[@]}"; do
    row=$(printf "  %-${BRANCH_COL}s" "$b")
    row_has_issue=0

    for i in "${!REPO_NAMES[@]}"; do
        repo_name="${REPO_NAMES[$i]}"
        repo_path="${REPO_PATHS[$i]}"

        has_local=0
        has_remote=0
        grep -q "^local|${repo_name}|${b}$"  "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_local=1
        grep -q "^remote|${repo_name}|${b}$" "$TMPDIR_DATA/raw.txt" 2>/dev/null && has_remote=1

        if [ $has_local -eq 0 ] && [ $has_remote -eq 0 ]; then
            cell=$(printf "%${REPO_COL}s" "-")
            MISSING_BOTH_LIST+=("${b}|${repo_name}")
            row_has_issue=1
        elif [ $has_local -eq 1 ] && [ $has_remote -eq 1 ]; then
            cell=$(printf "%${REPO_COL}s" "v")
        elif [ $has_local -eq 1 ] && [ $has_remote -eq 0 ]; then
            cell=$(printf "%${REPO_COL}s" "L")
            MISSING_REMOTE_LIST+=("${b}|${repo_name}|${repo_path}")
            row_has_issue=1
        else
            cell=$(printf "%${REPO_COL}s" "R")
        fi

        row+="$cell"
    done

    if [ $row_has_issue -eq 1 ]; then
        echo -e "${YELLOW}${row}${NC}"
    else
        echo -e "${GREEN}${row}${NC}"
    fi
done

echo

# -----------------------------------------------------------------------
# Issues summary
# -----------------------------------------------------------------------
total_missing_remote=${#MISSING_REMOTE_LIST[@]}
total_missing_both=${#MISSING_BOTH_LIST[@]}

if [ $total_missing_remote -eq 0 ] && [ $total_missing_both -eq 0 ]; then
    echo -e "${GREEN}[OK] All branches are fully synced across all repositories!${NC}"
    echo -e "${GREEN}     Every local branch has a corresponding remote tracking branch.${NC}"
    echo
    exit 0
fi

echo -e "${YELLOW}==========================================${NC}"
echo -e "${YELLOW}   Issues Found${NC}"
echo -e "${YELLOW}==========================================${NC}"
echo

if [ $total_missing_both -gt 0 ]; then
    echo -e "${YELLOW}--- Missing entirely in some repos (no local, no remote): $total_missing_both ---${NC}"
    for entry in "${MISSING_BOTH_LIST[@]}"; do
        branch="${entry%%|*}"
        repo="${entry#*|}"
        echo -e "  ${YELLOW}[!] '$branch' not present (local or remote) in '$repo'${NC}"
    done
    echo
    echo -e "${DARK_GRAY}  Cannot auto-push — branch doesn't exist locally in affected repos.${NC}"
    echo -e "${DARK_GRAY}  Fix: run switch-branch.sh to create the branch across all repos first.${NC}"
    echo
fi

if [ $total_missing_remote -gt 0 ]; then
    echo -e "${YELLOW}--- Local-only branches (need push to remote): $total_missing_remote ---${NC}"
    for entry in "${MISSING_REMOTE_LIST[@]}"; do
        branch="${entry%%|*}"
        rest="${entry#*|}"
        repo="${rest%%|*}"
        echo -e "  ${YELLOW}[!] '$branch' in '$repo' — local only, not pushed${NC}"
    done
    echo

    # -----------------------------------------------------------------------
    # Ask to push
    # -----------------------------------------------------------------------
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}是否推送缺失的遠端分支？${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} 一次推送全部 $total_missing_remote 筆"
    echo -e "  ${GREEN}[2]${NC} 逐筆確認後選擇性推送"
    echo
    echo -e "  ${YELLOW}[c]${NC} 取消（保留清點報告，跳過推送）"
    echo
    echo -e "${CYAN}==========================================${NC}"

    push_choice=""
    while true; do
        read -rp "請輸入選擇 (1-2/c): " push_choice
        case "$push_choice" in
            [Cc])
                echo -e "${YELLOW}[!] No branches were pushed. Remote branches remain out of sync.${NC}"
                exit 0
                ;;
            1|2) break ;;
            *) echo -e "${RED}無效選擇。${NC}" ;;
        esac
    done

    ENTRIES_TO_PUSH=()
    if [ "$push_choice" = "1" ]; then
        ENTRIES_TO_PUSH=("${MISSING_REMOTE_LIST[@]}")
    else
        echo
        echo -e "${BLUE}逐筆確認，按 y 推送，其他鍵跳過：${NC}"
        echo
        for entry in "${MISSING_REMOTE_LIST[@]}"; do
            branch="${entry%%|*}"
            rest="${entry#*|}"
            repo="${rest%%|*}"
            read -rp "  推送 '$branch' 至 '$repo' 遠端？(y/N): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                ENTRIES_TO_PUSH+=("$entry")
            fi
        done
    fi

    if [ ${#ENTRIES_TO_PUSH[@]} -eq 0 ]; then
        echo -e "${YELLOW}[!] Nothing selected to push.${NC}"
        exit 0
    fi

    echo
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   Pushing ${#ENTRIES_TO_PUSH[@]} branch(es)...${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo

    success_count=0
    fail_count=0
    FAILED_LIST=()

    set +e
    for entry in "${ENTRIES_TO_PUSH[@]}"; do
        branch="${entry%%|*}"
        rest="${entry#*|}"
        repo="${rest%%|*}"
        repo_path="${rest#*|}"

        echo -e "  ${BLUE}Pushing '$branch' in '$repo'...${NC}"
        git -C "$repo_path" push -u "$REMOTE" "$branch"
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}[OK] Pushed successfully${NC}"
            success_count=$((success_count + 1))
        else
            echo -e "  ${RED}[X] ERROR: Push failed${NC}"
            fail_count=$((fail_count + 1))
            FAILED_LIST+=("$repo/$branch")
        fi
    done
    set -e

    echo
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}   Push Summary${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}  Successful: $success_count${NC}"
    echo -e "${RED}  Failed:     $fail_count${NC}"

    if [ ${#FAILED_LIST[@]} -gt 0 ]; then
        echo
        echo -e "${RED}Failed pushes:${NC}"
        for f in "${FAILED_LIST[@]}"; do
            echo -e "  ${RED}$f${NC}"
        done
        exit 1
    fi

    echo
    echo -e "${GREEN}[OK] All selected branches pushed to remote!${NC}"
fi

echo
exit 0

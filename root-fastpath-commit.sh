#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/repo-context.sh"
source "$SCRIPT_DIR/lib/root-fastpath.sh"
REPO_ROOT="$(resolve_repo_root "$SCRIPT_DIR")"
REMOTE="$(resolve_remote_name "$REPO_ROOT")"
REMOTE_RE="$(remote_name_regex "$REMOTE")"

step() { echo; echo -e "\033[0;36m=== $1 ===\033[0m"; }

# 任何 git 呼叫失敗或輸出非數字都必須 fail closed（回非 0），不可默默當成 0，否則會把
# 真正的 git 錯誤誤判成「已同步 / 無變更」而錯誤地繼續推送。
get_divergence() {
    local repo_path="$1" branch="$2"
    if ! git -C "$repo_path" rev-parse --verify "$REMOTE/$branch" >/dev/null 2>&1; then
        echo "-1 -1"; return 0
    fi
    local ahead behind
    ahead="$(git -C "$repo_path" rev-list --count "$REMOTE/$branch..HEAD" 2>/dev/null)" || return 1
    behind="$(git -C "$repo_path" rev-list --count "HEAD..$REMOTE/$branch" 2>/dev/null)" || return 1
    case "$ahead" in ''|*[!0-9]*) return 1 ;; esac
    case "$behind" in ''|*[!0-9]*) return 1 ;; esac
    echo "$ahead $behind"
}

# 讀取 root 於某個 ref（HEAD / <remote>/<branch>）記錄的 submodule gitlink SHA。
gitlink_sha() {
    local repo_root="$1" ref="$2" sub="$3" line
    line="$(git -C "$repo_root" ls-tree "$ref" -- "$sub" 2>/dev/null)" || return 1
    [ -n "$line" ] || return 1
    echo "$line" | awk '{print $3}'
}

step "Check root fast-path eligibility"
# 冪等性：若 commit 已完成但 push 未完成（working tree 乾淨且 root 領先遠端），
# 直接進入 push 階段續跑，不再要求 working tree 有未提交的 gitlink 漂移。
resume_mode=0
if [ -z "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
    resume_branch="$(git -C "$REPO_ROOT" branch --show-current)"
    if git -C "$REPO_ROOT" rev-parse --verify "$REMOTE/$resume_branch" >/dev/null 2>&1; then
        pre_ahead="$(git -C "$REPO_ROOT" rev-list --count "$REMOTE/$resume_branch..HEAD" 2>/dev/null || echo 0)"
    else
        pre_ahead=1
    fi
    case "$pre_ahead" in ''|*[!0-9]*) pre_ahead=0 ;; esac
    if [ "$pre_ahead" -gt 0 ]; then
        resume_mode=1
        echo -e "\033[0;33mroot working tree clean but ahead of $REMOTE — resuming push-only for existing commit(s)\033[0m"
    fi
fi

if [ "$resume_mode" -eq 0 ]; then
    if ! fastpath_check "$REPO_ROOT"; then
        exit 1
    fi

    step "Commit root submodule refs"
    msg="$(fastpath_build_commit_message)"
    if fastpath_commit "$REPO_ROOT" "$msg"; then
        echo -e "\033[0;32m[OK] Root submodule refs committed\033[0m"
    else
        echo -e "\033[0;31m[X] ERROR: Failed to commit root submodule refs\033[0m"
        exit 1
    fi
fi

step "Fetch & divergence check"
mapfile -t submodules < <(fastpath_get_submodules "$REPO_ROOT")
if [ "${#submodules[@]}" -eq 0 ]; then
    echo -e "\033[0;31m[X] ERROR: failed to enumerate submodules from .gitmodules\033[0m"
    exit 1
fi
branch="$(git -C "$REPO_ROOT" branch --show-current)"

fetch_failed=()
git -C "$REPO_ROOT" fetch "$REMOTE" --quiet || fetch_failed+=("root")
for sub in "${submodules[@]}"; do
    git -C "$REPO_ROOT/$sub" fetch "$REMOTE" --quiet || fetch_failed+=("$sub")
done
if [ "${#fetch_failed[@]}" -gt 0 ]; then
    echo -e "\033[0;31m[X] Failed to fetch $REMOTE for: ${fetch_failed[*]}\033[0m"
    exit 1
fi

# 直接從 root 已提交的 tree 推導「本次未推送 commit 所改動的 submodule gitlink」，
# 這才是真正會被 push 出去的內容；normal 與 resume 兩種情境共用同一條路徑。
base_ref=""
if git -C "$REPO_ROOT" rev-parse --verify "$REMOTE/$branch" >/dev/null 2>&1; then
    base_ref="$REMOTE/$branch"
fi
changed_subs=()
changed_shas=()
for sub in "${submodules[@]}"; do
    head_sha="$(gitlink_sha "$REPO_ROOT" HEAD "$sub")" || continue
    if [ -n "$base_ref" ]; then
        base_sha="$(gitlink_sha "$REPO_ROOT" "$base_ref" "$sub" 2>/dev/null || true)"
        [ "$head_sha" = "$base_sha" ] && continue
    fi
    changed_subs+=("$sub")
    changed_shas+=("$head_sha")
done

behind_repos=()
div="$(get_divergence "$REPO_ROOT" "$branch")" || {
    echo -e "\033[0;31m[X] ERROR: failed to compute divergence for root\033[0m"; exit 1
}
read -r root_ahead root_behind <<< "$div"
[ "$root_behind" -gt 0 ] && behind_repos+=("root")

# 需要 push 的 submodule：推送它「當前所在分支」，與 root 分支名是否相同無關；
# 真正的安全條件是「root gitlink 記錄的 SHA 事後必須可從遠端觸及」。
to_push=()
to_push_branch=()
if [ "${#changed_subs[@]}" -gt 0 ]; then
    for i in "${!changed_subs[@]}"; do
        sub="${changed_subs[$i]}"
        sub_path="$REPO_ROOT/$sub"
        sub_branch="$(git -C "$sub_path" branch --show-current)"
        if [ -z "$sub_branch" ]; then
            echo -e "\033[0;33m  $sub: detached HEAD — cannot push a branch; will verify SHA reachability\033[0m"
            continue
        fi
        div="$(get_divergence "$sub_path" "$sub_branch")" || {
            echo -e "\033[0;31m[X] ERROR: failed to compute divergence for $sub\033[0m"; exit 1
        }
        read -r s_ahead s_behind <<< "$div"
        if [ "$s_behind" -gt 0 ]; then behind_repos+=("$sub"); continue; fi
        to_push+=("$sub")
        to_push_branch+=("$sub_branch")
    done
fi

if [ "${#behind_repos[@]}" -gt 0 ]; then
    echo -e "\033[0;31m[X] Push aborted: manual sync required for: ${behind_repos[*]}\033[0m"
    exit 1
fi

step "Dry-run push sync"
for sub in "${to_push[@]:-}"; do
    [ -n "$sub" ] && echo "  $sub: git push (dry-run, skipped)"
done
{ [ "$root_ahead" = "-1" ] || [ "$root_ahead" -gt 0 ]; } && echo "  root: git push (dry-run, skipped)"

step "Push root fast-path"
push_failed=()
if [ "${#to_push[@]}" -gt 0 ]; then
    for i in "${!to_push[@]}"; do
        sub="${to_push[$i]}"
        sub_branch="${to_push_branch[$i]}"
        sub_path="$REPO_ROOT/$sub"
        div="$(get_divergence "$sub_path" "$sub_branch")" || { push_failed+=("$sub"); continue; }
        read -r s_ahead _ <<< "$div"
        if [ "$s_ahead" = "-1" ]; then
            git -C "$sub_path" push -u "$REMOTE" "$sub_branch" && echo -e "\033[0;32m  $sub: pushed ($sub_branch)\033[0m" || push_failed+=("$sub")
        else
            git -C "$sub_path" push "$REMOTE" "$sub_branch" && echo -e "\033[0;32m  $sub: pushed ($sub_branch)\033[0m" || push_failed+=("$sub")
        fi
    done
fi

# 不變量：root gitlink 記錄的每個 submodule SHA，都必須在此刻可從遠端觸及，
# 否則新 clone 的 root 會指向一個從未發佈的 submodule commit。任一未觸及即中止，root 絕不 push。
step "Verify committed submodule refs are reachable on $REMOTE"
unreachable=()
if [ "${#changed_subs[@]}" -gt 0 ]; then
    for i in "${!changed_subs[@]}"; do
        sub="${changed_subs[$i]}"
        sha="${changed_shas[$i]}"
        sub_path="$REPO_ROOT/$sub"
        if git -C "$sub_path" branch -r --contains "$sha" 2>/dev/null | grep -qE "^[[:space:]]*$REMOTE_RE/"; then
            echo -e "\033[0;32m  $sub: ${sha:0:7} reachable on $REMOTE\033[0m"
        else
            echo -e "\033[0;31m  $sub: ${sha:0:7} NOT reachable on $REMOTE\033[0m"
            unreachable+=("$sub")
        fi
    done
fi

if [ "${#push_failed[@]}" -gt 0 ] || [ "${#unreachable[@]}" -gt 0 ]; then
    [ "${#push_failed[@]}" -gt 0 ] && echo -e "\033[0;31m[X] Submodule push failed for: ${push_failed[*]}. Root will NOT be pushed.\033[0m"
    [ "${#unreachable[@]}" -gt 0 ] && echo -e "\033[0;31m[X] Committed submodule refs NOT reachable on $REMOTE for: ${unreachable[*]}. Root will NOT be pushed.\033[0m"
    exit 1
fi

if [ "$root_ahead" = "-1" ] || [ "$root_ahead" -gt 0 ]; then
    if [ "$root_ahead" = "-1" ]; then
        git -C "$REPO_ROOT" push -u "$REMOTE" "$branch" && echo -e "\033[0;32m  root: pushed\033[0m" || {
            echo -e "\033[0;31m[X] ERROR: root push failed\033[0m"
            exit 1
        }
    else
        git -C "$REPO_ROOT" push "$REMOTE" "$branch" && echo -e "\033[0;32m  root: pushed\033[0m" || {
            echo -e "\033[0;31m[X] ERROR: root push failed\033[0m"
            exit 1
        }
    fi
fi

echo
echo -e "\033[0;32m[OK] Root fast-path commit and push completed.\033[0m"

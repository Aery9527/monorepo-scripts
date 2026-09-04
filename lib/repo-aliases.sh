#!/bin/bash
# lib/repo-aliases.sh — repo 顯示縮寫 loader

# 版本守門集中在 lib/repo-context.sh，所有腳本都會先載入它。
declare -gA REPO_ALIASES

load_repo_alias_map() {
    local repo_root="$1"
    REPO_ALIASES=()
    local alias_file="$repo_root/scripts/config/repo-aliases.txt"
    [ -f "$alias_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        local name="${line%%[[:space:]]*}"
        [ "$name" = "$line" ] && continue
        local alias_val="${line#*[[:space:]]}"
        REPO_ALIASES["$name"]="$alias_val"
    done < "$alias_file"
}

repo_short_name() {
    local repo_name="$1"
    if [ -n "${REPO_ALIASES[$repo_name]:-}" ]; then
        echo "${REPO_ALIASES[$repo_name]}"
        return 0
    fi
    echo "${repo_name##*-}"
}

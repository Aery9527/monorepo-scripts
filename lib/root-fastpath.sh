#!/bin/bash
# lib/root-fastpath.sh — root-only submodule-ref fastpath 邏輯

FASTPATH_CHANGES=()
FASTPATH_REASON=""

fastpath_get_submodules() {
    local repo_root="$1"
    # 解析與防護細節見 lib/repo-context.sh 的 list_initialized_submodule_paths（呼叫端一律先 source 它）。
    list_initialized_submodule_paths "$repo_root"
}

_fastpath_change_info() {
    local repo_root="$1" name="$2"
    local sub_path="$repo_root/$name"

    local ls_tree old_sha new_sha
    ls_tree="$(git -C "$repo_root" ls-tree HEAD -- "$name" 2>/dev/null)"
    [ -n "$ls_tree" ] || { echo "failed to read recorded SHA for $name"; return 1; }
    old_sha="$(echo "$ls_tree" | awk '{print $3}')"

    new_sha="$(git -C "$sub_path" rev-parse HEAD 2>/dev/null)"
    [ -n "$new_sha" ] || { echo "failed to read current HEAD for $name"; return 1; }

    if ! git -C "$sub_path" cat-file -e "$old_sha" 2>/dev/null; then
        echo "$name|$old_sha|$new_sha|-1|-1|"
        return 0
    fi

    local ahead behind subject
    ahead="$(git -C "$sub_path" rev-list --count "$old_sha..$new_sha" 2>/dev/null)" \
        || { echo "failed to count commits ahead for $name"; return 1; }
    behind="$(git -C "$sub_path" rev-list --count "$new_sha..$old_sha" 2>/dev/null)" \
        || { echo "failed to count commits behind for $name"; return 1; }
    case "$ahead" in ''|*[!0-9]*) echo "invalid ahead count for $name: '$ahead'"; return 1 ;; esac
    case "$behind" in ''|*[!0-9]*) echo "invalid behind count for $name: '$behind'"; return 1 ;; esac
    subject=""
    if [ "$ahead" -gt 0 ]; then
        subject="$(git -C "$sub_path" log --format=%s "$old_sha..$new_sha" 2>/dev/null | head -n1)"
    fi
    echo "$name|$old_sha|$new_sha|$ahead|$behind|$subject"
}

fastpath_check() {
    local repo_root="$1"
    FASTPATH_CHANGES=()
    FASTPATH_REASON=""

    local submodules
    submodules="$(fastpath_get_submodules "$repo_root")"
    if [ -z "$submodules" ]; then
        FASTPATH_REASON="failed to enumerate submodules from .gitmodules"
        echo "fast-path unavailable: $FASTPATH_REASON" >&2
        return 1
    fi

    # 必須用 -z：預設的 --porcelain 會把含空白等特殊字元的路徑用雙引號包起來
    #     M "lib/real dep"
    # 而 .gitmodules 取到的值是不帶引號的 lib/real dep，兩者永遠比不中，
    # 含空白路徑的 submodule 會被誤判成「非 submodule 檔案」而使 fast-path 永遠不可用。
    # core.quotePath=false 無效（它只影響非 ASCII）；-z 才會輸出未加工的原始路徑。
    # NUL 無法存進 bash 變數，因此先逐筆讀進陣列再處理。
    local status_entries=()
    while IFS= read -r -d '' entry; do
        status_entries+=("$entry")
    done < <(git -C "$repo_root" status --porcelain -z 2>/dev/null)

    if [ "${#status_entries[@]}" -eq 0 ]; then
        FASTPATH_REASON="root has no changes"
        echo "fast-path unavailable: $FASTPATH_REASON" >&2
        return 1
    fi

    local changed=() non_submodule=()
    local idx=0 entry code file
    # -z 下 rename/copy 會多輸出一個「原路徑」欄位，必須額外跳過，
    # 否則它會被當成一個獨立項目而誤判為非 submodule 檔案。
    while [ "$idx" -lt "${#status_entries[@]}" ]; do
        entry="${status_entries[$idx]}"
        idx=$((idx + 1))
        [ ${#entry} -lt 3 ] && continue
        code="${entry:0:2}"
        file="${entry:3}"
        case "$code" in R*|C*) idx=$((idx + 1)) ;; esac

        if echo "$submodules" | grep -qxF "$file"; then
            changed+=("$file")
            continue
        fi
        if [ "$code" = "??" ]; then continue; fi
        non_submodule+=("$file")
    done

    if [ "${#non_submodule[@]}" -gt 0 ]; then
        FASTPATH_REASON="requires root-only submodule ref changes; non-submodule files changed: $(IFS=,; echo "${non_submodule[*]}")"
        echo "fast-path unavailable: $FASTPATH_REASON" >&2
        return 1
    fi
    if [ "${#changed[@]}" -eq 0 ]; then
        FASTPATH_REASON="root has no changes"
        echo "fast-path unavailable: $FASTPATH_REASON" >&2
        return 1
    fi

    local info
    for name in "${changed[@]}"; do
        info="$(_fastpath_change_info "$repo_root" "$name")" || {
            FASTPATH_REASON="$info"
            echo "fast-path unavailable: $FASTPATH_REASON" >&2
            return 1
        }
        FASTPATH_CHANGES+=("$info")
    done

    echo "eligible"
    return 0
}

_fastpath_format_span() {
    local old_sha="$1" new_sha="$2" ahead="$3" behind="$4"
    local old_short="${old_sha:0:7}" new_short="${new_sha:0:7}"

    if [ "$ahead" = "-1" ]; then
        echo "$old_short -> $new_short (old ref unavailable)"
        return
    fi
    if [ "$ahead" -gt 0 ] && [ "$behind" -eq 0 ]; then
        local unit="commits"; [ "$ahead" -eq 1 ] && unit="commit"
        echo "$old_short -> $new_short ($ahead $unit)"
        return
    fi
    if [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; then
        local unit="commits"; [ "$behind" -eq 1 ] && unit="commit"
        echo "$old_short -> $new_short (rewind $behind $unit)"
        return
    fi
    if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
        echo "$old_short -> $new_short (no history change)"
        return
    fi
    echo "$old_short -> $new_short (history rewritten)"
}

fastpath_build_commit_message() {
    local names=() subject_line body=""
    for entry in "${FASTPATH_CHANGES[@]}"; do
        IFS='|' read -r name old_sha new_sha ahead behind subj <<< "$entry"
        names+=("$name")
    done

    local suffix="submodule refs"
    [ "${#names[@]}" -eq 1 ] && suffix="submodule ref"
    subject_line="chore(root): 同步 $(IFS=、; echo "${names[*]}") $suffix"

    for entry in "${FASTPATH_CHANGES[@]}"; do
        IFS='|' read -r name old_sha new_sha ahead behind subj <<< "$entry"
        body+="- $name: $(_fastpath_format_span "$old_sha" "$new_sha" "$ahead" "$behind")"$'\n'
        [ -n "$subj" ] && body+="  最新: $subj"$'\n'
    done

    printf '%s\n\n%s' "$subject_line" "$body"
}

fastpath_commit() {
    local repo_root="$1" message="$2"
    local names=()
    for entry in "${FASTPATH_CHANGES[@]}"; do
        IFS='|' read -r name _ <<< "$entry"
        names+=("$name")
    done

    git -C "$repo_root" add -- "${names[@]}" || { echo "git add failed" >&2; return 1; }
    printf '%s' "$message" | git -C "$repo_root" commit -F - || { echo "git commit failed" >&2; return 1; }
}

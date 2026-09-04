#!/bin/bash
# lib/root-fastpath.sh — root-only submodule-ref fastpath 邏輯

FASTPATH_CHANGES=()
FASTPATH_REASON=""

fastpath_get_submodules() {
    local repo_root="$1"
    git config --file "$repo_root/.gitmodules" --get-regexp path 2>/dev/null | cut -d' ' -f2-
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

    local status_lines
    status_lines="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
    if [ -z "$status_lines" ]; then
        FASTPATH_REASON="root has no changes"
        echo "fast-path unavailable: $FASTPATH_REASON" >&2
        return 1
    fi

    local changed=() non_submodule=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local code="${line:0:2}"
        local file="${line:3}"
        file="$(echo "$file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$file" in *" -> "*) file="${file##* -> }" ;; esac

        if echo "$submodules" | grep -qxF "$file"; then
            changed+=("$file")
            continue
        fi
        if [ "$code" = "??" ]; then continue; fi
        non_submodule+=("$file")
    done <<< "$status_lines"

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

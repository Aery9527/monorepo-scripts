#!/bin/bash
# lib/repo-context.sh — 消費端 repo root 與 remote 名稱解析
#
# 這兩件事都不可用「腳本位置的上一層」或字面 origin 硬推：那會把「掛載深度」與
# 「remote 命名」變成消費端必須配合的隱性契約，一旦不符只會得到看不出真因的錯誤
# （掛在 tools/monorepo-scripts 時推錯一層 → 只顯示「找不到 .gitmodules」）。

# 多支腳本使用 associative array / mapfile，需要 Bash 4.2 以上；提前檢查並給出清楚錯誤，
# 避免直接拋出難懂的語法或指令錯誤（例如 macOS 內建 bash 3.2）。
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERROR: monorepo-scripts 需要 Bash 4.2 以上版本（目前偵測到：${BASH_VERSION:-未知}）。" >&2
    echo "       macOS 內建 /bin/bash 常年停留在 3.2，請改用 Homebrew 安裝的較新版 bash。" >&2
    exit 1
fi

# 這些腳本使用 git branch --show-current（Git 2.22 起）等較新功能。太舊的 git 不會整支失敗，
# 而是讓個別指令回空值，導致分支清單靜默變空 —— 提前擋下比事後 debug 便宜。
# 嚴禁在此用 set -- 拆版本號：本檔被 source，會清掉呼叫端的位置參數（$1）。
_git_ver="$(git --version 2>/dev/null)"
_git_major="$(printf '%s' "$_git_ver" | sed -n 's/^git version \([0-9][0-9]*\)\..*/\1/p')"
_git_minor="$(printf '%s' "$_git_ver" | sed -n 's/^git version [0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')"
if [ -z "$_git_major" ] || [ -z "$_git_minor" ]; then
    echo "ERROR: 無法取得 git 版本，請確認 git 已安裝且在 PATH 中。" >&2
    exit 1
fi
if [ "$_git_major" -lt 2 ] || { [ "$_git_major" -eq 2 ] && [ "$_git_minor" -lt 22 ]; }; then
    echo "ERROR: monorepo-scripts 需要 Git 2.22 以上版本（目前偵測到：$_git_ver）。" >&2
    exit 1
fi
unset _git_ver _git_major _git_minor

# 解析消費端（superproject）repo root，與本工具集的掛載深度無關。
resolve_repo_root() {
    local script_dir="$1" raw root

    # A：本工具集是消費端的 submodule → superproject working tree 直接就是答案。
    raw="$(git -C "$script_dir" rev-parse --show-superproject-working-tree 2>/dev/null)" || raw=""
    if [ -n "$raw" ]; then
        root="$(cd "$raw" 2>/dev/null && pwd)" || root=""
        if [ -n "$root" ]; then
            echo "$root"
            return 0
        fi
    fi

    # B：本工具集只是消費端 repo 內的一般目錄（非 submodule）→ toplevel 即消費端 root。
    #    先正規化再比較：git 回傳 C:/... 而 pwd 回傳 /c/...，不正規化會誤判成不相等。
    raw="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || raw=""
    if [ -n "$raw" ]; then
        root="$(cd "$raw" 2>/dev/null && pwd)" || root=""
        if [ -n "$root" ] && [ "$root" != "$script_dir" ]; then
            echo "$root"
            return 0
        fi
    fi

    # C：獨立 clone（開發本工具集本身，或未註冊成 submodule）→ 退回上一層。
    (cd "$script_dir/.." && pwd)
}

# 列出 .gitmodules 中所有 submodule 的 path 值，一行一個；讀不到就輸出空內容。
#
# 嚴禁用 awk/cut 對 --get-regexp 的輸出按空格切 key 與 value。submodule 名稱預設等於
# 它的路徑，路徑含空白時「鍵」本身就含空白，該行沒有可靠的分隔點：
#     submodule.lib/my dep.path lib/my dep
#     cut -d' ' -f2-  →  "dep.path lib/my dep"（錯）
# 正解是先以 --name-only 取鍵，再逐一 --get 取值，完全不做字串切割。
#
# regex 必須錨定成 ^submodule\..*\.path$。未錨定的 "path" 會連鍵名以外的欄位一起命中：
# 名為 lib/pathutil 的 submodule 會讓 submodule.lib/pathutil.url 也被選出，於是 URL
# 被當成 submodule 路徑列舉。
list_submodule_paths() {
    local gitmodules_file="$1" cfg_key value
    while IFS= read -r cfg_key; do
        [ -n "$cfg_key" ] || continue
        value="$(git config --file "$gitmodules_file" --get "$cfg_key" 2>/dev/null)" || continue
        [ -n "$value" ] || continue
        printf '%s\n' "$value"
    done < <(git config --file "$gitmodules_file" --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null)
}

# 解析消費端指定的 remote 名稱；未設定時沿用 git 預設的 origin。
resolve_remote_name() {
    local repo_root="$1" cfg="$1/scripts/config/remote.txt" line name=""
    if [ -f "$cfg" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$line" ] && continue
            case "$line" in \#*) continue ;; esac
            name="$line"
            break
        done < "$cfg"
    fi
    [ -z "$name" ] && name="origin"

    # 名稱會被嵌進 ref 路徑與 sed/grep pattern，限制字元集避免注入與樣式誤判。
    case "$name" in
        *[!A-Za-z0-9._-]*)
            echo "ERROR: scripts/config/remote.txt 的 remote 名稱含不合法字元：$name" >&2
            return 1
            ;;
    esac
    echo "$name"
}

# 供 sed/grep 使用的 remote 名稱：字元集內唯一的 regex 元字元是 "."，轉義即可。
remote_name_regex() {
    printf '%s' "$1" | sed 's/\./\\./g'
}

# 計算 $2 相對於 $1 的路徑（以 / 分隔）；不在 root 之下時回非 0。
# 不可用字串前綴比對:MSYS 下同一實體目錄可能同時有 /tmp/... 與 /c/... 兩種字面形式,
# 前綴比對會把明明在 root 底下的目錄誤判成「不在 root 之下」。改以 -ef 逐層上溯比對實體身分。
path_relative_to_root() {
    local root="$1" cur="$2" rel="" base parent
    [ -d "$root" ] && [ -d "$cur" ] || return 1
    while :; do
        if [ "$cur" -ef "$root" ]; then
            echo "$rel"
            return 0
        fi
        parent="$(dirname "$cur")"
        [ "$parent" = "$cur" ] && return 1
        base="$(basename "$cur")"
        if [ -z "$rel" ]; then rel="$base"; else rel="$base/$rel"; fi
        cur="$parent"
    done
}

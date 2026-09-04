# lib/repo-context.ps1 — 消費端 repo root 與 remote 名稱解析
#
# 這兩件事都不可用「腳本位置的上一層」或字面 origin 硬推：那會把「掛載深度」與
# 「remote 命名」變成消費端必須配合的隱性契約，一旦不符只會得到看不出真因的錯誤
# （掛在 tools\monorepo-scripts 時推錯一層 → 只顯示「找不到 .gitmodules」）。

# 這些腳本使用 git branch --show-current（Git 2.22 起）等較新功能。太舊的 git 不會整支失敗，
# 而是讓個別指令回空值，導致分支清單靜默變空 —— 提前擋下比事後 debug 便宜。
# 必須寫成函式並由 Get-ConsumerRepoRoot 呼叫：dot-source 檔案頂層的 exit / throw
# 不保證能中止呼叫端腳本，函式內的 throw 才會確實往上傳遞。
function Assert-GitVersion {
    $raw = ''
    try { $raw = @(git --version 2>$null | Where-Object { $_ }) | Select-Object -First 1 } catch { $raw = '' }
    if ("$raw" -notmatch 'git version (\d+)\.(\d+)') {
        throw "無法取得 git 版本，請確認 git 已安裝且在 PATH 中。"
    }
    if ([int]$Matches[1] -lt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -lt 22)) {
        throw "monorepo-scripts 需要 Git 2.22 以上版本（目前偵測到：$raw）。"
    }
}

# 解析消費端（superproject）repo root，與本工具集的掛載深度無關。
function Get-ConsumerRepoRoot {
    param([Parameter(Mandatory)][string]$ScriptDir)

    Assert-GitVersion

    $scriptDirFull = (Resolve-Path -LiteralPath $ScriptDir).Path

    # PowerShell 5.1 下 $ErrorActionPreference='Stop' 會把 native command 的 stderr 提升為
    # terminating error，即使有 2>$null 也一樣，故一律以 try/catch 吸收。
    $firstLine = {
        param($raw)
        @($raw) | Where-Object { $_ -and ([string]$_).Trim() } |
            Select-Object -First 1 | ForEach-Object { ([string]$_).Trim() }
    }

    # A：本工具集是消費端的 submodule → superproject working tree 直接就是答案。
    try { $sp = git -C $scriptDirFull rev-parse --show-superproject-working-tree 2>$null } catch { $sp = $null }
    $sp = & $firstLine $sp
    if ($sp -and (Test-Path -LiteralPath $sp)) {
        return (Resolve-Path -LiteralPath $sp).Path
    }

    # B：本工具集只是消費端 repo 內的一般目錄（非 submodule）→ toplevel 即消費端 root。
    #    先正規化再比較：git 回傳 C:/... 而 $PSScriptRoot 是 C:\...，不正規化會誤判成不相等。
    try { $top = git -C $scriptDirFull rev-parse --show-toplevel 2>$null } catch { $top = $null }
    $top = & $firstLine $top
    if ($top -and (Test-Path -LiteralPath $top)) {
        $topFull = (Resolve-Path -LiteralPath $top).Path
        if ($topFull -ne $scriptDirFull) { return $topFull }
    }

    # C：獨立 clone（開發本工具集本身，或未註冊成 submodule）→ 退回上一層。
    return (Resolve-Path -LiteralPath (Join-Path $scriptDirFull "..")).Path
}

# 解析消費端指定的 remote 名稱；未設定時沿用 git 預設的 origin。
function Get-RemoteName {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $name = ""
    $cfg = Join-Path $RepoRoot "scripts\config\remote.txt"
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in Get-Content -LiteralPath $cfg -Encoding UTF8) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
            $name = $trimmed
            break
        }
    }
    if (-not $name) { $name = "origin" }

    # 名稱會被嵌進 ref 路徑與 regex，限制字元集避免注入與樣式誤判。
    if ($name -notmatch '^[A-Za-z0-9._-]+$') {
        throw "scripts/config/remote.txt 的 remote 名稱含不合法字元：$name"
    }
    return $name
}

# 計算 $Path 相對於 $Root 的路徑（以 / 分隔）；不在 root 之下時回 $null。
# 逐層上溯比對而非字串前綴比對，避免「root 是 Path 的字串前綴」這個假設出錯。
# 比較的是 FullName 正規化後的字串，不解析 reparse point：若 root 與 Path 分別經由
# subst 磁碟機或 junction 表示同一實體目錄，本函式會回傳 $null（呼叫端會 fail-closed 中止），
# 而非算出錯誤的相對路徑。Bash 版用 -ef 比對實體身分，涵蓋範圍較廣。
function Get-PathRelativeToRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd([char[]]@('\','/'))
    $cur      = (Get-Item -LiteralPath $Path).FullName.TrimEnd([char[]]@('\','/'))
    $parts    = New-Object System.Collections.ArrayList
    while ($true) {
        if ($cur -eq $rootFull) { return ($parts -join '/') }
        $parent = Split-Path -Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        [void]$parts.Insert(0, (Split-Path -Path $cur -Leaf))
        $cur = $parent
    }
}

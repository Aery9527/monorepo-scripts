function Get-FastpathSubmodules {
    param([Parameter(Mandatory)][string]$RepoRoot)

    # .gitmodules 缺路徑鍵位是合理失敗；呼叫端可能以 $ErrorActionPreference='Stop' 執行，
    # 須用 try/catch 吸收 PS 5.1 把 native command stderr 提升為 terminating error 的問題
    try { $lines = git config --file (Join-Path $RepoRoot ".gitmodules") --get-regexp path 2>$null } catch { $lines = $null }
    $result = @()
    foreach ($line in $lines) {
        # -split '\s+', 2 保留 key 之後的完整剩餘內容，避免路徑含空白時被截斷
        $parts = $line -split '\s+', 2
        if ($parts.Count -ge 2) { $result += $parts[1].Trim() }
    }
    return $result
}

function Get-GitStatusPorcelain {
    param([string]$RepoRoot)
    return @(git -C $RepoRoot status --porcelain 2>$null | Where-Object { $_ -ne '' })
}

function Get-FastpathChangedSubmodules {
    param([string[]]$StatusLines, [string[]]$Submodules)

    $allowed = [System.Collections.Generic.HashSet[string]]::new([string[]]$Submodules)
    $changed = @()
    $nonSubmodule = @()
    foreach ($line in $StatusLines) {
        $code = $line.Substring(0, 2)
        $file = $line.Substring(3).Trim()
        if ($file -match ' -> ') { $file = ($file -split ' -> ')[-1] }
        if ($allowed.Contains($file)) {
            if ($changed -notcontains $file) { $changed += $file }
            continue
        }
        if ($code -eq '??') { continue }
        $nonSubmodule += $file
    }
    return [PSCustomObject]@{ Changed = $changed; NonSubmodule = $nonSubmodule }
}

function Get-SubmoduleChangeInfo {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Name)

    $subPath = Join-Path $RepoRoot $Name
    # 路徑在 HEAD 找不到記錄（新增未提交的 submodule 等）是合理失敗；同上，須用 try/catch 吸收
    try { $lsTree = git -C $RepoRoot ls-tree HEAD -- $Name 2>$null } catch { $lsTree = $null }
    if (-not $lsTree) { throw "failed to read recorded SHA for $Name" }
    $oldSha = ($lsTree -split '\s+')[2]

    # submodule 尚未初始化或 HEAD unborn 時 rev-parse 合理失敗；同上，須用 try/catch 吸收
    try { $newSha = (git -C $subPath rev-parse HEAD 2>$null) } catch { $newSha = $null }
    if (-not $newSha) { throw "failed to read current HEAD for $Name" }

    # oldSha 在淺層 clone 或歷史重寫時可能已不存在，這是合理的失敗情境；
    # 呼叫端可能以 $ErrorActionPreference='Stop' 執行，須用 try/catch 吸收 PS 5.1 的 stderr 提升
    try { git -C $subPath cat-file -e $oldSha 2>$null } catch {}
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Name = $Name; OldSha = $oldSha; NewSha = $newSha; Ahead = -1; Behind = -1; Subject = "" }
    }

    # rev-list --count 失敗（物件損毀、缺 parent）不可默默當成 0；PS 5.1 在 $ErrorActionPreference='Stop'
    # 下會把 native stderr 提升為 terminating error，須用 try/catch 吸收後檢查 $LASTEXITCODE 與整數格式，fail closed
    try { $aheadRaw = git -C $subPath rev-list --count "$oldSha..$newSha" 2>$null } catch { $aheadRaw = $null }
    if ($LASTEXITCODE -ne 0 -or "$aheadRaw" -notmatch '^\d+$') { throw "failed to count commits ahead for $Name" }
    try { $behindRaw = git -C $subPath rev-list --count "$newSha..$oldSha" 2>$null } catch { $behindRaw = $null }
    if ($LASTEXITCODE -ne 0 -or "$behindRaw" -notmatch '^\d+$') { throw "failed to count commits behind for $Name" }
    $ahead = [int]$aheadRaw
    $behind = [int]$behindRaw
    $subject = ""
    if ($ahead -gt 0) {
        # 顯示用途，失敗僅影響訊息內容而非流程；同上，須用 try/catch 吸收避免非必要中止
        try { $subjects = @(git -C $subPath log --format=%s "$oldSha..$newSha" 2>$null) } catch { $subjects = @() }
        if ($subjects.Count -gt 0) { $subject = $subjects[0] }
    }
    return [PSCustomObject]@{ Name = $Name; OldSha = $oldSha; NewSha = $newSha; Ahead = $ahead; Behind = $behind; Subject = $subject }
}

function Test-RootFastpathEligible {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $submodules = Get-FastpathSubmodules -RepoRoot $RepoRoot
    if ($submodules.Count -eq 0) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "failed to enumerate submodules from .gitmodules"; Changes = @() }
    }

    $statusLines = Get-GitStatusPorcelain -RepoRoot $RepoRoot
    if ($statusLines.Count -eq 0) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "root has no changes"; Changes = @() }
    }

    $split = Get-FastpathChangedSubmodules -StatusLines $statusLines -Submodules $submodules
    if ($split.NonSubmodule.Count -gt 0) {
        $reason = "requires root-only submodule ref changes; non-submodule files changed: $($split.NonSubmodule -join ', ')"
        return [PSCustomObject]@{ Eligible = $false; Reason = $reason; Changes = @() }
    }
    if ($split.Changed.Count -eq 0) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "root has no changes"; Changes = @() }
    }

    try {
        $changes = @($split.Changed | ForEach-Object { Get-SubmoduleChangeInfo -RepoRoot $RepoRoot -Name $_ })
    } catch {
        return [PSCustomObject]@{ Eligible = $false; Reason = $_.Exception.Message; Changes = @() }
    }

    return [PSCustomObject]@{ Eligible = $true; Reason = ""; Changes = $changes }
}

function Format-FastpathChangeSpan {
    param([Parameter(Mandatory)]$Change)

    $oldShort = $Change.OldSha.Substring(0, 7)
    $newShort = $Change.NewSha.Substring(0, 7)
    if ($Change.Ahead -eq -1) { return "$oldShort -> $newShort (old ref unavailable)" }
    if ($Change.Ahead -gt 0 -and $Change.Behind -eq 0) {
        $unit = if ($Change.Ahead -eq 1) { "commit" } else { "commits" }
        return "$oldShort -> $newShort ($($Change.Ahead) $unit)"
    }
    if ($Change.Ahead -eq 0 -and $Change.Behind -gt 0) {
        $unit = if ($Change.Behind -eq 1) { "commit" } else { "commits" }
        return "$oldShort -> $newShort (rewind $($Change.Behind) $unit)"
    }
    if ($Change.Ahead -eq 0 -and $Change.Behind -eq 0) { return "$oldShort -> $newShort (no history change)" }
    return "$oldShort -> $newShort (history rewritten)"
}

function Build-RootFastpathCommitMessage {
    param([Parameter(Mandatory)][object[]]$Changes)

    $names = $Changes | ForEach-Object { $_.Name }
    $suffix = if ($names.Count -eq 1) { "submodule ref" } else { "submodule refs" }
    $subject = "chore(root): 同步 $($names -join '、') $suffix"

    $bodyLines = @()
    foreach ($change in $Changes) {
        $bodyLines += "- $($change.Name): $(Format-FastpathChangeSpan -Change $change)"
        if ($change.Subject) { $bodyLines += "  最新: $($change.Subject)" }
    }
    return (@($subject, "") + $bodyLines) -join "`n"
}

function Invoke-RootFastpathCommit {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object[]]$Changes,
        [Parameter(Mandatory)][string]$Message
    )

    $names = @($Changes | ForEach-Object { $_.Name })
    git -C $RepoRoot add -- @names
    if ($LASTEXITCODE -ne 0) { throw "git add failed" }

    $Message | git -C $RepoRoot commit -F -
    if ($LASTEXITCODE -ne 0) { throw "git commit failed with exit code $LASTEXITCODE" }
}

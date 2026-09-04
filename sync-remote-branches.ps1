. (Join-Path $PSScriptRoot "lib\repo-aliases.ps1")

$originalLocation = Get-Location
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
$RepoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
$Remote   = Get-RemoteName -RepoRoot $RepoRoot
Set-Location $RepoRoot
try {

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding          = [System.Text.Encoding]::UTF8

# ===========================================
# Git Remote Branch Sync Auditor
# 清點所有 repo（root + submodules）的 remote branch 同步狀態
# 找出哪些 branch 在某些 repo 的 remote 缺失，並提供 push 補齊功能
#
# 用法:
#   .\monorepo-scripts\sync-remote-branches.ps1
# ===========================================

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Remote Branch Sync Auditor" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Collect submodule paths from .gitmodules
# .gitmodules 缺路徑鍵位是合理失敗；PowerShell 5.1 下 $ErrorActionPreference='Stop' 會把
# native command 的 stderr 提升為 terminating error，即使有 2>$null 也一樣，須用 try/catch 吸收
try { $rawPaths = git config --file .gitmodules --get-regexp path 2>$null } catch { $rawPaths = $null }
$gitConfigExit = $LASTEXITCODE
if ($gitConfigExit -ne 0 -or -not $rawPaths) {
    Write-Host "ERROR: No submodules found or .gitmodules not readable" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
    exit 1
}

$submodules = @()
foreach ($line in ($rawPaths -split "`n")) {
    $line = $line.Trim()
    if ($line -eq '') { continue }
    $parts = $line -split '\s+', 2
    if ($parts.Count -ge 2) { $submodules += $parts[1].Trim() }
}

if ($submodules.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    exit 1
}

$ROOT = (Get-Location).Path

# Build ordered repo list: root first, then submodules
$repos = @(@{ Name = "root"; Path = $ROOT }) + @(
    $submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $ROOT $_) } }
)

# Display repos and current branches
Write-Host "Found $($repos.Count) repositories:" -ForegroundColor Blue
foreach ($repo in $repos) {
    $branch = git -C $repo.Path branch --show-current 2>$null
    Write-Host "  - $($repo.Name) ($branch)" -ForegroundColor Cyan
}
Write-Host ""

# -----------------------------------------------------------------------
# Mode selection: fetch first or audit only
# -----------------------------------------------------------------------
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇操作模式：" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] 僅清點（使用快取的遠端資訊，不連網）" -ForegroundColor Green
Write-Host "  [2] 先 fetch（建議 — 確保遠端資訊是最新的）" -ForegroundColor Green
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

while ($true) {
    $modeChoice = (Read-Host "請輸入選擇 (1-2/c)").Trim()
    if ($modeChoice -ieq 'c') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    } elseif ($modeChoice -eq '1') {
        Write-Host "[OK] Using cached remote info" -ForegroundColor Green
        Write-Host ""
        break
    } elseif ($modeChoice -eq '2') {
        Write-Host "[OK] Fetching all remotes (--prune)..." -ForegroundColor Green
        Write-Host ""
        foreach ($repo in $repos) {
            Write-Host "  Fetching $($repo.Name)..." -ForegroundColor Cyan
            # fetch 可能因網路或 remote 問題合理失敗；PowerShell 5.1 下 $ErrorActionPreference='Stop'
            # 會把 native command 的 stderr 提升為 terminating error，即使有 2>$null 也一樣，須用 try/catch 吸收
            try { git -C $repo.Path fetch --all --prune --quiet 2>$null } catch {}
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [!] WARNING: Fetch had errors for $($repo.Name)" -ForegroundColor Yellow
            }
        }
        Write-Host "[OK] Fetch completed" -ForegroundColor Green
        Write-Host ""
        break
    } else {
        Write-Host "無效選擇，請輸入 1、2 或 c" -ForegroundColor Red
    }
}

# -----------------------------------------------------------------------
# Collect branch status for each repo
# $branchData[$branchName][$repoName] = @{ Local = $bool; Remote = $bool }
# -----------------------------------------------------------------------
Write-Host "Auditing branch status across all repositories..." -ForegroundColor Blue

$branchData = @{}

foreach ($repo in $repos) {
    # Local branches
    $localBranches = @(
        git -C $repo.Path branch --format='%(refname:short)' 2>$null |
        Where-Object { $_ -ne '' }
    )

    # Remote branches：只列舉設定的 remote。git branch -r 會混入其他 remote，
    # 讓 other/xxx 被當成分支名列進清點結果。
    $remoteBranches = @(
        git -C $repo.Path for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null |
        Where-Object { $_ -ne 'HEAD' -and $_ -ne '' } |
        Sort-Object -Unique
    )

    foreach ($b in $localBranches) {
        if (-not $branchData.ContainsKey($b))              { $branchData[$b] = @{} }
        if (-not $branchData[$b].ContainsKey($repo.Name)) { $branchData[$b][$repo.Name] = @{ Local = $false; Remote = $false } }
        $branchData[$b][$repo.Name].Local = $true
    }

    foreach ($b in $remoteBranches) {
        if (-not $branchData.ContainsKey($b))              { $branchData[$b] = @{} }
        if (-not $branchData[$b].ContainsKey($repo.Name)) { $branchData[$b][$repo.Name] = @{ Local = $false; Remote = $false } }
        $branchData[$b][$repo.Name].Remote = $true
    }
}

$allBranches = @($branchData.Keys | Sort-Object)

if ($allBranches.Count -eq 0) {
    Write-Host "[!] No branches found across any repository." -ForegroundColor Yellow
    exit 0
}

Write-Host "[OK] Found $($allBranches.Count) unique branches total" -ForegroundColor Green
Write-Host ""

# -----------------------------------------------------------------------
# Build audit table
# Columns: repo names (abbreviated)
# Symbols: ✓ = local+remote   L = local-only   R = remote-only   - = missing
# Row colour: Green = fully synced, Yellow = has any issue
# -----------------------------------------------------------------------
$aliasMap = Get-RepoAliasMap -RepoRoot $RepoRoot
$repoShortNames = @{}
foreach ($repo in $repos) {
    $repoShortNames[$repo.Name] = Get-RepoShortName -RepoName $repo.Name -AliasMap $aliasMap
}

$maxBranchLen   = ($allBranches | Measure-Object -Property Length -Maximum).Maximum
$branchColWidth = [Math]::Max(24, $maxBranchLen + 2)
$maxShortLen  = ($repoShortNames.Values | Measure-Object Length -Maximum).Maximum
$repoColWidth = [Math]::Max($maxShortLen + 2, 6)

Write-Host "==========================================" -ForegroundColor Blue
Write-Host "   Branch Audit Report" -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""
Write-Host "  L=local-only  R=remote-only  v=both(OK)  -=missing" -ForegroundColor DarkGray
Write-Host ""

# Header row
$headerLine = "  " + "Branch".PadRight($branchColWidth)
foreach ($repo in $repos) {
    $headerLine += $repoShortNames[$repo.Name].PadLeft($repoColWidth)
}
Write-Host $headerLine -ForegroundColor Blue
Write-Host ("  " + "-" * ($branchColWidth + $repos.Count * $repoColWidth)) -ForegroundColor DarkGray

$missingRemoteEntries = @()
$missingBothEntries   = @()

foreach ($b in $allBranches) {
    $line        = "  " + $b.PadRight($branchColWidth)
    $rowHasIssue = $false

    foreach ($repo in $repos) {
        $status = $branchData[$b][$repo.Name]

        if ($null -eq $status -or (-not $status.Local -and -not $status.Remote)) {
            $cell            = "-".PadLeft($repoColWidth)
            $missingBothEntries  += @{ Branch = $b; RepoName = $repo.Name; RepoPath = $repo.Path }
            $rowHasIssue     = $true
        } elseif ($status.Local -and $status.Remote) {
            $cell = "v".PadLeft($repoColWidth)    # ASCII-safe checkmark
        } elseif ($status.Local -and -not $status.Remote) {
            $cell            = "L".PadLeft($repoColWidth)
            $missingRemoteEntries += @{ Branch = $b; RepoName = $repo.Name; RepoPath = $repo.Path }
            $rowHasIssue     = $true
        } else {
            # Remote-only: exists on remote but no local copy in this repo
            $cell = "R".PadLeft($repoColWidth)
        }

        $line += $cell
    }

    if ($rowHasIssue) {
        Write-Host $line -ForegroundColor Yellow
    } else {
        Write-Host $line -ForegroundColor Green
    }
}

Write-Host ""

# -----------------------------------------------------------------------
# Issues summary
# -----------------------------------------------------------------------
$totalMissingRemote = $missingRemoteEntries.Count
$totalMissingBoth   = $missingBothEntries.Count

if ($totalMissingRemote -eq 0 -and $totalMissingBoth -eq 0) {
    Write-Host "[OK] All branches are fully synced across all repositories!" -ForegroundColor Green
    Write-Host "     Every local branch has a corresponding remote tracking branch." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "   Issues Found" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

if ($totalMissingBoth -gt 0) {
    Write-Host "--- Missing entirely in some repos (no local, no remote): $totalMissingBoth ---" -ForegroundColor Yellow
    foreach ($entry in $missingBothEntries) {
        Write-Host "  [!] '$($entry.Branch)' not present (local or remote) in '$($entry.RepoName)'" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Cannot auto-push — branch doesn't exist locally in affected repos." -ForegroundColor DarkGray
    Write-Host "  Fix: run switch-branch.ps1 to create the branch across all repos first." -ForegroundColor DarkGray
    Write-Host ""
}

if ($totalMissingRemote -gt 0) {
    Write-Host "--- Local-only branches (need push to remote): $totalMissingRemote ---" -ForegroundColor Yellow
    foreach ($entry in $missingRemoteEntries) {
        Write-Host "  [!] '$($entry.Branch)' in '$($entry.RepoName)' — local only, not pushed" -ForegroundColor Yellow
    }
    Write-Host ""

    # -----------------------------------------------------------------------
    # Ask to push
    # -----------------------------------------------------------------------
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "是否推送缺失的遠端分支？" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 一次推送全部 $totalMissingRemote 筆" -ForegroundColor Green
    Write-Host "  [2] 逐筆確認後選擇性推送" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [c] 取消（保留清點報告，跳過推送）" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan

    $pushChoice = ""
    while ($true) {
        $pushChoice = (Read-Host "請輸入選擇 (1-2/c)").Trim().ToLower()
        if ($pushChoice -eq 'c') {
            Write-Host "[!] No branches were pushed. Remote branches remain out of sync." -ForegroundColor Yellow
            exit 0
        } elseif ($pushChoice -eq '1' -or $pushChoice -eq '2') {
            break
        }
        Write-Host "無效選擇。" -ForegroundColor Red
    }

    $entriesToPush = @()

    if ($pushChoice -eq '1') {
        $entriesToPush = $missingRemoteEntries
    } else {
        Write-Host ""
        Write-Host "逐筆確認，按 y 推送，其他鍵跳過：" -ForegroundColor Blue
        Write-Host ""
        foreach ($entry in $missingRemoteEntries) {
            $answer = (Read-Host "  推送 '$($entry.Branch)' 至 '$($entry.RepoName)' 遠端？(y/N)").Trim()
            if ($answer -match '^[Yy]$') { $entriesToPush += $entry }
        }
    }

    if ($entriesToPush.Count -eq 0) {
        Write-Host "[!] Nothing selected to push." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host "   Pushing $($entriesToPush.Count) branch(es)..." -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ""

    $successCount = 0
    $failCount    = 0
    $failedList   = @()

    foreach ($entry in $entriesToPush) {
        Write-Host "  Pushing '$($entry.Branch)' in '$($entry.RepoName)'..." -ForegroundColor Blue
        try {
            git -C $entry.RepoPath push -u $Remote $entry.Branch 2>&1 | Out-Null
        } catch {}
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Pushed successfully" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "  [X] ERROR: Push failed" -ForegroundColor Red
            $failCount++
            $failedList += "$($entry.RepoName)/$($entry.Branch)"
        }
    }

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Push Summary" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed:     $failCount"     -ForegroundColor Red

    if ($failedList.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed pushes:" -ForegroundColor Red
        foreach ($f in $failedList) { Write-Host "  $f" -ForegroundColor Red }
        exit 1
    }

    Write-Host ""
    Write-Host "[OK] All selected branches pushed to remote!" -ForegroundColor Green
}

Write-Host ""
exit 0
} finally {
    Set-Location $originalLocation
}

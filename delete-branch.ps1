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

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Submodule Branch Delete" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Collect submodule paths
# .gitmodules 缺路徑鍵位是合理失敗；PowerShell 5.1 下 $ErrorActionPreference='Stop' 會把
# native command 的 stderr 提升為 terminating error，即使有 2>$null 也一樣，須用 try/catch 吸收
try { $rawPaths = git config --file .gitmodules --get-regexp path 2>$null } catch { $rawPaths = $null }
if ($LASTEXITCODE -ne 0 -or -not $rawPaths) {
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
    Write-Host "ERROR: No submodules found" -ForegroundColor Red
    exit 1
}

$ROOT = (Get-Location).Path
$repos = @(@{ Name = "root"; Path = $ROOT }) + @(
    $submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $ROOT $_) } }
)

Write-Host "Found $($repos.Count) repositories:" -ForegroundColor Blue
foreach ($repo in $repos) {
    $branch = git -C $repo.Path branch --show-current 2>$null
    Write-Host "  - $($repo.Name) ($branch)" -ForegroundColor Cyan
}
Write-Host ""

$protectedBranches = @('main', 'master', 'develop')
$currentBranch     = git -C $ROOT branch --show-current 2>$null

# 快速清除模式：字面上的「只留目前分支」——不比照下方互動式多選對 main/master/develop 的保護。
# 唯一的安全網是逐分支確認「已完整推送」才刪，且要求所有 repo 先在同一分支才能執行，
# 避免各 submodule 目前所在分支不同時，誤判、砍到其他 repo 正在使用的分支。
function Invoke-QuickClean {
    Write-Host ""
    Write-Host "[快速清除模式] 檢查所有 repo 是否位於同一分支..." -ForegroundColor Blue

    # root 若為 detached HEAD，$currentBranch 是空字串；每個 submodule 若也 detached，
    # git branch --show-current 同樣回空字串，會讓下面逐一比對全部相等而誤判為「一致」，
    # 進而把所有本地具名分支都當成候選——必須在比對前先擋掉這個情況。
    if ([string]::IsNullOrEmpty($currentBranch)) {
        Write-Host "[X] root 目前為 detached HEAD，無法判斷「目前分支」，快速清除模式已中止。" -ForegroundColor Red
        return 1
    }

    $mismatch = $false
    foreach ($repo in $repos) {
        # 同上，須用 try/catch 吸收 PS 5.1 把 native command stderr 提升為 terminating error 的問題
        $b = $null
        try { $b = git -C $repo.Path branch --show-current 2>$null } catch { $b = $null }
        # 分支名稱要按字面（大小寫敏感）比對——PowerShell 的 -eq/-ne 預設不分大小寫，
        # 用 -ceq/-cne 才會跟 git 本身、跟 bash 版本的判斷一致。
        if ($b -cne $currentBranch) {
            $shown = if ($b) { $b } else { '<detached HEAD>' }
            Write-Host "  [X] $($repo.Name): 位於 '$shown'，與 root 的 '$currentBranch' 不一致" -ForegroundColor Red
            $mismatch = $true
        }
    }
    if ($mismatch) {
        Write-Host "[X] 各 repo 分支不一致，為避免砍錯分支，快速清除模式已中止。請先讓所有 repo 切到同一分支再重試。" -ForegroundColor Red
        return 1
    }
    Write-Host "[OK] 所有 repo 皆位於 '$currentBranch'" -ForegroundColor Green
    Write-Host ""

    # --prune 是必要的，不只是最佳實踐：若遠端已刪除某分支但本地 remote-tracking ref
    # 未被清掉，下面的 rev-parse 仍會成功、ahead 仍可能算出 0，導致「已刪除的遠端分支」被
    # 誤判為「已推送」而砍掉本地僅存的副本。
    Write-Host "Fetching $Remote（強制執行，並 --prune 避免用到已過期的遠端分支快取）..." -ForegroundColor Blue
    $fetchOk = @{}
    foreach ($repo in $repos) {
        # 同上，須用 try/catch 吸收 PS 5.1 把 native command stderr 提升為 terminating error 的問題；
        # 順手把 stdout 也導向 $null，避免污染此函式的回傳值（return 是這裡唯一該送出的輸出）
        try { git -C $repo.Path fetch $Remote --prune --quiet 2>$null 1>$null } catch {}
        if ($LASTEXITCODE -eq 0) {
            $fetchOk[$repo.Name] = $true
        } else {
            $fetchOk[$repo.Name] = $false
            Write-Host "  [!] WARNING: Fetch had errors for $($repo.Name)，該 repo 的分支將一律標記為無法確認" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    $plan = @()
    foreach ($repo in $repos) {
        # 同上，須用 try/catch 保護；捕獲到例外時視為列舉失敗，該 repo 整個略過並警示，
        # 不能讓失敗被吞掉、悄悄變成「這個 repo 沒有候選分支」。
        $localBranches = $null
        try {
            $localBranches = @(git -C $repo.Path branch --format='%(refname:short)' 2>$null | Where-Object { $_ -ne '' })
        } catch {
            $localBranches = $null
        }
        if ($LASTEXITCODE -ne 0 -or $null -eq $localBranches) {
            Write-Host "  [!] WARNING: 無法列出 $($repo.Name) 的本地分支，已略過該 repo" -ForegroundColor Yellow
            continue
        }

        foreach ($b in $localBranches) {
            if ($b -ceq $currentBranch) { continue }

            if (-not $fetchOk[$repo.Name]) {
                $plan += [PSCustomObject]@{ Repo = $repo.Name; Path = $repo.Path; Branch = $b; Action = 'SKIP'; Reason = '該 repo fetch 失敗，無法確認推送狀態' }
                continue
            }

            # 用完整 ref 路徑（refs/remotes/<remote>/<b>、refs/heads/<b>）取代 <remote>/<b> 這種
            # 簡寫，避免 git 的 DWIM 解析在極端命名巧合下解析到非預期的 ref。
            try { git -C $repo.Path rev-parse --verify --quiet "refs/remotes/$Remote/$b" 2>$null 1>$null } catch {}
            if ($LASTEXITCODE -ne 0) {
                $plan += [PSCustomObject]@{ Repo = $repo.Name; Path = $repo.Path; Branch = $b; Action = 'SKIP'; Reason = '無對應遠端分支，視為未推送' }
                continue
            }

            $aheadRaw = $null
            try { $aheadRaw = git -C $repo.Path rev-list --count "refs/remotes/$Remote/$b..refs/heads/$b" 2>$null } catch { $aheadRaw = $null }
            if ($LASTEXITCODE -ne 0 -or "$aheadRaw" -notmatch '^\d+$') {
                $plan += [PSCustomObject]@{ Repo = $repo.Name; Path = $repo.Path; Branch = $b; Action = 'SKIP'; Reason = '無法確認推送狀態，為安全略過' }
            } elseif ([int]$aheadRaw -eq 0) {
                $plan += [PSCustomObject]@{ Repo = $repo.Name; Path = $repo.Path; Branch = $b; Action = 'DELETE'; Reason = '已完整推送' }
            } else {
                $plan += [PSCustomObject]@{ Repo = $repo.Name; Path = $repo.Path; Branch = $b; Action = 'SKIP'; Reason = "領先遠端 $aheadRaw 個 commit，尚未推送" }
            }
        }
    }

    if ($plan.Count -eq 0) {
        Write-Host "[!] 除了目前分支 '$currentBranch' 外，沒有其他本地分支。" -ForegroundColor Yellow
        return 0
    }

    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "   快速清除計畫（保留：$currentBranch）" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host ""
    foreach ($p in $plan) {
        if ($p.Action -eq 'DELETE') {
            Write-Host "  [刪除] $($p.Repo) / $($p.Branch) — $($p.Reason)" -ForegroundColor Green
        } else {
            Write-Host "  [略過] $($p.Repo) / $($p.Branch) — $($p.Reason)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    $delCount = @($plan | Where-Object { $_.Action -eq 'DELETE' }).Count
    Write-Host "將刪除 $delCount 個本地分支，略過 $($plan.Count - $delCount) 個（未推送或無法確認）" -ForegroundColor Cyan
    Write-Host ""

    if ($delCount -eq 0) {
        Write-Host "[!] 沒有可安全刪除的分支（全部尚未推送），未執行任何刪除。" -ForegroundColor Yellow
        return 0
    }

    Write-Host "[!!!] WARNING: 此操作無法復原！" -ForegroundColor Red
    $confirm = (Read-Host "確認要刪除以上「已推送」的本地分支？(y/N)").Trim()
    if ($confirm -ine 'y') { Write-Host "取消操作。" -ForegroundColor Yellow; return 0 }
    Write-Host ""

    $successCount = 0
    $failCount = 0
    foreach ($p in ($plan | Where-Object { $_.Action -eq 'DELETE' })) {
        try { git -C $p.Path branch -D $p.Branch 2>$null 1>$null } catch {}
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] $($p.Repo) / $($p.Branch) — 已刪除" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "  [X] $($p.Repo) / $($p.Branch) — 刪除失敗" -ForegroundColor Red
            $failCount++
        }
    }

    Write-Host ""
    Write-Host "Summary: 成功 $successCount，失敗 $failCount" -ForegroundColor Cyan
    if ($failCount -gt 0) { return 1 }
    return 0
}

# 選擇工作流程
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇工作流程：" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] 互動式多選（清點所有 repo 後勾選要刪除的分支，可含遠端）" -ForegroundColor Green
Write-Host "  [2] 快速清除（保留目前分支，砍光其餘本地分支；自動略過尚未推送的分支）" -ForegroundColor Green
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

while ($true) {
    $flowChoice = (Read-Host "請輸入選擇 (1-2/c)").Trim()
    if ($flowChoice -ieq 'c') { Write-Host "取消操作。" -ForegroundColor Yellow; exit 0 }
    elseif ($flowChoice -eq '1') { break }
    elseif ($flowChoice -eq '2') { exit (Invoke-QuickClean) }
    else { Write-Host "無效選擇，請輸入 1、2 或 c" -ForegroundColor Red }
}

# Mode selection（互動式多選流程：選擇遠端資訊來源）
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇操作模式：" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] 僅使用快取的遠端資訊（不連網）" -ForegroundColor Green
Write-Host "  [2] 先 fetch（建議 — 確保遠端資訊是最新的）" -ForegroundColor Green
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

while ($true) {
    $modeChoice = (Read-Host "請輸入選擇 (1-2/c)").Trim()
    if ($modeChoice -ieq 'c') { Write-Host "取消操作。" -ForegroundColor Yellow; exit 0 }
    elseif ($modeChoice -eq '1') {
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

# Collect branch data across all repos
Write-Host "Collecting branch data..." -ForegroundColor Blue

$branchData = @{}

foreach ($repo in $repos) {
    $localBranches = @(
        git -C $repo.Path branch --format='%(refname:short)' 2>$null |
        Where-Object { $_ -ne '' }
    )
    $remoteBranches = @(
        # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
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

# Filter out protected + current branches
$deletableBranches = @(
    $branchData.Keys | Sort-Object | Where-Object {
        $_ -ne $currentBranch -and $protectedBranches -notcontains $_
    }
)

if ($deletableBranches.Count -eq 0) {
    Write-Host "[!] No deletable branches found (all are protected or current)." -ForegroundColor Yellow
    exit 0
}

Write-Host "[OK] Found $($deletableBranches.Count) deletable branches" -ForegroundColor Green
Write-Host ""

# Short name lookup
$aliasMap = Get-RepoAliasMap -RepoRoot $RepoRoot
$repoShortNames = @{}
foreach ($repo in $repos) {
    $repoShortNames[$repo.Name] = Get-RepoShortName -RepoName $repo.Name -AliasMap $aliasMap
}

$maxShortLen    = ($repoShortNames.Values | Measure-Object Length -Maximum).Maximum
$repoColWidth   = [Math]::Max($maxShortLen + 2, 6)
$maxBranchLen   = ($deletableBranches | Measure-Object -Property Length -Maximum).Maximum
$branchColWidth = [Math]::Max(24, $maxBranchLen + 2)
$idxWidth       = $deletableBranches.Count.ToString().Length + 3   # "[N] "

# Display matrix table
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "   Branch Audit — 可刪除分支" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [!] 已排除：main, master, develop 及目前分支 ($currentBranch)" -ForegroundColor DarkGray
Write-Host "  L=僅本地  R=僅遠端  v=本地+遠端  -=不存在" -ForegroundColor DarkGray
Write-Host ""

$idxPad    = " " * $idxWidth
$headerLine = "  " + $idxPad + "Branch".PadRight($branchColWidth)
foreach ($repo in $repos) {
    $headerLine += $repoShortNames[$repo.Name].PadLeft($repoColWidth)
}
Write-Host $headerLine -ForegroundColor Blue
Write-Host ("  " + "-" * ($idxWidth + $branchColWidth + $repos.Count * $repoColWidth)) -ForegroundColor DarkGray

for ($i = 0; $i -lt $deletableBranches.Count; $i++) {
    $b      = $deletableBranches[$i]
    $idxStr = "[$($i+1)]".PadRight($idxWidth)
    $line   = "  " + $idxStr + $b.PadRight($branchColWidth)

    foreach ($repo in $repos) {
        $status = $branchData[$b][$repo.Name]
        if ($null -eq $status -or (-not $status.Local -and -not $status.Remote)) {
            $cell = "-".PadLeft($repoColWidth)
        } elseif ($status.Local -and $status.Remote) {
            $cell = "v".PadLeft($repoColWidth)
        } elseif ($status.Local) {
            $cell = "L".PadLeft($repoColWidth)
        } else {
            $cell = "R".PadLeft($repoColWidth)
        }
        $line += $cell
    }
    Write-Host $line -ForegroundColor Green
}

Write-Host ""

# Branch multi-selection
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇要刪除的分支（可多選）：" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  輸入編號，多個用逗號分隔（例：1,3,5）" -ForegroundColor DarkGray
Write-Host "  輸入 a 選取全部" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

$selectedBranches = @()
while ($true) {
    $rawInput = (Read-Host "請輸入選擇").Trim()
    if ($rawInput -ieq 'c') { Write-Host "取消操作。" -ForegroundColor Yellow; exit 0 }

    if ($rawInput -ieq 'a') {
        $selectedBranches = $deletableBranches
        break
    }

    $nums   = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $valid  = $true
    $picked = @()
    foreach ($n in $nums) {
        $num = 0
        if ([int]::TryParse($n, [ref]$num) -and $num -ge 1 -and $num -le $deletableBranches.Count) {
            $picked += $deletableBranches[$num - 1]
        } else {
            Write-Host "無效編號：$n（請輸入 1 到 $($deletableBranches.Count)）" -ForegroundColor Red
            $valid = $false
            break
        }
    }

    if ($valid -and $picked.Count -gt 0) {
        $selectedBranches = @($picked | Sort-Object -Unique)
        break
    }
    if ($valid -and $picked.Count -eq 0) {
        Write-Host "未選擇任何分支，請重新輸入。" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "已選擇 $($selectedBranches.Count) 個分支：" -ForegroundColor Blue
foreach ($b in $selectedBranches) { Write-Host "  - $b" -ForegroundColor Cyan }
Write-Host ""

# Delete scope
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇刪除範圍：" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] 僅刪除本地分支" -ForegroundColor Green
Write-Host "  [2] 僅刪除遠端分支" -ForegroundColor Green
Write-Host "  [3] 同時刪除本地與遠端分支" -ForegroundColor Green
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

$deleteLocal  = $false
$deleteRemote = $false
while ($true) {
    $opt = (Read-Host "請輸入選擇 (1-3/c)").Trim()
    if ($opt -ieq 'c') { Write-Host "取消操作。" -ForegroundColor Yellow; exit 0 }
    if ($opt -eq '1') { $deleteLocal = $true;  $deleteRemote = $false; break }
    if ($opt -eq '2') { $deleteLocal = $false; $deleteRemote = $true;  break }
    if ($opt -eq '3') { $deleteLocal = $true;  $deleteRemote = $true;  break }
    Write-Host "無效選擇，請輸入 1、2、3 或 c" -ForegroundColor Red
}

# Delete plan + confirm
Write-Host ""
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "   刪除計畫" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "  分支（$($selectedBranches.Count) 個）：$($selectedBranches -join ', ')" -ForegroundColor Cyan
Write-Host "  刪除本地：$(if ($deleteLocal)  { 'YES' } else { 'NO' })" -ForegroundColor Cyan
Write-Host "  刪除遠端：$(if ($deleteRemote) { 'YES' } else { 'NO' })" -ForegroundColor Cyan
Write-Host "  影響範圍：$($repos.Count) 個 repo（root + $($submodules.Count) submodules）" -ForegroundColor Yellow
Write-Host ""

# Per-repo-per-branch breakdown
Write-Host "--- 各 repo 執行明細 ---" -ForegroundColor Blue
Write-Host ""
$del_maxBranch = ($selectedBranches | Measure-Object Length -Maximum).Maximum
$del_maxRepo   = ($repos | ForEach-Object { $repoShortNames[$_.Name] } | Measure-Object Length -Maximum).Maximum
$del_bW = [Math]::Max(20, $del_maxBranch + 2)
$del_rW = [Math]::Max(8,  $del_maxRepo + 2)
$del_hdr = "  " + "分支".PadRight($del_bW) + "Repo".PadRight($del_rW) + "  本地" + "   遠端" + "  動作"
Write-Host $del_hdr -ForegroundColor Blue
Write-Host ("  " + "-" * ($del_bW + $del_rW + 28)) -ForegroundColor DarkGray

$del_hasLocalOnlyWithRemoteScope = $false
foreach ($b in $selectedBranches) {
    foreach ($repo in $repos) {
        $status    = $branchData[$b][$repo.Name]
        $hasLocal  = $status -and $status.Local
        $hasRemote = $status -and $status.Remote
        $short     = $repoShortNames[$repo.Name]

        $localAction  = if ($deleteLocal  -and $hasLocal)  { "刪除" } elseif ($deleteLocal  -and -not $hasLocal)  { "無/跳過" } else { "不變" }
        $remoteAction = if ($deleteRemote -and $hasRemote) { "刪除" } elseif ($deleteRemote -and -not $hasRemote) { "無/跳過" } else { "不變" }

        if ($deleteRemote -and -not $hasRemote -and $hasLocal) {
            $del_hasLocalOnlyWithRemoteScope = $true
        }

        $action = @()
        if ($deleteLocal  -and $hasLocal)  { $action += "刪本地" }
        if ($deleteRemote -and $hasRemote) { $action += "刪遠端" }
        if ($action.Count -eq 0)           { $action += "SKIP" }

        $actionStr = $action -join " + "
        $localStr  = if ($hasLocal)  { "[L]" } else { "[-]" }
        $remoteStr = if ($hasRemote) { "[R]" } else { "[-]" }

        $row = "  " + $b.PadRight($del_bW) + $short.PadRight($del_rW) + "  $localStr  $remoteStr  $actionStr"
        if ($actionStr -eq "SKIP") {
            Write-Host $row -ForegroundColor DarkGray
        } elseif ($deleteRemote -and -not $hasRemote -and $hasLocal) {
            Write-Host $row -ForegroundColor Yellow
        } else {
            Write-Host $row -ForegroundColor Green
        }
    }
}
Write-Host ""

if ($del_hasLocalOnlyWithRemoteScope) {
    Write-Host "[!] 警告：部分選定分支僅存在本地（L），沒有遠端副本。" -ForegroundColor Yellow
    Write-Host "    選擇「刪除遠端」對這些分支毫無影響，本地副本將保留。" -ForegroundColor Yellow
    Write-Host "    若要同時刪除本地副本，請取消後改選 [3] 同時刪除本地與遠端分支。" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "[!!!] WARNING: 此操作無法復原！" -ForegroundColor Red
$confirm = (Read-Host "確認要刪除這些分支？(y/N)").Trim()
if ($confirm -ine 'y') { Write-Host "取消操作。" -ForegroundColor Yellow; exit 0 }
Write-Host ""

# Execute
$successCount = 0
$failCount    = 0
$failedList   = @()

foreach ($repo in $repos) {
    foreach ($b in $selectedBranches) {
        $status    = $branchData[$b][$repo.Name]
        $hasLocal  = $status -and $status.Local
        $hasRemote = $status -and $status.Remote

        if ($deleteLocal) {
            if ($hasLocal) {
                # branch -D 可能因分支正被其他 worktree checkout 等原因合理失敗；同上，須用 try/catch 吸收
                try { git -C $repo.Path branch -D $b 2>$null } catch {}
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [OK] $($repo.Name) / $b — local deleted" -ForegroundColor Green
                } else {
                    Write-Host "  [!] $($repo.Name) / $b — local delete failed" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [-] $($repo.Name) / $b — no local, skipped" -ForegroundColor DarkGray
            }
        }

        if ($deleteRemote) {
            if ($hasRemote) {
                $gitOut = $null
                try {
                    $gitOut = git -C $repo.Path push $Remote --delete $b 2>&1
                } catch {}
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [OK] $($repo.Name) / $b — remote deleted" -ForegroundColor Green
                    $successCount++
                } elseif ("$gitOut" -match 'remote ref does not exist') {
                    # tracking ref 是舊快取，remote 實際已不存在，視為成功
                    Write-Host "  [OK] $($repo.Name) / $b — remote already gone (stale cache)" -ForegroundColor DarkGray
                    $successCount++
                } else {
                    Write-Host "  [X] $($repo.Name) / $b — remote delete failed" -ForegroundColor Red
                    if ($gitOut) { Write-Host "       $gitOut" -ForegroundColor DarkGray }
                    $failCount++
                    $failedList += "$($repo.Name)/$b (remote)"
                }
            } else {
                Write-Host "  [-] $($repo.Name) / $b — no remote, skipped" -ForegroundColor DarkGray
            }
        } elseif ($deleteLocal -and $hasLocal) {
            $successCount++
        }
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed:     $failCount"     -ForegroundColor Red

if ($failedList.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed:" -ForegroundColor Red
    foreach ($f in $failedList) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "[OK] Branch deletion completed!" -ForegroundColor Green
Write-Host ""
exit 0
} finally {
    Set-Location $originalLocation
}
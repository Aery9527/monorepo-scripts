param(
    [ValidateSet("pull", "fetch", "pull-all", "")][string]$Mode = ""
)
. (Join-Path $PSScriptRoot "lib\repo-aliases.ps1")
$originalLocation = Get-Location
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
$RepoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
$Remote   = Get-RemoteName -RepoRoot $RepoRoot
$RemoteRe = [regex]::Escape($Remote)
Set-Location $RepoRoot
try {

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Submodule Update Branch" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 取得所有「已初始化」的 submodule 路徑；解析與防護細節見 lib/repo-context.ps1。
$submodules = @(Get-InitializedSubmodulePaths -RepoRoot $RepoRoot)

if ($submodules.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
    exit 1
}

$ROOT = (Get-Location).Path

function Get-RepoCurrentBranch {
    param([string]$RepoPath)

    return [string](git -C $RepoPath branch --show-current 2>$null)
}

# 解決 `git fetch <remote> <branch>:<branch>` 在本地新建 branch 但不設 upstream 的痼疾。
# 當指定 Branch 在本地存在、無 upstream，且 <remote>/<Branch> 存在時，自動補上 tracking。
function Ensure-RepoUpstreamOnBranch {
    param([string]$RepoPath, [string]$Branch)

    if (-not $Branch) { return }

    git -C $RepoPath show-ref --verify --quiet "refs/heads/$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    $null = git -C $RepoPath rev-parse --abbrev-ref "$Branch@{upstream}" 2>$null
    if ($LASTEXITCODE -eq 0) { return }

    git -C $RepoPath show-ref --verify --quiet "refs/remotes/$Remote/$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    git -C $RepoPath branch --set-upstream-to="$Remote/$Branch" $Branch --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] upstream 自動補上 -> $Remote/$Branch" -ForegroundColor Green
    }
}

function Test-RepoLocalBranchExists {
    param([string]$RepoPath, [string]$Branch)

    if (-not $Branch) { return $false }
    git -C $RepoPath show-ref --verify --quiet "refs/heads/$Branch" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-RepoRemoteBranchExists {
    param([string]$RepoPath, [string]$Branch)

    if (-not $Branch) { return $false }
    git -C $RepoPath show-ref --verify --quiet "refs/remotes/$Remote/$Branch" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-RepoHeadBranchCandidates {
    param([string]$RepoPath, [string]$RefRoot)

    $branches = @(
        git -C $RepoPath for-each-ref --format='%(refname:short)' --points-at HEAD $RefRoot 2>$null |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' }
    )

    if ($RefRoot -eq "refs/remotes/$Remote") {
        return @(
            $branches |
            Where-Object { $_ -ne $Remote -and $_ -ne "$Remote/HEAD" } |
            ForEach-Object { $_ -replace "^$RemoteRe/", "" } |
            Where-Object { $_ -ne '' }
        )
    }

    return $branches
}

function Resolve-GitmodulesSectionByPath {
    # .gitmodules 的 [submodule "NAME"] 之 NAME 未必等於 path，需先反查對應的 section name
    # 才能查詢 submodule.<NAME>.branch。
    param([string]$GitmodulesFile, [string]$TargetPath)

    # 與 Get-SubmodulePaths 同樣的兩步取法：先取鍵再逐一取值，不對 key/value 做字串切割。
    # 路徑含空白時鍵本身就含空白（submodule.lib/my dep.path），按空白切會同時切壞兩邊。
    try {
        $cfgKeys = @(git config --file $GitmodulesFile --name-only --get-regexp '^submodule\..*\.path$' 2>$null)
    } catch {
        return ''
    }
    if ($LASTEXITCODE -ne 0) { return '' }

    foreach ($cfgKey in $cfgKeys) {
        if ([string]::IsNullOrWhiteSpace($cfgKey)) { continue }
        try { $val = git config --file $GitmodulesFile --get $cfgKey 2>$null } catch { continue }
        if ($LASTEXITCODE -ne 0) { continue }
        if (([string]$val).Trim() -eq $TargetPath) {
            return ($cfgKey -replace '^submodule\.', '' -replace '\.path$', '')
        }
    }
    return ''
}

function Get-PreferredRepoBranch {
    param([string]$RepoName, [string]$RepoPath, [string]$RootBranch)

    $currentBranch = Get-RepoCurrentBranch -RepoPath $RepoPath
    if ($currentBranch) { return $currentBranch }

    if ($RepoName -ne 'root') {
        # .gitmodules 一律位於 repo 根目錄（$ROOT），與 submodule 巢狀深度無關。
        $gitmodulesFile = Join-Path $ROOT ".gitmodules"
        $section = Resolve-GitmodulesSectionByPath -GitmodulesFile $gitmodulesFile -TargetPath $RepoName
        $configuredBranch = ''
        if ($section) {
            $configuredBranch = [string](git config --file $gitmodulesFile --get "submodule.$section.branch" 2>$null)
        }
        if ($configuredBranch) {
            if ($configuredBranch -eq '.') {
                if ($RootBranch -and ((Test-RepoLocalBranchExists -RepoPath $RepoPath -Branch $RootBranch) -or
                                      (Test-RepoRemoteBranchExists -RepoPath $RepoPath -Branch $RootBranch))) {
                    return $RootBranch
                }
            } elseif ((Test-RepoLocalBranchExists -RepoPath $RepoPath -Branch $configuredBranch) -or
                      (Test-RepoRemoteBranchExists -RepoPath $RepoPath -Branch $configuredBranch)) {
                return $configuredBranch
            }
        }
    }

    $localBranches = @(Get-RepoHeadBranchCandidates -RepoPath $RepoPath -RefRoot 'refs/heads')
    if ($localBranches.Count -eq 1) { return $localBranches[0] }

    $remoteBranches = @(Get-RepoHeadBranchCandidates -RepoPath $RepoPath -RefRoot "refs/remotes/$Remote")
    if ($remoteBranches.Count -eq 1) { return $remoteBranches[0] }

    return ''
}

function Get-RepoBranchDisplay {
    param([string]$RepoName, [string]$RepoPath, [string]$RootBranch)

    $currentBranch = Get-RepoCurrentBranch -RepoPath $RepoPath
    if ($currentBranch) { return $currentBranch }

    $preferredBranch = Get-PreferredRepoBranch -RepoName $RepoName -RepoPath $RepoPath -RootBranch $RootBranch
    if ($preferredBranch) { return "(detached -> $preferredBranch)" }

    return "(detached)"
}

function Ensure-RepoAttachedToBranch {
    param([string]$RepoName, [string]$RepoPath, [string]$RootBranch)

    $currentBranch = Get-RepoCurrentBranch -RepoPath $RepoPath
    if ($currentBranch) {
        return [PSCustomObject]@{
            Success      = $true
            Branch       = $currentBranch
            AutoAttached = $false
            Message      = ""
        }
    }

    $targetBranch = Get-PreferredRepoBranch -RepoName $RepoName -RepoPath $RepoPath -RootBranch $RootBranch
    if (-not $targetBranch) {
        return [PSCustomObject]@{
            Success      = $false
            Branch       = ""
            AutoAttached = $false
            Message      = "detached HEAD，且無法自動判斷要切回哪個 branch"
        }
    }

    if (Test-RepoLocalBranchExists -RepoPath $RepoPath -Branch $targetBranch) {
        git -C $RepoPath checkout $targetBranch --quiet 2>$null
    } elseif (Test-RepoRemoteBranchExists -RepoPath $RepoPath -Branch $targetBranch) {
        git -C $RepoPath checkout -b $targetBranch "$Remote/$targetBranch" --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            git -C $RepoPath checkout $targetBranch --quiet 2>$null
        }
    } else {
        return [PSCustomObject]@{
            Success      = $false
            Branch       = $targetBranch
            AutoAttached = $false
            Message      = "detached HEAD，但找不到可切換的 branch '$targetBranch'"
        }
    }

    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{
            Success      = $false
            Branch       = $targetBranch
            AutoAttached = $false
            Message      = "detached HEAD，切換到 branch '$targetBranch' 失敗"
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        Branch       = $targetBranch
        AutoAttached = $true
        Message      = ""
    }
}

$rootBranch = Get-RepoCurrentBranch -RepoPath $ROOT
if ($rootBranch) {
    $rootResolvedBranch = $rootBranch
} else {
    $rootResolvedBranch = Get-PreferredRepoBranch -RepoName 'root' -RepoPath $ROOT -RootBranch ''
}

# Print submodules with their current branches
Write-Host "Found submodules:" -ForegroundColor Blue
$rootDisplay = Get-RepoBranchDisplay -RepoName 'root' -RepoPath $ROOT -RootBranch $rootResolvedBranch
Write-Host "  - root ($rootDisplay)" -ForegroundColor Cyan
foreach ($sub in $submodules) {
    $subPath = Join-Path $ROOT $sub
    $subBranch = Get-RepoBranchDisplay -RepoName $sub -RepoPath $subPath -RootBranch $rootResolvedBranch
    Write-Host "  - $sub ($subBranch)" -ForegroundColor Cyan
}
Write-Host ""

# -----------------------------------------------------------------------
# Branch Status Table
# -----------------------------------------------------------------------
$ub_aliasMap = Get-RepoAliasMap -RepoRoot $RepoRoot
$ub_root  = $ROOT
$ub_repos = @(@{ Name = "root"; Path = $ub_root }) + @(
    $submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $ub_root $_) } }
)

$ub_nameW   = 8
$ub_branchW = 14
$ub_aheadW  = 7
$ub_rows = @()
foreach ($r in $ub_repos) {
    $short    = Get-RepoShortName -RepoName $r.Name -AliasMap $ub_aliasMap
    $currentBranch   = Get-RepoCurrentBranch -RepoPath $r.Path
    $preferredBranch = ""
    if ($currentBranch) {
        $branch = $currentBranch
    } else {
        $preferredBranch = Get-PreferredRepoBranch -RepoName $r.Name -RepoPath $r.Path -RootBranch $rootResolvedBranch
        if ($preferredBranch) { $branch = "(detached -> $preferredBranch)" }
        else { $branch = "(detached)" }
    }

    if (-not $currentBranch) {
        $ahead  = "--"
        $upName = "(detached)"
        if ($preferredBranch) {
            $hint = "detached HEAD — pull 時會先切回 $preferredBranch"
        } else {
            $hint = "detached HEAD — 無法自動判斷 branch"
        }
    } else {
        $upstream = git -C $r.Path rev-parse --abbrev-ref '@{upstream}' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $upstream) {
            $ahead  = "--"
            $upName = "(無 upstream)"
            $hint   = "無 upstream — 建議使用 push -u"
        } else {
            $aheadN = git -C $r.Path rev-list '@{upstream}..HEAD' --count 2>$null
            $ahead  = if ($aheadN -match '^\d+$') { "+$aheadN" } else { "--" }
            $upName = $upstream
            $hint   = if ($aheadN -eq "0") { "(已同步)" } else { "需要 push" }
        }
    }
    $ub_nameW   = [Math]::Max($ub_nameW, $short.Length + 2)
    $ub_branchW = [Math]::Max($ub_branchW, $branch.Length + 2)
    $ub_rows   += @{ Short = $short; Branch = $branch; Ahead = $ahead; Upstream = $upName; Hint = $hint }
}

Write-Host "==========================================" -ForegroundColor Blue
Write-Host "   Branch 狀態 — 各 repo 目前分支" -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""
Write-Host "  +N=本地領先  --=無 upstream  (behind 資訊需 fetch 後才準確)" -ForegroundColor DarkGray
Write-Host ""
$ub_hdr = "  " + "名稱".PadRight($ub_nameW) + "Branch".PadRight($ub_branchW) + "Ahead".PadLeft($ub_aheadW) + "  Upstream"
Write-Host $ub_hdr -ForegroundColor Blue
Write-Host ("  " + "-" * ($ub_nameW + $ub_branchW + $ub_aheadW + 12)) -ForegroundColor DarkGray
foreach ($row in $ub_rows) {
    $line  = "  " + $row.Short.PadRight($ub_nameW) + $row.Branch.PadRight($ub_branchW) + $row.Ahead.PadLeft($ub_aheadW) + "  $($row.Upstream)"
    if ($row.Hint -like "無 upstream*" -or $row.Hint -like "detached HEAD*") { Write-Host $line -ForegroundColor Yellow }
    elseif ($row.Hint -eq "(已同步)") { Write-Host $line -ForegroundColor Green }
    else { Write-Host $line -ForegroundColor Cyan }
}
Write-Host ""

$operation = ""
$opDesc = ""
$gitArgs = @()
$needBranch = $false

if ($Mode) {
    switch ($Mode) {
        "pull"     { $operation = "pull";     $opDesc = "Pulling";       $gitArgs = @("pull") }
        "fetch"    { $operation = "fetch";    $opDesc = "Fetching";      $gitArgs = @("fetch", "--all") }
        "pull-all" { $operation = "pull-all"; $opDesc = "Pull 所有分支" }
    }
} else {
    # Operation menu
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "選擇操作：" -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Fetch — 更新遠端追蹤分支 (git fetch --all)" -ForegroundColor Green
    Write-Host "  [2] Fetch 指定分支" -ForegroundColor Green
    Write-Host "  [3] Pull — 取得並合併當前分支的遠端變更 (git pull)" -ForegroundColor Green
    Write-Host "  [4] 將指定分支同步到本地 (git fetch $Remote branch:branch)" -ForegroundColor Green
    Write-Host "  [5] Pull 所有分支 — 更新所有有 upstream 的本地分支" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [c] 取消" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan

    $validOps = @("c", "1", "2", "3", "4", "5")
    $choice = ""
    while ($choice -notin $validOps) {
        $choice = (Read-Host "請輸入選擇 (1-5/c)").Trim().ToLower()
        if ($choice -notin $validOps) {
            Write-Host "無效選擇，請輸入 1-5 或 c" -ForegroundColor Yellow
        }
    }

    if ($choice -eq "c") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }

    switch ($choice) {
        "1" {
            $operation = "fetch"
            $opDesc = "Fetching"
            $gitArgs = @("fetch", "--all")
            $needBranch = $false
        }
        "2" {
            $operation = "fetch"
            $opDesc = "Fetching"
            $needBranch = $true
        }
        "3" {
            $operation = "pull"
            $opDesc = "Pulling"
            $gitArgs = @("pull")
            $needBranch = $false
        }
        "4" {
            $operation = "update"
            $opDesc = "Updating"
            $needBranch = $true
        }
        "5" {
            $operation = "pull-all"
            $opDesc    = "Pull 所有分支"
            $needBranch = $false
        }
    }
}

if ($needBranch) {
    Write-Host ""
    Write-Host "Fetching remote branches..." -ForegroundColor Blue
    git fetch --all --quiet 2>$null

    # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
    $branchArray = @(
        git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null |
        Where-Object { $_ -ne 'HEAD' -and $_ -ne '' } |
        Sort-Object -Unique
    )

    if ($branchArray.Count -eq 0) {
        Write-Host "ERROR: No remote branches found" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "選擇要 ${operation} 的分支：" -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $branchArray.Count; $i++) {
        Write-Host "  [$($i + 1)] $($branchArray[$i])" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  [e] 輸入自訂分支名稱" -ForegroundColor Cyan
    Write-Host "  [c] 取消" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan

    $targetBranch = ""
    while ($true) {
        $branchChoice = (Read-Host "請輸入選擇 (1-$($branchArray.Count)/e/c)").Trim().ToLower()

        if ($branchChoice -eq "c") {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }
        elseif ($branchChoice -eq "e") {
            $targetBranch = (Read-Host "輸入分支名稱").Trim()
            if ($targetBranch -eq "") {
                Write-Host "分支名稱不可為空" -ForegroundColor Yellow
                continue
            }
            break
        }
        elseif ($branchChoice -match '^\d+$') {
            $idx = [int]$branchChoice - 1
            if ($idx -ge 0 -and $idx -lt $branchArray.Count) {
                $targetBranch = $branchArray[$idx]
                break
            }
            Write-Host "無效選擇，請重新輸入。" -ForegroundColor Yellow
        }
        else {
            Write-Host "無效選擇，請重新輸入。" -ForegroundColor Yellow
        }
    }

    switch ($operation) {
        "fetch" { $gitArgs = @("fetch", $Remote, $targetBranch) }
        "update" { $gitArgs = @("fetch", $Remote, "${targetBranch}:${targetBranch}") }
        "pull"   { $gitArgs = @("pull", $Remote, $targetBranch) }
    }

    $opDesc = "$opDesc branch '$targetBranch'"
}

# Confirm
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "$opDesc root and all submodules..." -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Mode) {
    $confirm = (Read-Host "確認要執行此操作？(y/N)").Trim().ToLower()
    if ($confirm -ne "y") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}
Write-Host ""

# Helper: 對單一 repo 更新所有有 upstream 的本地分支
# 執行前先確保 HEAD 已 attach 到分支：detached HEAD 時若不先切回，底下的分支 ref 雖會前進，
# 但實際 checkout 出來的工作目錄仍停在舊 commit，等同於白做。
function Invoke-PullAllBranches {
    param([string]$RepoPath, [string]$RepoName, [string]$RootBranch)

    $attachResult = Ensure-RepoAttachedToBranch -RepoName $RepoName -RepoPath $RepoPath -RootBranch $RootBranch
    if (-not $attachResult.Success) {
        Write-Host "  [X] ERROR: $($attachResult.Message)" -ForegroundColor Red
        return $false
    }
    if ($attachResult.AutoAttached) {
        Write-Host "  [OK] Detached HEAD 已切換到 $($attachResult.Branch)" -ForegroundColor Green
    }

    git -C $RepoPath fetch --all --prune --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] ERROR: fetch 失敗" -ForegroundColor Red
        return $false
    }

    $curBranch   = [string](git -C $RepoPath branch --show-current 2>$null)
    $allBranches = @(git -C $RepoPath branch --format '%(refname:short)' 2>$null |
                     Where-Object { $_ -ne '' })

    $okCount      = 0
    $failBranches = @()

    foreach ($b in $allBranches) {
        $null = git -C $RepoPath rev-parse --abbrev-ref "${b}@{upstream}" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }   # 無 upstream，略過

        if ($b -eq $curBranch) {
            git -C $RepoPath pull --ff-only --quiet
        } else {
            git -C $RepoPath fetch $Remote "${b}:${b}" --quiet 2>$null
        }

        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [OK] $b" -ForegroundColor Green
            $okCount++
        } else {
            Write-Host "    [!] $b — 更新失敗（可能需要 merge）" -ForegroundColor Yellow
            $failBranches += $b
        }
    }

    if ($okCount -eq 0 -and $failBranches.Count -eq 0) {
        Write-Host "  [--] 無有效 upstream 分支，略過" -ForegroundColor DarkGray
    } else {
        $msg   = "  已更新 $okCount 個分支"
        if ($failBranches.Count -gt 0) { $msg += "，$($failBranches.Count) 個失敗" }
        $color = if ($failBranches.Count -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host $msg -ForegroundColor $color
    }

    return ($failBranches.Count -eq 0)
}

# Execute operation
$successCount = 0
$failCount = 0
$failedRepos = @()

if ($operation -eq "pull-all") {
    # Pull all branches in every repo
    foreach ($sub in $submodules) {
        Write-Host "Processing $sub..." -ForegroundColor Blue
        $subPath = Join-Path $ROOT $sub
        # 用 .git 是否存在判斷 submodule 是否已初始化；不可只用 Test-Path 目錄本身，
        # 因為未初始化的 submodule 目錄可能已存在但是空的，git -C 對空目錄會往上層尋根，
        # 誤判為已初始化的父層（root）repo。
        if (-not (Test-Path (Join-Path $subPath ".git"))) {
            Write-Host "  [X] ERROR: submodule directory missing/uninitialized: $sub" -ForegroundColor Red
            $failCount++; $failedRepos += "$sub (missing/uninitialized submodule)"
            continue
        }
        if (Invoke-PullAllBranches -RepoPath $subPath -RepoName $sub -RootBranch $rootResolvedBranch) { $successCount++ }
        else { $failCount++; $failedRepos += $sub }
    }
    Write-Host "Processing root..." -ForegroundColor Blue
    if (Invoke-PullAllBranches -RepoPath (Get-Location).Path -RepoName "root" -RootBranch $rootResolvedBranch) { $successCount++ }
    else { $failCount++; $failedRepos += "root" }
} else {
    # Process submodules first
    foreach ($sub in $submodules) {
        Write-Host "Processing $sub..." -ForegroundColor Blue

        $subPath = Join-Path $ROOT $sub
        # 用 .git 是否存在判斷 submodule 是否已初始化；不可只用 Test-Path 目錄本身，
        # 因為未初始化的 submodule 目錄可能已存在但是空的，git -C 對空目錄會往上層尋根，
        # 誤判為已初始化的父層（root）repo。
        if (-not (Test-Path (Join-Path $subPath ".git"))) {
            Write-Host "  [X] ERROR: submodule directory missing/uninitialized: $sub" -ForegroundColor Red
            $failCount++
            $failedRepos += "$sub (missing/uninitialized submodule)"
            continue
        }

        if ($operation -eq "pull") {
            $attachResult = Ensure-RepoAttachedToBranch -RepoName $sub -RepoPath $subPath -RootBranch $rootResolvedBranch
            if (-not $attachResult.Success) {
                Write-Host "  [X] ERROR: $($attachResult.Message)" -ForegroundColor Red
                $failCount++
                $failedRepos += $sub
                continue
            }
            if ($attachResult.AutoAttached) {
                Write-Host "  [OK] Detached HEAD 已切換到 $($attachResult.Branch)" -ForegroundColor Green
            }
        }

        git -C $subPath @gitArgs
        $result = $LASTEXITCODE

        if ($result -eq 0) {
            Write-Host "  [OK] $opDesc successful" -ForegroundColor Green
            if ($operation -eq "update") {
                Ensure-RepoUpstreamOnBranch -RepoPath $subPath -Branch $targetBranch
            }
            $successCount++
        }
        else {
            Write-Host "  [X] ERROR: $opDesc failed" -ForegroundColor Red
            $failCount++
            $failedRepos += $sub
        }
    }

    # Process root last
    Write-Host "Processing root..." -ForegroundColor Blue
    if ($operation -eq "pull") {
        $attachResult = Ensure-RepoAttachedToBranch -RepoName 'root' -RepoPath $ROOT -RootBranch $rootResolvedBranch
        if (-not $attachResult.Success) {
            Write-Host "  [X] ERROR: $($attachResult.Message)" -ForegroundColor Red
            $failCount++
            $failedRepos += "root"
            $result = 1
        } else {
            if ($attachResult.AutoAttached) {
                Write-Host "  [OK] Detached HEAD 已切換到 $($attachResult.Branch)" -ForegroundColor Green
            }
            & git @gitArgs
            $result = $LASTEXITCODE
        }
    } else {
        & git @gitArgs
        $result = $LASTEXITCODE
    }

    if ($result -eq 0) {
        Write-Host "  [OK] $opDesc successful" -ForegroundColor Green
        if ($operation -eq "update") {
            Ensure-RepoUpstreamOnBranch -RepoPath $ROOT -Branch $targetBranch
        }
        $successCount++
    }
    else {
        Write-Host "  [X] ERROR: $opDesc failed" -ForegroundColor Red
        $failCount++
        $failedRepos += "root"
    }
}

# Summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor Red

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Failed repositories:" -ForegroundColor Red
    foreach ($repo in $failedRepos) {
        Write-Host "  $repo" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "[OK] All repositories updated successfully!" -ForegroundColor Green
Write-Host ""
exit 0
} finally {
    Set-Location $originalLocation
}

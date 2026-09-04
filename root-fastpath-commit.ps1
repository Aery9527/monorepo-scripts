$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 預設不是 UTF-8，若不設定會導致 commit message 裡的中文字元
# 透過 pipe 傳給 git 時被替換成 "?"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
. (Join-Path $PSScriptRoot "lib\root-fastpath.ps1")

$originalLocation = Get-Location
try {
    $repoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
    $Remote   = Get-RemoteName -RepoRoot $repoRoot
    $RemoteRe = [regex]::Escape($Remote)

    function Invoke-Step {
        param([string]$Title)
        Write-Host ""
        Write-Host "=== $Title ===" -ForegroundColor Cyan
    }

    function Get-RepoDivergence {
        param([string]$RepoPath, [string]$Branch)
        $remoteRef = "$Remote/$Branch"
        # git rev-parse --verify 在無 upstream 時預期失敗；PowerShell 5.1 下 $ErrorActionPreference='Stop'
        # 會把 native command 的 stderr 提升為 terminating error，即使有 2>$null 也一樣，須用 try/catch 吸收
        try { git -C $RepoPath rev-parse --verify $remoteRef 2>$null 1>$null } catch {}
        if ($LASTEXITCODE -ne 0) { return @(-1, -1) }
        # rev-list --count 失敗或輸出非數字都必須 fail closed，不可默默當成 0
        try { $aheadRaw = git -C $RepoPath rev-list --count "$remoteRef..HEAD" 2>$null } catch { $aheadRaw = $null }
        if ($LASTEXITCODE -ne 0 -or "$aheadRaw" -notmatch '^\d+$') { throw "failed to count ahead for $RepoPath ($Branch)" }
        try { $behindRaw = git -C $RepoPath rev-list --count "HEAD..$remoteRef" 2>$null } catch { $behindRaw = $null }
        if ($LASTEXITCODE -ne 0 -or "$behindRaw" -notmatch '^\d+$') { throw "failed to count behind for $RepoPath ($Branch)" }
        return @([int]$aheadRaw, [int]$behindRaw)
    }

    # 讀取 root 於某個 ref（HEAD / <remote>/<branch>）記錄的 submodule gitlink SHA。
    function Get-GitlinkSha {
        param([string]$RepoRoot, [string]$Ref, [string]$SubPath)
        # Ref（如 <remote>/<branch>）尚不存在，或 SubPath 在該 ref 下沒有記錄，都是合理失敗；
        # 同上，須用 try/catch 吸收 PS 5.1 把 native command stderr 提升為 terminating error 的問題
        try { $line = git -C $RepoRoot ls-tree $Ref -- $SubPath 2>$null } catch { $line = $null }
        if (-not $line) { return $null }
        return ($line -split '\s+')[2]
    }

    Invoke-Step -Title "Check root fast-path eligibility"
    # 冪等性：若 commit 已完成但 push 未完成（working tree 乾淨且 root 領先遠端），
    # 直接進入 push 階段續跑，不再要求 working tree 有未提交的 gitlink 漂移。
    $resumeMode = $false
    $rootStatus = @(git -C $repoRoot status --porcelain 2>$null | Where-Object { $_ -ne '' })
    if ($rootStatus.Count -eq 0) {
        $resumeBranch = git -C $repoRoot branch --show-current
        $preAhead = 1
        try { git -C $repoRoot rev-parse --verify "$Remote/$resumeBranch" 2>$null 1>$null } catch {}
        if ($LASTEXITCODE -eq 0) {
            try { $ac = git -C $repoRoot rev-list --count "$Remote/$resumeBranch..HEAD" 2>$null } catch { $ac = $null }
            if ("$ac" -match '^\d+$') { $preAhead = [int]$ac } else { $preAhead = 0 }
        }
        if ($preAhead -gt 0) {
            $resumeMode = $true
            Write-Host "root working tree clean but ahead of $Remote — resuming push-only for existing commit(s)" -ForegroundColor Yellow
        }
    }

    if (-not $resumeMode) {
        $eligibility = Test-RootFastpathEligible -RepoRoot $repoRoot
        if (-not $eligibility.Eligible) {
            Write-Host "fast-path unavailable: $($eligibility.Reason)" -ForegroundColor Red
            exit 1
        }
        Write-Host "eligible" -ForegroundColor Green

        Invoke-Step -Title "Commit root submodule refs"
        $message = Build-RootFastpathCommitMessage -Changes $eligibility.Changes
        Invoke-RootFastpathCommit -RepoRoot $repoRoot -Changes $eligibility.Changes -Message $message
        Write-Host "[OK] Root submodule refs committed" -ForegroundColor Green
    }

    Invoke-Step -Title "Fetch & divergence check"
    # 重用 lib/root-fastpath.ps1 已經 dot-source 進來的 Get-FastpathSubmodules，不重新定義
    $submodules = Get-FastpathSubmodules -RepoRoot $repoRoot
    $branch = git -C $repoRoot branch --show-current
    $allRepos = @(@{ Name = "root"; Path = $repoRoot }) + @($submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $repoRoot $_) } })

    $fetchFailed = @()
    foreach ($r in $allRepos) {
        # fetch 可能因網路或 remote 問題合理失敗；同上，須用 try/catch 吸收 PS 5.1 的 stderr 提升
        try { git -C $r.Path fetch $Remote --quiet 2>$null } catch {}
        if ($LASTEXITCODE -ne 0) { $fetchFailed += $r.Name }
    }
    if ($fetchFailed.Count -gt 0) {
        Write-Host "[X] Failed to fetch $Remote for: $($fetchFailed -join ', ')" -ForegroundColor Red
        exit 1
    }

    # 直接從 root 已提交的 tree 推導「本次未推送 commit 所改動的 submodule gitlink」，
    # 這才是真正會被 push 出去的內容；normal 與 resume 兩種情境共用同一條路徑。
    $baseRef = $null
    try { git -C $repoRoot rev-parse --verify "$Remote/$branch" 2>$null 1>$null } catch {}
    if ($LASTEXITCODE -eq 0) { $baseRef = "$Remote/$branch" }

    $changed = @()
    foreach ($sub in $submodules) {
        $headSha = Get-GitlinkSha -RepoRoot $repoRoot -Ref "HEAD" -SubPath $sub
        if (-not $headSha) { continue }
        if ($baseRef) {
            $baseSha = Get-GitlinkSha -RepoRoot $repoRoot -Ref $baseRef -SubPath $sub
            if ($headSha -eq $baseSha) { continue }
        }
        $changed += [PSCustomObject]@{ Name = $sub; Sha = $headSha }
    }

    $behindRepos = @()
    $rootDivergence = Get-RepoDivergence -RepoPath $repoRoot -Branch $branch
    if ($rootDivergence[1] -gt 0) { $behindRepos += "root" }

    # 需要 push 的 submodule：推送它「當前所在分支」，與 root 分支名是否相同無關。
    $toPush = @()
    foreach ($c in $changed) {
        $subPath = Join-Path $repoRoot $c.Name
        $subBranch = git -C $subPath branch --show-current
        if (-not $subBranch) {
            Write-Host "  $($c.Name): detached HEAD — cannot push a branch; will verify SHA reachability" -ForegroundColor Yellow
            continue
        }
        $div = Get-RepoDivergence -RepoPath $subPath -Branch $subBranch
        if ($div[1] -gt 0) { $behindRepos += $c.Name; continue }
        $toPush += [PSCustomObject]@{ Name = $c.Name; Branch = $subBranch; NewBranch = ($div[0] -eq -1) }
    }

    if ($behindRepos.Count -gt 0) {
        Write-Host "[X] Push aborted: manual sync required for: $($behindRepos -join ', ')" -ForegroundColor Red
        exit 1
    }

    Invoke-Step -Title "Dry-run push sync"
    foreach ($p in $toPush) {
        Write-Host "  $($p.Name): git push (dry-run, skipped)" -ForegroundColor DarkGray
    }
    if ($rootDivergence[0] -eq -1 -or $rootDivergence[0] -gt 0) { Write-Host "  root: git push (dry-run, skipped)" -ForegroundColor DarkGray }

    Invoke-Step -Title "Push root fast-path"
    $pushFailed = @()
    foreach ($p in $toPush) {
        $subPath = Join-Path $repoRoot $p.Name
        # git push 失敗（甚至成功但寫 stderr）會在 PS 5.1 $ErrorActionPreference='Stop' 下被提升為
        # terminating error，須用 try/catch 吸收，才能讓 $LASTEXITCODE 判斷成立、迴圈續跑其餘 submodule
        try {
            if ($p.NewBranch) { git -C $subPath push -u $Remote $p.Branch }
            else { git -C $subPath push $Remote $p.Branch }
        } catch {}
        if ($LASTEXITCODE -eq 0) { Write-Host "  $($p.Name): pushed ($($p.Branch))" -ForegroundColor Green }
        else { Write-Host "  $($p.Name): FAILED" -ForegroundColor Red; $pushFailed += $p.Name }
    }

    # 不變量：root gitlink 記錄的每個 submodule SHA，都必須在此刻可從遠端觸及，
    # 否則新 clone 的 root 會指向一個從未發佈的 submodule commit。任一未觸及即中止，root 絕不 push。
    Invoke-Step -Title "Verify committed submodule refs are reachable on $Remote"
    $unreachable = @()
    foreach ($c in $changed) {
        $subPath = Join-Path $repoRoot $c.Name
        try { $refs = @(git -C $subPath branch -r --contains $c.Sha 2>$null) } catch { $refs = @() }
        $onOrigin = $refs | Where-Object { $_ -match "^\s*$RemoteRe/" }
        if ($onOrigin) { Write-Host "  $($c.Name): $($c.Sha.Substring(0,7)) reachable on $Remote" -ForegroundColor Green }
        else { Write-Host "  $($c.Name): $($c.Sha.Substring(0,7)) NOT reachable on $Remote" -ForegroundColor Red; $unreachable += $c.Name }
    }

    if ($pushFailed.Count -gt 0 -or $unreachable.Count -gt 0) {
        if ($pushFailed.Count -gt 0) { Write-Host "[X] Submodule push failed for: $($pushFailed -join ', '). Root will NOT be pushed." -ForegroundColor Red }
        if ($unreachable.Count -gt 0) { Write-Host "[X] Committed submodule refs NOT reachable on $Remote for: $($unreachable -join ', '). Root will NOT be pushed." -ForegroundColor Red }
        exit 1
    }

    if ($rootDivergence[0] -eq -1 -or $rootDivergence[0] -gt 0) {
        try {
            if ($rootDivergence[0] -eq -1) { git -C $repoRoot push -u $Remote $branch }
            else { git -C $repoRoot push $Remote $branch }
        } catch {}
        if ($LASTEXITCODE -ne 0) { Write-Host "[X] root push FAILED" -ForegroundColor Red; exit 1 }
        Write-Host "  root: pushed" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "[OK] Root fast-path commit and push completed." -ForegroundColor Green
    exit 0
} finally {
    Set-Location $originalLocation
}

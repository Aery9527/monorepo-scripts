# Windows PowerShell 5.1 預設不是 UTF-8，若不設定會導致 Invoke-RootFastpathCommit
# 透過 pipe 把中文 commit message 傳給 git 時被替換成 "?"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot "lib\repo-aliases.ps1")
. (Join-Path $PSScriptRoot "lib\root-fastpath.ps1")

$originalLocation = Get-Location
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
$RepoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
$Remote   = Get-RemoteName -RepoRoot $RepoRoot
Set-Location $RepoRoot
try {

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Git Submodule Branch Merge" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Collect submodule paths from .gitmodules
    # ---------------------------------------------------------------------------
    $rawPaths = @(git config --file .gitmodules --get-regexp path 2>$null)
    if ($LASTEXITCODE -ne 0 -or $rawPaths.Count -eq 0) {
        Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
        Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
        exit 1
    }

    $submodules = @()
    foreach ($line in $rawPaths) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -ge 2) {
            $submodules += $parts[1].Trim()
        }
    }

    if ($submodules.Count -eq 0) {
        Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
        Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
        exit 1
    }

    # ---------------------------------------------------------------------------
    # Load merge direction rules (whitelist / blacklist per repo+source_branch)
    # ---------------------------------------------------------------------------
    $mergeRules = @{}
    $mergeRulesFile = Join-Path $RepoRoot "scripts\config\merge-direction-rules.txt"
    if (Test-Path $mergeRulesFile) {
        foreach ($ruleLine in Get-Content $mergeRulesFile -Encoding UTF8) {
            $ruleLine = $ruleLine.Trim()
            if ($ruleLine -eq '' -or $ruleLine.StartsWith('#')) { continue }
            $rp = $ruleLine -split '\s+'
            if ($rp.Count -lt 3) { continue }
            $ruleKey = "$($rp[0])|$($rp[2])"
            $mergeRules[$ruleKey] = @{
                Mode    = $rp[1].ToLower()
                Targets = if ($rp.Count -ge 4) { [string[]]$rp[3..($rp.Count - 1)] } else { @() }
            }
        }
    }

    function Test-MergeAllowed {
        param([string]$Repo, [string]$SourceBranch, [string]$TargetBranch)
        $key = "${Repo}|${SourceBranch}"
        if (-not $mergeRules.ContainsKey($key)) { return $true }
        $rule = $mergeRules[$key]
        switch ($rule.Mode) {
            'allow' { return $TargetBranch -in $rule.Targets }
            'deny'  { return $TargetBranch -notin $rule.Targets }
            default { return $true }
        }
    }

    # 解決 `git fetch <remote> <branch>:<branch>` 在本地新建 branch 但不設 upstream 的痼疾。
    # 當指定 Branch 在本地存在、無 upstream，且 <remote>/<Branch> 存在時，自動補 tracking。
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

    # ---------------------------------------------------------------------------
    # Show current branches; warn when repos are on different branches
    # ---------------------------------------------------------------------------
    Write-Host "Found submodules:" -ForegroundColor Blue
    $rootBranch = git branch --show-current 2>$null
    Write-Host "  - root ($rootBranch)" -ForegroundColor Cyan

    $submoduleBranches = @{}
    $allSame = $true
    foreach ($sub in $submodules) {
        $branch = git -C $sub branch --show-current 2>$null
        $submoduleBranches[$sub] = $branch
        Write-Host "  - $sub ($branch)" -ForegroundColor Cyan
        if ($branch -ne $rootBranch) { $allSame = $false }
    }
    Write-Host ""

    if (-not $allSame) {
        Write-Host "[!] WARNING: Not all repositories are on the same branch!" -ForegroundColor Yellow
        Write-Host "    Please make sure all repositories are on the same branch before merging." -ForegroundColor Yellow
        Write-Host ""
        $continueAnyway = Read-Host "是否仍要繼續？(y/N)"
        if ($continueAnyway -ne 'y' -and $continueAnyway -ne 'Y') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    $targetBranch = $rootBranch
    $sourceBranch = $rootBranch
    Write-Host "Target branch (current): $targetBranch" -ForegroundColor Cyan
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Select fetch mode
    # ---------------------------------------------------------------------------
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "選擇操作模式：" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 僅使用本地分支（不 fetch）" -ForegroundColor Green
    Write-Host "  [2] 先 fetch 遠端分支（建議）" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [c] 取消" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan

    $fetchMode = 0
    while ($true) {
        $modeChoice = Read-Host "請輸入選擇 (1-2/c)"

        if ($modeChoice -ieq 'c') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        } elseif ($modeChoice -eq '1') {
            Write-Host "[OK] Using local branches only" -ForegroundColor Green
            $fetchMode = 0
            Write-Host ""
            break
        } elseif ($modeChoice -eq '2') {
            Write-Host "[OK] Fetching remote branches..." -ForegroundColor Green
            $fetchMode = 1
            Write-Host ""

            Write-Host "  Fetching root..." -ForegroundColor Cyan
            # --no-recurse-submodules: 每個 submodule 下面已經有獨立的 fetch 迴圈處理，
            # root 這一步不需要靠 git 預設的 on-demand 遞迴去抓 gitlink 指到的 submodule commit——
            # 一旦某個 gitlink 壞掉（指向 submodule 遠端已不可達的 commit），會連帶讓 root fetch 直接失敗。
            $fetchOutput = git fetch --all --quiet --no-recurse-submodules 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: Failed to fetch in root" -ForegroundColor Red
                if ($fetchOutput) { Write-Host ("    " + ($fetchOutput | Out-String).Trim()) -ForegroundColor Red }
                exit 1
            }

            foreach ($sub in $submodules) {
                Write-Host "  Fetching $sub..." -ForegroundColor Cyan
                $fetchOutput = git -C $sub fetch --all --quiet 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "ERROR: Failed to fetch in $sub" -ForegroundColor Red
                    if ($fetchOutput) { Write-Host ("    " + ($fetchOutput | Out-String).Trim()) -ForegroundColor Red }
                    exit 1
                }
            }

            Write-Host "[OK] Fetch completed" -ForegroundColor Green
            Write-Host ""
            break
        } else {
            Write-Host "無效選擇，請輸入 1、2 或 c" -ForegroundColor Red
        }
    }

    # ---------------------------------------------------------------------------
    # Branch Audit Matrix — 顯示各分支在各 repo 的分佈狀態
    # ---------------------------------------------------------------------------
    $mg_root = (Get-Location).Path
    $mg_repos = @(@{ Name = "root"; Path = $mg_root }) + @(
    $submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $mg_root $_) } }
    )
    $mg_bd = @{}
    $mg_cur = @{}
    foreach ($r in $mg_repos) {
        $mg_cur[$r.Name] = git -C $r.Path branch --show-current 2>$null
        $lB = @(git -C $r.Path branch --format='%(refname:short)' 2>$null | Where-Object { $_ -ne '' })
        # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
        $rB = @(git -C $r.Path for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null |
                Where-Object { $_ -ne 'HEAD' -and $_ -ne '' } | Sort-Object -Unique)
        foreach ($b in $lB) {
            if (-not $mg_bd.ContainsKey($b))          { $mg_bd[$b] = @{} }
            if (-not $mg_bd[$b].ContainsKey($r.Name)) { $mg_bd[$b][$r.Name] = @{ L = $false; R = $false } }
            $mg_bd[$b][$r.Name].L = $true
        }
        foreach ($b in $rB) {
            if (-not $mg_bd.ContainsKey($b))          { $mg_bd[$b] = @{} }
            if (-not $mg_bd[$b].ContainsKey($r.Name)) { $mg_bd[$b][$r.Name] = @{ L = $false; R = $false } }
            $mg_bd[$b][$r.Name].R = $true
        }
    }
    $mg_all = @($mg_bd.Keys | Sort-Object)
    $repoRootForAliases = $RepoRoot
    $aliasMap = Get-RepoAliasMap -RepoRoot $repoRootForAliases
    $mg_sn = @{}
    foreach ($r in $mg_repos) {
        $mg_sn[$r.Name] = Get-RepoShortName -RepoName $r.Name -AliasMap $aliasMap
    }
    $mg_maxS = ($mg_sn.Values | Measure-Object Length -Maximum).Maximum
    $mg_rCol = [Math]::Max($mg_maxS + 2, 6)
    $mg_maxB = if ($mg_all.Count -gt 0) { ($mg_all | Measure-Object -Property Length -Maximum).Maximum } else { 22 }
    $mg_bCol = [Math]::Max(24, $mg_maxB + 2)
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host "   Branch Audit — 各分支分佈狀態" -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  v=local+remote   L=local-only   R=remote-only   -=不存在" -ForegroundColor DarkGray
    Write-Host "  （藍字列 = merge 目標 branch；請選擇來源 branch）" -ForegroundColor DarkGray
    Write-Host ""
    $mg_hdr = "  " + "Branch".PadRight($mg_bCol)
    foreach ($r in $mg_repos) { $mg_hdr += $mg_sn[$r.Name].PadLeft($mg_rCol) }
    Write-Host $mg_hdr -ForegroundColor Blue
    Write-Host ("  " + "-" * ($mg_bCol + $mg_repos.Count * $mg_rCol)) -ForegroundColor DarkGray
    foreach ($b in $mg_all) {
        $mg_line = "  " + $b.PadRight($mg_bCol)
        $mg_issue = $false
        foreach ($r in $mg_repos) {
            $s = $mg_bd[$b][$r.Name]
            if ($null -eq $s -or (-not $s.L -and -not $s.R)) {
                $mg_line += "-".PadLeft($mg_rCol)
            } elseif ($s.L -and $s.R) {
                $mg_line += "v".PadLeft($mg_rCol)
            } elseif ($s.L) {
                $mg_line += "L".PadLeft($mg_rCol); $mg_issue = $true
            } else {
                $mg_line += "R".PadLeft($mg_rCol); $mg_issue = $true
            }
        }
        if ($b -eq $targetBranch) { Write-Host $mg_line -ForegroundColor Cyan }
        elseif ($mg_issue) { Write-Host $mg_line -ForegroundColor Yellow }
        else { Write-Host $mg_line -ForegroundColor Green }
    }
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Collect common branches: present in root AND every submodule
    # ---------------------------------------------------------------------------
    Write-Host "Collecting common branches..." -ForegroundColor Blue

    $branchCount = @{}
    $totalRepos  = $submodules.Count + 1

    # Root branches：不用 git branch -a（會混入其他 remote，且本地分支與
    # refs/remotes/<remote>/HEAD 會變成同一個裸名字），改用 for-each-ref 精確列舉。
    # 分開取值並各自檢查 exit code，避免把「列舉失敗」誤判成「沒有共同分支」。
    $rootHeads = @(git for-each-ref --format='%(refname:strip=2)' refs/heads 2>$null)
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: 無法列舉 root 的本地分支" -ForegroundColor Red; exit 1 }
    $rootRemotes = @(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null)
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: 無法列舉 root 的遠端分支（remote: $Remote）" -ForegroundColor Red; exit 1 }
    $rootBranches = @(
        ($rootHeads + $rootRemotes) |
            Where-Object { $_ -and $_ -ne 'HEAD' -and $_ -ne $targetBranch } |
            Sort-Object -Unique
    )
    foreach ($b in $rootBranches) {
        if ($b) { $branchCount[$b] = ($branchCount[$b] -as [int]) + 1 }
    }

    # Submodule branches
    foreach ($sub in $submodules) {
        $subHeads = @(git -C $sub for-each-ref --format='%(refname:strip=2)' refs/heads 2>$null)
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: 無法列舉 $sub 的本地分支" -ForegroundColor Red; exit 1 }
        $subRemotes = @(git -C $sub for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null)
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: 無法列舉 $sub 的遠端分支（remote: $Remote）" -ForegroundColor Red; exit 1 }
        $subBranches = @(
            ($subHeads + $subRemotes) |
                Where-Object { $_ -and $_ -ne 'HEAD' -and $_ -ne $targetBranch } |
                Sort-Object -Unique
        )
        foreach ($b in $subBranches) {
            if ($b) { $branchCount[$b] = ($branchCount[$b] -as [int]) + 1 }
        }
    }

    # Keep only branches present in all repos, then sort
    $branchList = @(
    $branchCount.Keys |
            Where-Object { $branchCount[$_] -eq $totalRepos } |
            Sort-Object
    )

    Write-Host "[OK] Found $($branchList.Count) available source branches" -ForegroundColor Green
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Branch selection menu
    # ---------------------------------------------------------------------------
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "選擇要 merge 的來源分支：" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Current branch: $targetBranch" -ForegroundColor Cyan
    Write-Host "  Will merge: [source] -> $targetBranch" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $branchList.Count; $i++) {
        Write-Host "  [$($i + 1)] $($branchList[$i])" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  [e] 輸入自訂分支名稱" -ForegroundColor Cyan
    Write-Host "  [c] 取消" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan

    while ($true) {
        $choice = Read-Host "請輸入選擇 (1-$($branchList.Count)/e/c)"

        if ($choice -ieq 'c') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }

        if ($choice -ieq 'e') {
            $customBranch = Read-Host "輸入來源分支名稱"
            if (-not $customBranch) {
                Write-Host "ERROR: Branch name cannot be empty" -ForegroundColor Red
                continue
            }
            $sourceBranch = $customBranch
            break
        }

        $num = 0
        if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $branchList.Count) {
            $sourceBranch = $branchList[$num - 1]
            break
        }

        Write-Host "無效選擇，請輸入 1 到 $($branchList.Count) 的數字、e 或 c" -ForegroundColor Red
    }

    # ---------------------------------------------------------------------------
    # Merge plan + confirmation
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Merge Plan:" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Source: $sourceBranch" -ForegroundColor Cyan
    Write-Host "  Target: $targetBranch" -ForegroundColor Cyan
    Write-Host "  Action: Merge $sourceBranch into current branch $targetBranch" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "確認要執行此操作？(y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Guard: reject uncommitted changes
    # ---------------------------------------------------------------------------
    Write-Host "Checking for uncommitted changes..." -ForegroundColor Blue
    $hasChanges = $false

    git diff --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $hasChanges = $true }
    git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $hasChanges = $true }

    foreach ($sub in $submodules) {
        git -C $sub diff --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { $hasChanges = $true }
        git -C $sub diff --cached --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { $hasChanges = $true }
    }

    if ($hasChanges) {
        Write-Host "[X] ERROR: There are uncommitted changes in one or more repositories." -ForegroundColor Red
        Write-Host "    Please commit or stash your changes before merging." -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] No uncommitted changes" -ForegroundColor Green
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Counters
    # ---------------------------------------------------------------------------
    $successCount    = 0
    $failCount       = 0
    $skippedCount    = 0
    $failedRepos     = @()
    $skippedRepos    = @()
    $skippedSubNames = [System.Collections.Generic.HashSet[string]]::new()

    # ---------------------------------------------------------------------------
    # Fetch mode: fast-forward local source branch to remote tip
    # ---------------------------------------------------------------------------
    if ($fetchMode -eq 1) {
        Write-Host "Updating local source branch to remote version..." -ForegroundColor Blue
        Write-Host ""

        Write-Host "  Updating root..." -ForegroundColor Cyan
        # --no-recurse-submodules: 同上，避免壞掉的 gitlink 讓這裡的 fetch/pull 也失敗。
        git fetch --no-recurse-submodules $Remote "${sourceBranch}:${sourceBranch}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Fallback: checkout + pull --ff-only
            $savedBranch = git branch --show-current 2>$null
            git checkout $sourceBranch 2>$null
            if ($LASTEXITCODE -eq 0) {
                git pull --no-recurse-submodules $Remote $sourceBranch --ff-only 2>$null
                git checkout $savedBranch 2>$null
            }
        }
        Ensure-RepoUpstreamOnBranch -RepoPath '.' -Branch $sourceBranch

        foreach ($sub in $submodules) {
            Write-Host "  Updating $sub..." -ForegroundColor Cyan

            # 用 .git 是否存在判斷 submodule 是否已初始化；不可用 `git -C` 探測，
            # 因為空目錄會被 git 往上層目錄尋根，誤判為已初始化的父層 repo。
            if (-not (Test-Path (Join-Path $sub ".git"))) {
                Write-Host "  [!] Skipping - submodule directory missing/uninitialized: $sub" -ForegroundColor Yellow
                continue
            }

            git -C $sub fetch $Remote "${sourceBranch}:${sourceBranch}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                $savedBranch = git -C $sub branch --show-current 2>$null
                git -C $sub checkout $sourceBranch 2>$null
                if ($LASTEXITCODE -eq 0) {
                    git -C $sub pull $Remote $sourceBranch --ff-only 2>$null
                    git -C $sub checkout $savedBranch 2>$null
                }
            }
            Ensure-RepoUpstreamOnBranch -RepoPath $sub -Branch $sourceBranch
        }

        Write-Host "[OK] Source branch updated" -ForegroundColor Green
        Write-Host ""
    }

    # ---------------------------------------------------------------------------
    # Merge submodules first
    # ---------------------------------------------------------------------------
    foreach ($sub in $submodules) {
        Write-Host "Processing $sub..." -ForegroundColor Blue

        # 用 .git 是否存在判斷 submodule 是否已初始化；不可用 `git -C` 探測，
        # 因為空目錄會被 git 往上層目錄尋根，誤判為已初始化的父層 repo。
        if (-not (Test-Path (Join-Path $sub ".git"))) {
            Write-Host "  [X] ERROR: submodule directory missing/uninitialized: $sub" -ForegroundColor Red
            $failCount++
            $failedRepos += "$sub (missing/uninitialized submodule)"
            continue
        }

        $subTarget = $submoduleBranches[$sub]

        if (-not (Test-MergeAllowed -Repo $sub -SourceBranch $sourceBranch -TargetBranch $subTarget)) {
            Write-Host "  [SKIP] Direction rule blocks $sourceBranch -> $subTarget" -ForegroundColor Yellow
            $skippedCount++
            $skippedRepos += "$sub (direction rule: $sourceBranch -> $subTarget)"
            $skippedSubNames.Add($sub) | Out-Null
            continue
        }

        Write-Host "  Merging $sourceBranch into $subTarget..." -ForegroundColor Cyan
        git -C $sub merge $sourceBranch --no-edit
        $mergeExit = $LASTEXITCODE

        if ($mergeExit -eq 0) {
            Write-Host "  [OK] Merge successful" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "  [X] ERROR: Merge failed - conflicts detected" -ForegroundColor Red
            Write-Host "  Please resolve conflicts manually in $sub" -ForegroundColor Red
            $failCount++
            $failedRepos += "$sub (merge conflict)"
        }
    }

    # ---------------------------------------------------------------------------
    # Merge root
    # submodule conflicts not resolved => skip root (would be meaningless noise)
    # ---------------------------------------------------------------------------
    if ($failCount -gt 0) {
        Write-Host "[!] Skipping root merge - $failCount submodule(s) have unresolved conflicts." -ForegroundColor Yellow
        Write-Host "    Resolve submodule conflicts first, then re-run or merge root manually." -ForegroundColor Yellow
    } else {
        Write-Host "Processing root..." -ForegroundColor Blue

        if (-not (Test-MergeAllowed -Repo 'root' -SourceBranch $sourceBranch -TargetBranch $targetBranch)) {
            Write-Host "  [SKIP] Direction rule blocks $sourceBranch -> $targetBranch in root" -ForegroundColor Yellow
            $skippedCount++
            $skippedRepos += "root (direction rule: $sourceBranch -> $targetBranch)"
        } else {

            Write-Host "  Merging $sourceBranch into $targetBranch..." -ForegroundColor Cyan
            git merge $sourceBranch --no-edit

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Merge successful" -ForegroundColor Green
                $successCount++
            } else {
                # Determine whether the conflict is purely submodule refs (mode 160000).
                # If so, auto-resolve by accepting the current HEAD ref of each submodule
                # and completing the merge commit.  Any real file conflict requires manual work.
                Write-Host "  [!] Root merge conflict detected, analysing..." -ForegroundColor Yellow

                $conflictLines   = @(git ls-files -u 2>$null)
                $hasNonSubmodule = $false
                $conflictedPaths = @{}   # deduplicated; one path appears 3× (stages 1-3)

                foreach ($line in $conflictLines) {
                    # git ls-files -u format: "<mode> <sha1> <stage>\t<path>"
                    $tabParts = $line -split '\t', 2
                    if ($tabParts.Count -ge 2) {
                        $mode     = ($tabParts[0] -split '\s+')[0]
                        $filePath = $tabParts[1]
                        if ($mode -ne '160000') {
                            $hasNonSubmodule = $true
                        } else {
                            $conflictedPaths[$filePath] = $true
                        }
                    }
                }

                if ($hasNonSubmodule) {
                    Write-Host "  [X] ERROR: Real file conflicts in root - please resolve manually" -ForegroundColor Red
                    $failCount++
                    $failedRepos += "root (merge conflict)"
                } else {
                    Write-Host "  [!] Only submodule ref conflicts detected" -ForegroundColor Yellow

                    # 若 gitlink 衝突涉及被 direction rule skip 的子模組，無法安全自動解衝：
                    # auto-resolve 只能取目前工作樹 HEAD（target side），會靜默丟棄 source 端更新。
                    $dangerousConflicts = @($conflictedPaths.Keys | Where-Object { $skippedSubNames.Contains($_) })
                    if ($dangerousConflicts.Count -gt 0) {
                        Write-Host "  [X] ERROR: Root gitlink conflict for skipped submodule(s): $($dangerousConflicts -join ', ')" -ForegroundColor Red
                        Write-Host "      Cannot auto-resolve safely - accepting current HEAD would silently drop the source-side pointer update." -ForegroundColor Red
                        Write-Host "      Please abort the merge (git merge --abort) and resolve manually." -ForegroundColor Red
                        $failCount++
                        $failedRepos += "root (unsafe gitlink conflict for skipped: $($dangerousConflicts -join ', '))"
                    } else {
                        Write-Host "  [!] Auto-resolving: accepting current HEAD of each conflicted submodule..." -ForegroundColor Yellow
                        foreach ($path in $conflictedPaths.Keys) {
                            git add $path
                        }
                        git commit --no-edit
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  [OK] Merge completed - submodule ref conflicts auto-resolved" -ForegroundColor Green
                            $successCount++
                        } else {
                            Write-Host "  [X] ERROR: Failed to complete merge after auto-resolve" -ForegroundColor Red
                            $failCount++
                            $failedRepos += "root (merge commit failed)"
                        }
                    }
                }
            }

        } # end direction-rule check
    }

    # ---------------------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Summary" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed:     $failCount" -ForegroundColor Red
    Write-Host "  Skipped:    $skippedCount" -ForegroundColor Yellow

    if ($failedRepos.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed repositories:" -ForegroundColor Red
        foreach ($repo in $failedRepos) {
            Write-Host "  $repo" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "[!] Some merges failed. Please resolve conflicts manually." -ForegroundColor Yellow
        exit 1
    }

    if ($skippedRepos.Count -gt 0) {
        Write-Host ""
        Write-Host "Skipped repositories (direction rules):" -ForegroundColor Yellow
        foreach ($repo in $skippedRepos) {
            Write-Host "  $repo" -ForegroundColor Yellow
        }
    }

    # ---------------------------------------------------------------------------
    # Auto-commit root submodule refs via fastpath
    # After submodule merges, root's gitlinks lag behind the actual submodule
    # HEADs.  Probe eligibility silently; only commit when root's dirty state is
    # purely submodule refs.  Mixed / non-submodule changes require manual commit.
    # ---------------------------------------------------------------------------
    $repoRootForFastpath = $RepoRoot
    $fastpathResult = Test-RootFastpathEligible -RepoRoot $repoRootForFastpath

    if ($fastpathResult.Eligible) {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Blue
        Write-Host "   Auto-committing root submodule refs" -ForegroundColor Blue
        Write-Host "==========================================" -ForegroundColor Blue
        $fastpathMessage = Build-RootFastpathCommitMessage -Changes $fastpathResult.Changes
        try {
            Invoke-RootFastpathCommit -RepoRoot $repoRootForFastpath -Changes $fastpathResult.Changes -Message $fastpathMessage
            Write-Host "[OK] Root submodule refs committed" -ForegroundColor Green
        } catch {
            Write-Host "[X] ERROR: Failed to commit root submodule refs — $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    } else {
        $rootDirty = @(git status --porcelain 2>$null | Where-Object { $_ -ne '' })
        if ($rootDirty.Count -gt 0) {
            Write-Host ""
            Write-Host "[!] Root has uncommitted changes that are not pure submodule refs." -ForegroundColor Yellow
            Write-Host "    Please commit root manually." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "[OK] All merges completed successfully!" -ForegroundColor Green
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Final branch status
    # ---------------------------------------------------------------------------
    Write-Host "Current branch status:" -ForegroundColor Blue
    $rootCurrent = git branch --show-current 2>$null
    Write-Host "  root: $rootCurrent" -ForegroundColor Cyan
    foreach ($sub in $submodules) {
        $current = git -C $sub branch --show-current 2>$null
        Write-Host "  ${sub}: $current" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "[!] Remember to push changes after reviewing the merge results." -ForegroundColor Yellow

    exit 0
} finally {
    Set-Location $originalLocation
}

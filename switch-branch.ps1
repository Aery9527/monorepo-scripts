$originalLocation = Get-Location
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
$RepoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
$Remote   = Get-RemoteName -RepoRoot $RepoRoot
Set-Location $RepoRoot
try {
. (Join-Path $PSScriptRoot "lib\repo-aliases.ps1")

# ===========================================
# Git Submodule Branch Switcher
# 一次切換 root 和所有 git submodule 到相同的 branch
#
# 用法:
#   .\monorepo-scripts\switch-branch.ps1              互動式選單
#   .\monorepo-scripts\switch-branch.ps1 <branch>     非互動：直接切換到指定分支
# ===========================================

# Parse command line argument ($args available without param() block)
$script:nonInteractive    = $false
$script:targetBranch      = ""
$script:createIfNotExists = $false
$script:successCount      = 0
$script:failCount         = 0
$script:failedRepos       = @()

if ($args.Count -gt 0 -and $args[0] -ne "") {
    $script:nonInteractive    = $true
    $script:targetBranch      = $args[0]
    $script:createIfNotExists = $true
}

# Load repo alias map for short name display
$script:aliasMap = Get-RepoAliasMap (Get-Location).Path

# ---------------------------------------------------------------------------
# Ensure-RepoUpstream
# 切換完成後，若當前 branch 缺 upstream 但 <remote>/<branch> 存在，自動補 tracking。
# 解決 "git checkout -b develop"（無來源）會留下無 upstream 本地 branch 的痼疾，
# 避免之後 git pull 出現 "no tracking information" 錯誤。
# ---------------------------------------------------------------------------
function Ensure-RepoUpstream {
    param([string]$RepoPath)

    $curBranch = [string](git -C $RepoPath branch --show-current 2>$null)
    if (-not $curBranch) { return }

    $null = git -C $RepoPath rev-parse --abbrev-ref '@{upstream}' 2>$null
    if ($LASTEXITCODE -eq 0) { return }

    git -C $RepoPath show-ref --verify --quiet "refs/remotes/$Remote/$curBranch" 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    git -C $RepoPath branch --set-upstream-to="$Remote/$curBranch" $curBranch --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] upstream 已自動補上 -> $Remote/$curBranch" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Switch-RepoBranch
# Switches the CWD repository to $script:targetBranch.
# Modifies $script:successCount / failCount / failedRepos / createIfNotExists.
# Returns $true on success, $false on failure.
# ---------------------------------------------------------------------------
function Switch-RepoBranch {
    param([string]$RepoName, [string]$Path)

    # Uncommitted changes check
    git -C $Path diff --quiet 2>$null
    $diffResult = $LASTEXITCODE
    git -C $Path diff --cached --quiet 2>$null
    $cachedResult = $LASTEXITCODE

    if ($diffResult -ne 0) {
        Write-Host "  [X] ERROR: $RepoName has uncommitted changes" -ForegroundColor Red
        $script:failCount++
        $script:failedRepos += "$RepoName (uncommitted changes)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }
    if ($cachedResult -ne 0) {
        Write-Host "  [X] ERROR: $RepoName has staged changes" -ForegroundColor Red
        $script:failCount++
        $script:failedRepos += "$RepoName (staged changes)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }

    # Detect skip-worktree files (invisible to git-diff/status but can block checkout)
    $swFiles = @(git -C $Path ls-files -v 2>$null | Where-Object { $_ -match '^S ' } | ForEach-Object {
        ($_ -split '\s+', 2)[1]
    })
    if ($swFiles.Count -gt 0) {
        $swList = $swFiles -join ', '
        Write-Host "  [!] WARNING: $RepoName has skip-worktree files: $swList" -ForegroundColor Yellow
        Write-Host "      These are hidden from git status but may block checkout." -ForegroundColor Yellow
        Write-Host "      Fix: git update-index --no-skip-worktree <file> && git checkout -- <file>" -ForegroundColor Yellow
    }

    # Detect untracked files (warning only — safe unless target branch has files at the same paths)
    $untrackedFiles = @(git -C $Path ls-files --others --exclude-standard 2>$null)
    if ($untrackedFiles.Count -gt 0) {
        Write-Host "  [!] INFO: $RepoName has untracked files (will be ignored during switch):" -ForegroundColor DarkGray
        foreach ($f in $untrackedFiles) {
            Write-Host "      $f" -ForegroundColor DarkGray
        }
        Write-Host "      Safe unless the target branch has committed files at the same paths." -ForegroundColor DarkGray
    }

    $branch = $script:targetBranch

    # Helper: run checkout and surface clear error when blocked by untracked files
    function Invoke-Checkout {
        param([string[]]$GitArgs)
        $out = git -C $Path @GitArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and ($out -join "`n") -match "untracked working tree") {
            Write-Host "  [X] ERROR: Checkout blocked — untracked files would be overwritten by target branch:" -ForegroundColor Red
            $out | Where-Object { $_ -match "^\s" -or $_ -match "error:" } | ForEach-Object {
                Write-Host "      $_" -ForegroundColor Red
            }
            Write-Host "      Fix: move or remove the conflicting untracked files, then retry." -ForegroundColor Yellow
        }
        return $exitCode
    }

    # 1. Local branch exists → checkout directly
    git -C $Path show-ref --verify --quiet "refs/heads/$branch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $rc = Invoke-Checkout @("checkout", $branch, "--quiet")
        if ($rc -eq 0) {
            Write-Host "  [OK] Switched to existing local branch" -ForegroundColor Green
            Ensure-RepoUpstream -RepoPath $Path
            $script:successCount++
            return $true
        }
        $script:failCount++
        $script:failedRepos += "$RepoName (checkout failed)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }

    # 2. Remote tracking branch exists → create local tracking branch
    git -C $Path show-ref --verify --quiet "refs/remotes/$Remote/$branch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $rc = Invoke-Checkout @("checkout", "-b", $branch, "$Remote/$branch", "--quiet")
        if ($rc -eq 0) {
            Write-Host "  [OK] Switched to remote tracking branch" -ForegroundColor Green
            Ensure-RepoUpstream -RepoPath $Path
            $script:successCount++
            return $true
        }
        # -b failed (local branch already exists) → fall back to plain checkout
        $rc = Invoke-Checkout @("checkout", $branch, "--quiet")
        if ($rc -eq 0) {
            Write-Host "  [OK] Switched to existing branch" -ForegroundColor Green
            Ensure-RepoUpstream -RepoPath $Path
            $script:successCount++
            return $true
        }
        $script:failCount++
        $script:failedRepos += "$RepoName (checkout failed)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }

    # 3. Branch does not exist locally or remotely
    if ($script:createIfNotExists) {
        $rc = Invoke-Checkout @("checkout", "-b", $branch, "--quiet")
        if ($rc -eq 0) {
            Write-Host "  [OK] Created and switched to new branch" -ForegroundColor Green
            Ensure-RepoUpstream -RepoPath $Path
            $script:successCount++
            return $true
        }
        Write-Host "  [X] ERROR: Failed to create branch $branch" -ForegroundColor Red
        $script:failCount++
        $script:failedRepos += "$RepoName (create branch failed)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }

    # Ask user whether to create the branch
    Write-Host "  [!] Branch $branch does not exist in $RepoName" -ForegroundColor Yellow
    $createAnswer = Read-Host "    是否要建立此分支？(y/N)"
    if ($createAnswer -match '^[Yy]$') {
        $rc = Invoke-Checkout @("checkout", "-b", $branch, "--quiet")
        if ($rc -eq 0) {
            Write-Host "  [OK] Created and switched to new branch" -ForegroundColor Green
            Ensure-RepoUpstream -RepoPath $Path
            $script:successCount++
            $script:createIfNotExists = $true
            return $true
        }
        Write-Host "  [X] ERROR: Failed to create branch $branch" -ForegroundColor Red
        $script:failCount++
        $script:failedRepos += "$RepoName (create branch failed)"
        Write-Host "Aborting due to error." -ForegroundColor Red
        return $false
    }

    Write-Host "  [X] ERROR: Branch $branch does not exist" -ForegroundColor Red
    $script:failCount++
    $script:failedRepos += "$RepoName (branch not found)"
    Write-Host "Aborting due to error." -ForegroundColor Red
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Submodule Branch Switcher" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 取得所有「已初始化」的 submodule 路徑；解析與防護細節見 lib/repo-context.ps1。
$submodules = @(Get-InitializedSubmodulePaths -RepoRoot $RepoRoot)

if ($submodules.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
    exit 1
}

# Display current branch status
Write-Host "Found submodules:" -ForegroundColor Blue
$rootCurrent = git branch --show-current 2>$null
Write-Host "  - root ($rootCurrent)" -ForegroundColor Cyan
foreach ($sub in $submodules) {
    $curr = git -C $sub branch --show-current 2>$null
    Write-Host "  - $sub ($curr)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Interactive: fetch mode selection
# ---------------------------------------------------------------------------
if (-not $script:nonInteractive) {
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

    while ($true) {
        $modeChoice = Read-Host "請輸入選擇 (1-2/c)"

        if ($modeChoice -eq 'c' -or $modeChoice -eq 'C') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        } elseif ($modeChoice -eq '1') {
            Write-Host "[OK] Using local branches only" -ForegroundColor Green
            Write-Host ""
            break
        } elseif ($modeChoice -eq '2') {
            Write-Host "[OK] Fetching remote branches..." -ForegroundColor Green
            Write-Host ""

            Write-Host "  Fetching root..."
            git fetch --all --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: Failed to fetch in root" -ForegroundColor Red
                exit 1
            }
            foreach ($sub in $submodules) {
                Write-Host "  Fetching $sub..."
                git -C $sub fetch --all --quiet 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "ERROR: Failed to fetch in $sub" -ForegroundColor Red
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
}

# ---------------------------------------------------------------------------
# Branch Audit Matrix — 顯示各分支在各 repo 的分佈狀態
# ---------------------------------------------------------------------------
if (-not $script:nonInteractive) {
    $sw_root = (Get-Location).Path
    $sw_repos = @(@{ Name = "root"; Path = $sw_root }) + @(
        $submodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $sw_root $_) } }
    )
    $sw_bd = @{}
    $sw_cur = @{}
    foreach ($r in $sw_repos) {
        $sw_cur[$r.Name] = git -C $r.Path branch --show-current 2>$null
        $lB = @(git -C $r.Path branch --format='%(refname:short)' 2>$null | Where-Object { $_ -ne '' })
        # 只列舉設定的 remote：git branch -r 會混入其他 remote，讓 other/xxx 被當成分支名。
        $rB = @(git -C $r.Path for-each-ref --format='%(refname:strip=3)' "refs/remotes/$Remote" 2>$null |
            Where-Object { $_ -ne 'HEAD' -and $_ -ne '' } | Sort-Object -Unique)
        foreach ($b in $lB) {
            if (-not $sw_bd.ContainsKey($b))          { $sw_bd[$b] = @{} }
            if (-not $sw_bd[$b].ContainsKey($r.Name)) { $sw_bd[$b][$r.Name] = @{ L = $false; R = $false } }
            $sw_bd[$b][$r.Name].L = $true
        }
        foreach ($b in $rB) {
            if (-not $sw_bd.ContainsKey($b))          { $sw_bd[$b] = @{} }
            if (-not $sw_bd[$b].ContainsKey($r.Name)) { $sw_bd[$b][$r.Name] = @{ L = $false; R = $false } }
            $sw_bd[$b][$r.Name].R = $true
        }
    }
    $sw_all = @($sw_bd.Keys | Sort-Object)
    $sw_sn = @{}
    foreach ($r in $sw_repos) {
        $sw_sn[$r.Name] = Get-RepoShortName $r.Name $script:aliasMap
    }
    $sw_maxS = ($sw_sn.Values | Measure-Object Length -Maximum).Maximum
    $sw_rCol = [Math]::Max($sw_maxS + 2, 6)
    $sw_maxB = if ($sw_all.Count -gt 0) { ($sw_all | Measure-Object -Property Length -Maximum).Maximum } else { 22 }
    $sw_bCol = [Math]::Max(24, $sw_maxB + 2)

    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host "   Branch Audit — 各分支分佈狀態" -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  v=local+remote   L=local-only   R=remote-only   -=不存在" -ForegroundColor DarkGray
    Write-Host "  （藍字列 = 目前所在 branch）" -ForegroundColor DarkGray
    Write-Host ""
    $sw_hdr = "  " + "Branch".PadRight($sw_bCol)
    foreach ($r in $sw_repos) { $sw_hdr += $sw_sn[$r.Name].PadLeft($sw_rCol) }
    Write-Host $sw_hdr -ForegroundColor Blue
    Write-Host ("  " + "-" * ($sw_bCol + $sw_repos.Count * $sw_rCol)) -ForegroundColor DarkGray
    foreach ($b in $sw_all) {
        $sw_line = "  " + $b.PadRight($sw_bCol)
        $sw_issue = $false; $sw_isCur = $false
        foreach ($r in $sw_repos) {
            $s = $sw_bd[$b][$r.Name]
            if ($sw_cur[$r.Name] -eq $b) { $sw_isCur = $true }
            if ($null -eq $s -or (-not $s.L -and -not $s.R)) {
                $sw_line += "-".PadLeft($sw_rCol)
            } elseif ($s.L -and $s.R) {
                $sw_line += "v".PadLeft($sw_rCol)
            } elseif ($s.L) {
                $sw_line += "L".PadLeft($sw_rCol); $sw_issue = $true
            } else {
                $sw_line += "R".PadLeft($sw_rCol); $sw_issue = $true
            }
        }
        if ($sw_isCur) { Write-Host $sw_line -ForegroundColor Cyan }
        elseif ($sw_issue) { Write-Host $sw_line -ForegroundColor Yellow }
        else { Write-Host $sw_line -ForegroundColor Green }
    }
    Write-Host ""
}
# ---------------------------------------------------------------------------
if (-not $script:nonInteractive) {
    # 直接使用 audit matrix 已收集的 $sw_all（全 repo 所有 branch 的 union）
    $sw_branchList = if ($sw_all.Count -gt 0) { $sw_all } else { @() }

    Write-Host "[OK] Found $($sw_branchList.Count) 個分支（有缺失的 repo 切換時將自動建立本地 branch）" -ForegroundColor Green
    Write-Host ""

    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host "選擇要切換的目標分支：" -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ""
    for ($i = 0; $i -lt $sw_branchList.Count; $i++) {
        Write-Host "  [$($i + 1)] $($sw_branchList[$i])" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  [e] 輸入自訂分支名稱（若不存在將自動建立）" -ForegroundColor Cyan
    Write-Host "  [c] 取消" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Blue

    while ($true) {
        $choice = Read-Host "請輸入選擇 (1-$($sw_branchList.Count)/e/c)"

        if ($choice -eq 'c' -or $choice -eq 'C') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        } elseif ($choice -eq 'e' -or $choice -eq 'E') {
            $customBranch = Read-Host "輸入新分支名稱"
            if ([string]::IsNullOrWhiteSpace($customBranch)) {
                Write-Host "ERROR: Branch name cannot be empty" -ForegroundColor Red
                continue
            }
            $script:targetBranch      = $customBranch
            $script:createIfNotExists = $true
            break
        } elseif ($choice -match '^\d+$') {
            $idx = [int]$choice
            if ($idx -ge 1 -and $idx -le $sw_branchList.Count) {
                $script:targetBranch      = $sw_branchList[$idx - 1]
                $script:createIfNotExists = $true
                break
            }
        }
        Write-Host "無效選擇，請輸入 1 到 $($sw_branchList.Count) 的數字、e 或 c" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Switching root and all submodules to: $($script:targetBranch)" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

# Confirm before proceeding
if (-not $script:nonInteractive) {
    $confirm = Read-Host "確認要執行此操作？(y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Switch root
# ---------------------------------------------------------------------------
$ROOT = (Get-Location).Path
Write-Host "Switching root..." -ForegroundColor Blue
$ok = Switch-RepoBranch -RepoName "root" -Path $ROOT

if (-not $ok) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Summary" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Successful: $($script:successCount)" -ForegroundColor Green
    Write-Host "  Failed:     $($script:failCount)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Failed repositories:" -ForegroundColor Red
    foreach ($failed in $script:failedRepos) { Write-Host "  $failed" -ForegroundColor Red }
    exit 1
}

# ---------------------------------------------------------------------------
# Switch submodules
# ---------------------------------------------------------------------------
foreach ($sub in $submodules) {
    Write-Host "Switching $sub..." -ForegroundColor Blue
    $ok = Switch-RepoBranch -RepoName $sub -Path (Join-Path $ROOT $sub)
    if (-not $ok) { break }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Successful: $($script:successCount)" -ForegroundColor Green
Write-Host "  Failed:     $($script:failCount)" -ForegroundColor Red

if ($script:failCount -gt 0) {
    Write-Host ""
    Write-Host "Failed repositories:" -ForegroundColor Red
    foreach ($failed in $script:failedRepos) { Write-Host "  $failed" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "[OK] Root and all submodules switched to branch: $($script:targetBranch)" -ForegroundColor Green
Write-Host ""

# Final branch status report
Write-Host "Current branch status:" -ForegroundColor Blue
$rootFinal = git branch --show-current 2>$null
Write-Host "  root: $rootFinal" -ForegroundColor Cyan
foreach ($sub in $submodules) {
    $curr = git -C $sub branch --show-current 2>$null
    Write-Host "  ${sub}: $curr" -ForegroundColor Cyan
}

exit 0
} finally {
    Set-Location $originalLocation
}

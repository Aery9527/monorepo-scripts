# ===========================================
# Git Submodule Push Branch
# 一次對 root 和所有 git submodule 執行 push
# ===========================================

$originalLocation = Get-Location
. (Join-Path $PSScriptRoot "lib/repo-context.ps1")
$RepoRoot = Get-ConsumerRepoRoot -ScriptDir $PSScriptRoot
$Remote   = Get-RemoteName -RepoRoot $RepoRoot
Set-Location $RepoRoot
try {
. (Join-Path $PSScriptRoot "lib\repo-aliases.ps1")
$ROOT = (Get-Location).Path

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Submodule Push Branch" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 取得所有「已初始化」的 submodule 路徑；解析與防護細節見 lib/repo-context.ps1。
$parsedSubmodules = @(Get-InitializedSubmodulePaths -RepoRoot $RepoRoot)

if ($parsedSubmodules.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $RepoRoot" -ForegroundColor Red
    exit 1
}

# 顯示 root 和所有 submodule 的目前分支
Write-Host "Found submodules:" -ForegroundColor Blue
$rootBranch = git branch --show-current 2>$null
Write-Host "  - root ($rootBranch)" -ForegroundColor Cyan
foreach ($sub in $parsedSubmodules) {
    $branch = git -C (Join-Path $ROOT $sub) branch --show-current 2>$null
    Write-Host "  - $sub ($branch)" -ForegroundColor Cyan
}
Write-Host ""

# -----------------------------------------------------------------------
# Push Status Table
# -----------------------------------------------------------------------
$aliasMap = Get-RepoAliasMap -RepoRoot $RepoRoot
$pb_repos = @(@{ Name = "root"; Path = $ROOT }) + @(
    $parsedSubmodules | ForEach-Object { @{ Name = $_; Path = (Join-Path $ROOT $_) } }
)

$pb_nameW   = 8
$pb_branchW = 14
$pb_aheadW  = 7
$pb_rows = @()
foreach ($r in $pb_repos) {
    $short    = Get-RepoShortName -RepoName $r.Name -AliasMap $aliasMap
    if (-not $short)  { $short = $r.Name }
    $branch   = [string](git -C $r.Path branch --show-current 2>$null)
    if (-not $branch) { $branch = "(detached)" }
    $upstream = git -C $r.Path rev-parse --abbrev-ref '@{upstream}' 2>$null
    if ($branch -eq "(detached)") {
        $ahead  = "--"
        $upName = "--"
        $hint   = "detached — 將自動 checkout $rootBranch"
    } elseif ($LASTEXITCODE -ne 0 -or -not $upstream) {
        $ahead  = "--"
        $upName = "(無 upstream)"
        $hint   = "無 upstream — 建議使用 push -u"
    } else {
        $aheadN = git -C $r.Path rev-list '@{upstream}..HEAD' --count 2>$null
        $ahead  = if ($aheadN -match '^\d+$') { "+$aheadN" } else { "--" }
        $upName = $upstream
        $hint   = if ($aheadN -eq "0") { "(已同步)" } else { "需要 push" }
    }
    $pb_nameW   = [Math]::Max($pb_nameW, $short.Length + 2)
    $pb_branchW = [Math]::Max($pb_branchW, $branch.Length + 2)
    $pb_rows   += @{ Short = $short; Branch = $branch; Ahead = $ahead; Upstream = $upName; Hint = $hint }
}

Write-Host "==========================================" -ForegroundColor Blue
Write-Host "   Push 狀態 — 各 repo 目前分支" -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""
Write-Host "  +N = 本地領先 N 個 commit（待 push）   -- = 無 upstream" -ForegroundColor DarkGray
Write-Host ""
$pb_hdr = "  " + "名稱".PadRight($pb_nameW) + "Branch".PadRight($pb_branchW) + "Ahead".PadLeft($pb_aheadW) + "  Upstream"
Write-Host $pb_hdr -ForegroundColor Blue
Write-Host ("  " + "-" * ($pb_nameW + $pb_branchW + $pb_aheadW + 12)) -ForegroundColor DarkGray
foreach ($row in $pb_rows) {
    $line  = "  " + $row.Short.PadRight($pb_nameW) + $row.Branch.PadRight($pb_branchW) + $row.Ahead.PadLeft($pb_aheadW) + "  $($row.Upstream)"
    if ($row.Hint -like "detached*")       { Write-Host $line -ForegroundColor Yellow }
    elseif ($row.Hint -like "無 upstream*") { Write-Host $line -ForegroundColor Yellow }
    elseif ($row.Hint -eq "(已同步)")       { Write-Host $line -ForegroundColor Green }
    else { Write-Host $line -ForegroundColor Cyan }
}
Write-Host ""

# 選單
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "選擇操作：" -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] Push — 推送本地 commit 到遠端 (git push)" -ForegroundColor Green
Write-Host "  [2] Push 並設定 upstream (git push -u $Remote <branch>)" -ForegroundColor Green
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan

# 讀取使用者輸入，loop 直到有效選項
$OPERATION = ""
$OP_DESC   = ""
do {
    $choice = (Read-Host "請輸入選擇 (1-2/c)").ToLower()
    switch ($choice) {
        "c" {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }
        "1" {
            $OPERATION = "push"
            $OP_DESC   = "Pushing"
        }
        "2" {
            $OPERATION = "push-upstream"
            $OP_DESC   = "Pushing with upstream"
        }
        default {
            Write-Host "無效選擇，請輸入 1、2 或 c" -ForegroundColor Yellow
        }
    }
} while ($OPERATION -eq "")

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "$OP_DESC root and all submodules..." -ForegroundColor Blue
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 確認操作
$confirm = Read-Host "確認要執行此操作？(y/N)"
if ($confirm -notmatch '^[Yy]$') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# 組合 repos 清單：root + submodules
$repos = @(@{ Name = "root"; Path = $ROOT })
foreach ($sub in $parsedSubmodules) {
    $repos += @{ Name = $sub; Path = (Join-Path $ROOT $sub) }
}

$successCount = 0
$failCount    = 0
$failedRepos  = @()

foreach ($repo in $repos) {
    Write-Host "Processing $($repo.Name)..." -ForegroundColor Blue

    $currentBranch = [string](git -C $repo.Path branch --show-current 2>$null)
    if (-not $currentBranch) {
        # detached HEAD — 嘗試 checkout 到 root 同名 branch
        git -C $repo.Path checkout $rootBranch 2>$null
        if ($LASTEXITCODE -eq 0) {
            $currentBranch = $rootBranch
            Write-Host "  [!] detached HEAD，已自動 checkout 到 $rootBranch" -ForegroundColor Yellow
        } else {
            Write-Host "  [!] 跳過 — detached HEAD，且找不到 branch '$rootBranch'" -ForegroundColor DarkGray
            continue
        }
    }

    if ($OPERATION -eq "push-upstream") {
        git -C $repo.Path push -u $Remote "$currentBranch"
    } else {
        git -C $repo.Path push
    }
    $exitCode = $LASTEXITCODE  # 立即捕捉，避免後續操作覆寫

    if ($exitCode -eq 0) {
        Write-Host "  [OK] $OP_DESC successful" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "  [X] ERROR: $OP_DESC failed" -ForegroundColor Red
        $failCount++
        $failedRepos += $repo.Name
    }
}

# 結果摘要
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed:     $failCount" -ForegroundColor Red

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Failed repositories:" -ForegroundColor Red
    foreach ($failed in $failedRepos) {
        Write-Host "  - $failed" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "[OK] All repositories pushed successfully!" -ForegroundColor Green
Write-Host ""
exit 0
} finally {
    Set-Location $originalLocation
}

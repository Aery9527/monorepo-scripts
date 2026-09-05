# ===========================================
# Git Rollback（消費端腳本範例）
# 取消 root 和所有 git submodule 的本地變更
#
# 用法:
#   ./scripts/rollback.ps1   互動式選單（唯一入口，無參數模式）
#
# 本檔示範「消費端自有腳本」：住在消費端 repo 的 scripts/ 下，不載入工具集的
# lib，完全自我完備。設計理由與前置條件見同目錄的 SAMPLE.md。
# ===========================================

$originalLocation = Get-Location
try {

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 解析 repo root。消費端腳本住在自己的 repo 內，直接問 git 即可；
# 不可用 Join-Path $PSScriptRoot ".."，那會把「腳本必須放在 root 的下一層」變成隱性契約，
# 一旦目錄結構調整只會得到看不出真因的「找不到 .gitmodules」。
$projectRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectRoot)) {
    Write-Host "ERROR: $PSScriptRoot 不在任何 git repo 內，無法解析 repo root" -ForegroundColor Red
    exit 1
}
Set-Location $projectRoot
$projectRoot = (Get-Location).Path

# 確認路徑是「它自己的」git worktree root。
# 未初始化的 submodule 只是個空目錄，git 會沿著目錄往上找到 superproject —— 此時
# git reset --hard 會打在 root 上而不是該 submodule，靜默且不可逆，必須先擋下。
# 兩邊都經 Resolve-Path 正規化後再比對，避免 git 回傳的正斜線形式被誤判成不同路徑。
function Test-OwnWorktree {
    param ([string]$Path)

    if (-not (Test-Path $Path -PathType Container)) { return $false }
    $top = git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($top)) { return $false }

    $a = Resolve-Path -LiteralPath $top -ErrorAction SilentlyContinue
    $b = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $a -or -not $b) { return $false }
    return ($a.ProviderPath -eq $b.ProviderPath)
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Git Rollback" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 這支腳本只有互動模式：選單與確認都必須由人輸入。stdin 被導向時 Read-Host 可能
# 直接回空字串，會讓選單無限迴圈刷「無效選擇」，因此提前擋下。
if ([Console]::IsInputRedirected) {
    Write-Host "ERROR: 本腳本需要互動式終端機執行（選單與確認皆需人工輸入）" -ForegroundColor Red
    exit 1
}

# 取得所有 submodule 路徑；先落地成陣列再判斷，才不會讓管線吃掉 $LASTEXITCODE。
# submodule 名稱預設等於路徑，路徑含空白時「鍵」本身就含空白，因此不能按空格切 key 與
# value —— 改成先取 key 再逐一 --get 取值。
# regex 必須錨定：未錨定的 "path" 在有名為 lib/pathutil 的 submodule 時會連
# submodule.lib/pathutil.url 一起選出，把 URL 當成路徑列舉。
$cfgKeys = @(git config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$' 2>$null)
if ($LASTEXITCODE -ne 0 -or $cfgKeys.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $projectRoot" -ForegroundColor Red
    exit 1
}

$submodules = @()
foreach ($cfgKey in $cfgKeys) {
    if ([string]::IsNullOrWhiteSpace($cfgKey)) { continue }
    $value = git config --file .gitmodules --get $cfgKey
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
        $submodules += $value.Trim()
    }
}

if ($submodules.Count -eq 0) {
    Write-Host "ERROR: No submodules found in this repository" -ForegroundColor Red
    Write-Host "       解析到的 repo root: $projectRoot" -ForegroundColor Red
    exit 1
}

Write-Host "Found submodules:" -ForegroundColor Blue
$rootBranch = git branch --show-current 2>$null
Write-Host "  - root ($rootBranch)" -ForegroundColor Cyan
foreach ($sub in $submodules) {
    $subPath = Join-Path $projectRoot $sub
    if (Test-OwnWorktree -Path $subPath) {
        $branch = git -C $subPath branch --show-current 2>$null
        Write-Host "  - $sub ($branch)" -ForegroundColor Cyan
    } else {
        Write-Host "  - $sub (未初始化，將略過)" -ForegroundColor Yellow
    }
}
Write-Host ""

Write-Host "==========================================" -ForegroundColor Red
Write-Host "選擇 rollback 操作：" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red
Write-Host ""
Write-Host "  [1] Reset changes        - 還原所有已追蹤檔案的變更 (git reset --hard HEAD)" -ForegroundColor Cyan
Write-Host "  [2] Reset + Clean        - 還原變更並移除 untracked 檔案/目錄 (git reset --hard HEAD && git clean -fd)" -ForegroundColor Cyan
Write-Host "  [3] Clean only           - 僅移除 untracked 檔案/目錄 (git clean -fd)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [c] 取消" -ForegroundColor Yellow
Write-Host ""
Write-Host "==========================================" -ForegroundColor Red

$operation = ""
$opDesc    = ""

while ($true) {
    $choice = Read-Host "請輸入選擇 (1-3/c)"
    if ($null -eq $choice) { $choice = "" }

    switch ($choice.ToLower()) {
        "c" {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }
        "1" {
            $operation = "reset"
            $opDesc    = "Reset all tracked file changes (git reset --hard HEAD)"
        }
        "2" {
            $operation = "reset_clean"
            $opDesc    = "Reset changes + remove untracked files (git reset --hard HEAD && git clean -fd)"
        }
        "3" {
            $operation = "clean"
            $opDesc    = "Remove untracked files (git clean -fd)"
        }
        default {
            Write-Host "無效選擇，請輸入 1-3 或 c" -ForegroundColor Red
        }
    }

    if ($operation -ne "") { break }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Red
Write-Host "  WARNING: This action cannot be undone!" -ForegroundColor Red
Write-Host "  $opDesc" -ForegroundColor Red
Write-Host "  Applies to: root and ALL submodules" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "確認要執行此操作？(y/N)"
if ($confirm -notmatch '^[Yy]$') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

$successCount = 0
$skipCount    = 0
$failCount    = 0
$failedRepos  = @()

function Invoke-Rollback {
    param (
        [string]$RepoPath,
        [string]$RepoName
    )

    Write-Host "Processing $RepoName..." -ForegroundColor Blue

    # 不是自己的 worktree 就略過：這裡若放行，git 會往上找到 superproject 而把
    # reset --hard 打在 root 上。
    if (-not (Test-OwnWorktree -Path $RepoPath)) {
        Write-Host "  - 略過：$RepoName 未初始化或不是獨立的 git worktree" -ForegroundColor Yellow
        $script:skipCount++
        return
    }

    if ($script:operation -eq "reset" -or $script:operation -eq "reset_clean") {
        git -C $RepoPath reset --hard HEAD
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [X] ERROR: git reset --hard HEAD failed" -ForegroundColor Red
            $script:failCount++
            $script:failedRepos += $RepoName
            return
        }
    }

    if ($script:operation -eq "clean" -or $script:operation -eq "reset_clean") {
        git -C $RepoPath clean -fd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [X] ERROR: git clean -fd failed" -ForegroundColor Red
            $script:failCount++
            $script:failedRepos += $RepoName
            return
        }
    }

    Write-Host "  [OK] Done" -ForegroundColor Green
    $script:successCount++
}

# 先處理 submodule 再處理 root，讓中途失敗時的狀態較好判讀
foreach ($sub in $submodules) {
    Invoke-Rollback -RepoPath (Join-Path $projectRoot $sub) -RepoName $sub
}

Invoke-Rollback -RepoPath $projectRoot -RepoName "root"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Skipped:    $skipCount" -ForegroundColor Yellow
Write-Host "  Failed:     $failCount" -ForegroundColor Red

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Failed repositories:" -ForegroundColor Red
    foreach ($repo in $failedRepos) {
        Write-Host "  [X] $repo" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "[OK] All repositories rolled back successfully!" -ForegroundColor Green
Write-Host ""
exit 0
} finally {
    Set-Location $originalLocation
}

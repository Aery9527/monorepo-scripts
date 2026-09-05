# ===========================================
# Normalize Git EOL Settings（消費端腳本範例，Windows 專用）
# 對齊 root 與所有 git submodule 的換行設定：
#   core.autocrlf=false / core.eol=lf / core.safecrlf=true
#
# 用法:
#   ./scripts/normalize-git-eol.ps1                   只改本 repo 與其 submodule
#   ./scripts/normalize-git-eol.ps1 -ApplyGlobal      另外改「使用者全域」git config
#   ./scripts/normalize-git-eol.ps1 -Renormalize:$false   跳過 git add --renormalize
#
# 沒有 .sh 對應版本：core.autocrlf 只在 Windows 上有實際作用，Linux/macOS 執行等同無操作。
# 設計理由與副作用說明見同目錄的 SAMPLE.md。
# ===========================================

param(
    [switch]$ApplyGlobal = $false,
    [switch]$Renormalize = $true
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$originalLocation = Get-Location
try {
    # 解析 repo root。消費端腳本住在自己的 repo 內，直接問 git 即可；
    # 不可用 Join-Path $PSScriptRoot ".."，那會把「腳本必須放在 root 的下一層」變成隱性契約。
    $projectRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectRoot)) {
        throw "$PSScriptRoot 不在任何 git repo 內，無法解析 repo root"
    }
    Set-Location $projectRoot
    $projectRoot = (Get-Location).Path

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Normalize Git EOL Settings" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path ".gitmodules")) {
        throw "Cannot find .gitmodules in repo root: $projectRoot"
    }

    # 確認路徑是「它自己的」git worktree root。
    # 未初始化的 submodule 只是個空目錄，git 會沿著目錄往上找到 superproject —— 此時
    # git config --local 會寫進 root 的設定檔，看起來成功卻改錯對象。
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

    if ($ApplyGlobal) {
        Write-Host "--- Global Git Config ---" -ForegroundColor Blue
        Write-Host "注意：以下三行會改動你的使用者全域 git config，影響本機所有 repo" -ForegroundColor Yellow
        git config --global core.autocrlf false
        if ($LASTEXITCODE -ne 0) { throw "Failed: git config --global core.autocrlf false" }
        git config --global core.eol lf
        if ($LASTEXITCODE -ne 0) { throw "Failed: git config --global core.eol lf" }
        git config --global core.safecrlf true
        if ($LASTEXITCODE -ne 0) { throw "Failed: git config --global core.safecrlf true" }
        Write-Host "[OK] Applied global EOL config" -ForegroundColor Green
        Write-Host ""
    }

    # 取得所有 submodule 路徑；先落地成陣列再判斷，才不會讓管線吃掉 $LASTEXITCODE。
    # submodule 名稱預設等於路徑，路徑含空白時「鍵」本身就含空白，因此不能按空格切 key 與
    # value —— 改成先取 key 再逐一 --get 取值。
    $cfgKeys = @(git config --file .gitmodules --name-only --get-regexp path 2>$null)
    if ($LASTEXITCODE -ne 0 -or $cfgKeys.Count -eq 0) {
        throw "No submodules found in this repository (repo root: $projectRoot)"
    }

    # root 一律納入；submodule 逐一驗證，未初始化的明確列出而不是靜默略過
    $repos = @([pscustomobject]@{ Name = "root"; Path = $projectRoot })
    foreach ($cfgKey in $cfgKeys) {
        if ([string]::IsNullOrWhiteSpace($cfgKey)) { continue }
        $value = git config --file .gitmodules --get $cfgKey
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { continue }

        $sub     = $value.Trim()
        $subPath = Join-Path $projectRoot $sub
        if (Test-OwnWorktree -Path $subPath) {
            $repos += [pscustomobject]@{ Name = $sub; Path = $subPath }
        } else {
            Write-Host "  [!] 略過 $sub：未初始化或不是獨立的 git worktree" -ForegroundColor Yellow
        }
    }

    Write-Host "--- Target Repositories ---" -ForegroundColor Blue
    foreach ($repo in $repos) {
        Write-Host "  $($repo.Name)" -ForegroundColor Cyan
    }
    Write-Host ""

    foreach ($repo in $repos) {
        Write-Host "[$($repo.Name)] Apply local config..." -ForegroundColor Blue

        git -C $repo.Path config --local core.autocrlf false
        if ($LASTEXITCODE -ne 0) { throw "[$($repo.Name)] Failed to set core.autocrlf=false" }

        git -C $repo.Path config --local core.eol lf
        if ($LASTEXITCODE -ne 0) { throw "[$($repo.Name)] Failed to set core.eol=lf" }

        git -C $repo.Path config --local core.safecrlf true
        if ($LASTEXITCODE -ne 0) { throw "[$($repo.Name)] Failed to set core.safecrlf=true" }

        $autocrlf = git -C $repo.Path config --local --get core.autocrlf
        $eol      = git -C $repo.Path config --local --get core.eol
        $safecrlf = git -C $repo.Path config --local --get core.safecrlf
        if ($LASTEXITCODE -ne 0) { throw "[$($repo.Name)] Failed to read back local config" }

        Write-Host "  [OK] autocrlf=$autocrlf eol=$eol safecrlf=$safecrlf" -ForegroundColor Green
    }
    Write-Host ""

    if ($Renormalize) {
        Write-Host "--- Renormalize Index ---" -ForegroundColor Blue
        Write-Host "注意：git add --renormalize 會把換行修正結果放進 index（staged）" -ForegroundColor Yellow
        foreach ($repo in $repos) {
            Write-Host "[$($repo.Name)] git add --renormalize ." -ForegroundColor Blue
            git -C $repo.Path add --renormalize .
            if ($LASTEXITCODE -ne 0) { throw "[$($repo.Name)] renormalize failed" }

            $cachedChanged = @(git -C $repo.Path diff --cached --name-only)
            $cachedChanged = @($cachedChanged | Where-Object { $_ })

            if ($cachedChanged.Count -gt 0) {
                Write-Host "  [!] Found staged changes after renormalize: $($cachedChanged.Count)" -ForegroundColor Yellow
            } else {
                Write-Host "  [OK] No staged content changes" -ForegroundColor Green
            }
        }
        Write-Host ""
    }

    Write-Host "--- Final Status Summary ---" -ForegroundColor Blue
    foreach ($repo in $repos) {
        $count = @(git -C $repo.Path status --porcelain).Count
        if ($count -eq 0) {
            Write-Host "  [OK] $($repo.Name) clean" -ForegroundColor Green
        } else {
            Write-Host "  [!] $($repo.Name) has $count pending changes" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
} finally {
    Set-Location $originalLocation
}

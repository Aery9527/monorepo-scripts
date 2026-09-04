function Get-RepoAliasMap {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $map = @{}
    $aliasFile = Join-Path $RepoRoot "scripts\config\repo-aliases.txt"
    if (-not (Test-Path $aliasFile)) {
        return $map
    }

    foreach ($line in Get-Content -Path $aliasFile -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed -split '\s+', 2
        if ($parts.Count -eq 2) {
            $map[$parts[0]] = $parts[1]
        }
    }
    return $map
}

function Get-RepoShortName {
    param(
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][hashtable]$AliasMap
    )

    if ($AliasMap.ContainsKey($RepoName)) {
        return $AliasMap[$RepoName]
    }
    $fallback = ($RepoName -split '-')[-1]
    if (-not $fallback) { return $RepoName }
    return $fallback
}

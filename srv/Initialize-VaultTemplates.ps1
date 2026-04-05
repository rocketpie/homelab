#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RelativeRepoPath([string]$BasePath, [string]$Path) {
    return [System.IO.Path]::GetRelativePath($BasePath, $Path)
}

function Get-VaultTemplateContent([string]$TargetFilePath) {
    $targetLines = [string[]](Get-Content -LiteralPath $TargetFilePath)
    $markerIndex = -1

    for ($lineIndex = 0; $lineIndex -lt $targetLines.Length; $lineIndex++) {
        if ($targetLines[$lineIndex].Trim() -eq "# vault.yml:") {
            $markerIndex = $lineIndex
            break
        }
    }

    if ($markerIndex -lt 0) {
        return $null
    }

    if ($markerIndex -ge ($targetLines.Length - 1)) {
        return ""
    }

    $templateLines = foreach ($line in $targetLines[($markerIndex + 1)..($targetLines.Length - 1)]) {
        if ($line -match '^\s*# ?(.*)$') {
            $matches[1]
        }
        else {
            $line
        }
    }

    return ($templateLines -join "`n").TrimEnd()
}

$repoRootPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$targetFiles = Get-ChildItem -LiteralPath $repoRootPath -Recurse -File -Include *.yml,*.yaml |
Where-Object { $_.Name -ne "vault.yml" } |
Sort-Object FullName

foreach ($targetFile in $targetFiles) {
    $vaultTemplateContent = Get-VaultTemplateContent -TargetFilePath $targetFile.FullName
    if ($null -eq $vaultTemplateContent) {
        continue
    }

    $vaultFilePath = Join-Path $targetFile.Directory.FullName "vault.yml"
    if (Test-Path -LiteralPath $vaultFilePath) {
        continue
    }

    $vaultFileLines = if ([string]::IsNullOrWhiteSpace($vaultTemplateContent)) {
        @()
    }
    else {
        $vaultTemplateContent -split "\r?\n"
    }

    Set-Content -LiteralPath $vaultFilePath -Encoding utf8NoBOM -Value $vaultFileLines
    Write-Host "Created $(Get-RelativeRepoPath -BasePath $repoRootPath -Path $vaultFilePath)"
}

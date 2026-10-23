#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$RepoRoot = ".",

    [string]$VaultPasswordFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }
}

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
$vaultPasswordFile = if ([string]::IsNullOrWhiteSpace($VaultPasswordFile)) {
    Join-Path (Split-Path -Parent $PSScriptRoot) "vault_pass.ps1"
}
else {
    $VaultPasswordFile
}

Require-Command "ansible-vault"

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

    # Encrypt before the file is created so a plaintext vault never hits disk.
    $encryptedLines = @(
        $vaultTemplateContent | & ansible-vault encrypt --vault-password-file $vaultPasswordFile --output=-
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to encrypt the new vault file for '$($targetFile.FullName)'."
    }
    if ($encryptedLines.Count -eq 0) {
        throw "ansible-vault returned no encrypted content for '$($targetFile.FullName)'."
    }

    Set-Content -LiteralPath $vaultFilePath -Encoding utf8NoBOM -Value $encryptedLines
    Write-Host "Created encrypted $(Get-RelativeRepoPath -BasePath $repoRootPath -Path $vaultFilePath)"
}

#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Variable -Scope Script -Name 'vEnvPath' -Value (Join-Path $PSScriptRoot ".venv")
Set-Variable -Scope Script -Name 'vEnvPython' -Value (Join-Path $vEnvPath "bin/python")
Set-Variable -Scope Script -Name 'vEnvAnsiblePlaybook' -Value (Join-Path $vEnvPath "bin/ansible-playbook")
Set-Variable -Scope Script -Name 'vEnvAnsibleVault' -Value (Join-Path $vEnvPath "bin/ansible-vault")
Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")
Set-Variable -Scope Script -Name 'vaultTemplateRendererScript' -Value (Join-Path $PSScriptRoot "srv/render-vault-template.py")

$localCollections = $(Join-Path $PSScriptRoot ".collections")
if (!"$($env:ANSIBLE_COLLECTIONS_PATH)".Contains($localCollections)) {
    $env:ANSIBLE_COLLECTIONS_PATH = "$($localCollections):$($env:ANSIBLE_COLLECTIONS_PATH)"
}

function Main {
    Ensure-Venv
    Ensure-ToolsInVenv
    Sync-VaultTemplateComments

    $ansibleLint = Join-Path $vEnvPath "bin/ansible-lint"

    if (-not (Test-Path $ansibleLint)) { throw "ansible-lint not found in venv. Ensure it's in $vEnvRequirements and run -InstallVenv." }

    $vaultExcludes = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "vault.yml" -File |
    ForEach-Object {
        [System.IO.Path]::GetRelativePath($PSScriptRoot, $_.FullName)
    } |
    Sort-Object

    $ansibleLintArgs = @()
    foreach ($vaultExclude in $vaultExcludes) {
        $ansibleLintArgs += "--exclude"
        $ansibleLintArgs += $vaultExclude
    }
    $ansibleLintArgs += $PSScriptRoot

    Write-Host "Running ansible-lint..."
    & $ansibleLint @ansibleLintArgs
}

function Get-RelativeRepoPath([string]$Path) {
    return [System.IO.Path]::GetRelativePath($PSScriptRoot, $Path)
}

function Sync-VaultTemplateComments {
    $vaultFiles = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "vault.yml" -File | Sort-Object FullName
    foreach ($vaultFile in $vaultFiles) {
        $targetFiles = @(Get-VaultTemplateTargetFiles -VaultFilePath $vaultFile.FullName)
        if ($targetFiles.Count -eq 0) {
            Write-Warning "No vault template comment target found for $(Get-RelativeRepoPath -Path $vaultFile.FullName)"
            continue
        }

        $commentLines = Get-VaultTemplateCommentLines -VaultFilePath $vaultFile.FullName
        foreach ($targetFile in $targetFiles) {
            Update-VaultTemplateCommentBlock `
                -VaultFilePath $vaultFile.FullName `
                -TargetFilePath $targetFile.FullName `
                -CommentLines $commentLines
        }
    }
}

function Get-VaultTemplateTargetFiles([string]$VaultFilePath) {
    $vaultDirectory = Split-Path -Parent $VaultFilePath

    return Get-ChildItem -LiteralPath $vaultDirectory -File |
    Where-Object {
        $_.Name -ne "vault.yml" -and $_.Extension -in @(".yml", ".yaml")
    } |
    Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^\s*# vault\.yml:\s*$'
    } |
    Sort-Object FullName
}

function Get-VaultTemplateCommentLines([string]$VaultFilePath) {
    $vaultContent = Get-VaultTemplateSourceContent -VaultFilePath $VaultFilePath
    $sanitizedYaml = @($vaultContent | & $vEnvPython $vaultTemplateRendererScript) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build vault template comment for $(Get-RelativeRepoPath -Path $VaultFilePath)"
    }

    $commentLines = [System.Collections.Generic.List[string]]::new()
    $commentLines.Add("# vault.yml:")
    if (-not [string]::IsNullOrWhiteSpace($sanitizedYaml)) {
        foreach ($line in ($sanitizedYaml -split "\r?\n")) {
            if ($line.Length -eq 0) {
                $commentLines.Add("#")
            }
            else {
                $commentLines.Add("# $line")
            }
        }
    }

    return $commentLines.ToArray()
}

function Get-VaultTemplateSourceContent([string]$VaultFilePath) {
    $vaultContent = Get-Content -LiteralPath $VaultFilePath -Raw
    if (-not $vaultContent.TrimStart().StartsWith('$ANSIBLE_VAULT;')) {
        return $vaultContent
    }

    Ensure-VaultPassword

    $decryptedVaultContent = & $vEnvAnsibleVault view $VaultFilePath --vault-password-file $vaultPasswordScript
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to decrypt $(Get-RelativeRepoPath -Path $VaultFilePath) for vault template sync"
    }

    return ($decryptedVaultContent -join "`n")
}

function Update-VaultTemplateCommentBlock(
    [string]$VaultFilePath,
    [string]$TargetFilePath,
    [string[]]$CommentLines
) {
    $originalLines = [string[]](Get-Content -LiteralPath $TargetFilePath)
    $markerIndex = -1
    for ($lineIndex = 0; $lineIndex -lt $originalLines.Length; $lineIndex++) {
        if ($originalLines[$lineIndex].Trim() -eq "# vault.yml:") {
            $markerIndex = $lineIndex
            break
        }
    }

    if ($markerIndex -lt 0) {
        Write-Warning "Skipping $(Get-RelativeRepoPath -Path $TargetFilePath): no # vault.yml: marker found"
        return
    }

    if ($markerIndex -eq 0) {
        $updatedLines = $CommentLines
    }
    else {
        $updatedLines = @($originalLines[0..($markerIndex - 1)] + $CommentLines)
    }

    $originalContent = ($originalLines -join "`n")
    $updatedContent = ($updatedLines -join "`n")
    if ($originalContent -ceq $updatedContent) {
        return
    }

    Write-Host "Syncing vault template comment in $(Get-RelativeRepoPath -Path $TargetFilePath) from $(Get-RelativeRepoPath -Path $VaultFilePath)"
    Set-Content -LiteralPath $TargetFilePath -Encoding utf8NoBOM -Value $updatedLines
}


function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }
}

function Ensure-Venv {
    if (-not (Test-Path $vEnvPython)) {
        Require-Command "python3"
        Write-Host "Creating venv at $vEnvPath"
        & python3 -m venv $vEnvPath
    }
}

function Ensure-ToolsInVenv {
    if (-not (Test-Path $vEnvAnsiblePlaybook)) {
        throw "ansible-playbook not found in venv. Did you run -InstallVenv?"
    }
    if (-not (Test-Path $vEnvAnsibleVault)) {
        throw "ansible-vault not found in venv. Did you run -InstallVenv?"
    }
}

function Ensure-VaultPassword {
    $vaultPassword = $env:ANSIBLE_VAULT_PASSWORD
    if (-not [string]::IsNullOrWhiteSpace($vaultPassword)) {
        return
    }

    $vaultPassword = Read-Host -Prompt "Ansible Vault password?" -AsSecureString
    $env:ANSIBLE_VAULT_PASSWORD = [pscredential]::new('dummy', $vaultPassword).GetNetworkCredential().Password
}

Main

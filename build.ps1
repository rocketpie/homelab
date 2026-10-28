#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ansiblePython = $env:ANSIBLE_PYTHON

Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")
Set-Variable -Scope Script -Name 'vaultTemplateRendererScript' -Value (Join-Path $PSScriptRoot "srv/render-vault-template.py")

function Main {
    Assert-DevContainerRuntime
    & $vaultPasswordScript | Out-Null # ensure vault password is available in the dev container
    Sync-VaultTemplateComments
    Invoke-PlaybookSyntaxChecks

    $vaultExcludes = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "vault.yml" -File |
    ForEach-Object {
        [System.IO.Path]::GetRelativePath($PSScriptRoot, $_.FullName)
    } |
    Sort-Object

    # TODO: now that we have the vault password available in the runtime, can't we run ansible lint on the vault files as well?
    $ansibleLintArgs = @()
    foreach ($vaultExclude in $vaultExcludes) {
        $ansibleLintArgs += "--exclude"
        $ansibleLintArgs += $vaultExclude
    }
    $ansibleLintArgs += $PSScriptRoot

    Write-Host "Running ansible-lint..."
    & ansible-lint @ansibleLintArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ansible-lint failed with exit code $LASTEXITCODE"
    }
}

function Get-RelativeRepoPath([string]$Path) {
    return [System.IO.Path]::GetRelativePath($PSScriptRoot, $Path)
}

function Invoke-PlaybookSyntaxChecks {
    $inventory = Join-Path $PSScriptRoot "inventory/hosts.yml"
    $playbookRoot = Join-Path $PSScriptRoot "playbooks"
    $playbooks = Get-ChildItem -LiteralPath $playbookRoot -Filter "*.yml" -File | Sort-Object Name

    foreach ($playbook in $playbooks) {
        $relativePath = Get-RelativeRepoPath -Path $playbook.FullName
        Write-Host "Checking syntax: $relativePath"
        & ansible-playbook -i $inventory $playbook.FullName --syntax-check
        if ($LASTEXITCODE -ne 0) {
            throw "ansible-playbook --syntax-check failed for $relativePath"
        }
    }
}

# TODO: is there a better way for templating or validating vault.yml files? schema validation?
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
    $sanitizedYaml = @($vaultContent | & $ansiblePython $vaultTemplateRendererScript) -join "`n"
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

    $decryptedVaultContent = & ansible-vault view $VaultFilePath --vault-password-file $vaultPasswordScript
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

function Assert-DevContainerRuntime {
    if ([string]::IsNullOrWhiteSpace($ansiblePython)) {
        throw "ANSIBLE_PYTHON is not set. Run this script inside the dev container."
    }
    if (-not (Test-Path -LiteralPath $ansiblePython)) {
        throw "ANSIBLE_PYTHON does not exist: $ansiblePython. Run this script inside the dev container."
    }
    if (-not (Get-Command ansible-lint -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: 'ansible-lint' not found on PATH. Run this script inside the dev container."
    }
    if (-not (Get-Command ansible-playbook -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: 'ansible-playbook' not found on PATH. Run this script inside the dev container."
    }
    if (-not (Get-Command ansible-vault -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: 'ansible-vault' not found on PATH. Run this script inside the dev container."
    }
}


Main

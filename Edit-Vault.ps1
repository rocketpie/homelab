#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
    [Parameter(ParameterSetName = "Edit", Mandatory, Position = 1)]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $repoRoot = $PSScriptRoot
            if ([string]::IsNullOrWhiteSpace($repoRoot)) { return }

            Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter "vault.yml" -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object { $_.Directory.Name } |
            Where-Object { $_ -like "$wordToComplete*" } |
            Select-Object -Unique
        })]
    [string]$Vault,

    [Parameter(ParameterSetName = "Help")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")
Set-Variable -Scope Script -Name 'vaultTempDirectory' -Value "/dev/shm"

function Write-Help {
    Write-Host "Usage:"
    Write-Host "  pwsh Edit-Vault.ps1 <vault-name>"
    Write-Host "  pwsh Edit-Vault.ps1 -Help"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  <vault-name>           Parent directory name of a vault.yml, e.g. all, proxmox, restic1"
    Write-Host "                         (tab-completion lists them all)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Help                  Show this help (default)"
    Write-Host ""
    Write-Host "This uses the active environment's vault password from vault_pass.ps1."
    Write-Host "TMPDIR is set to /dev/shm so the editor's plaintext copy stays on tmpfs."
    Write-Host ""
    Write-Host "Activate an environment on the container host first:"
    Write-Host "  pwsh Set-Environment.ps1 -Environment <name>"
}

function Main {
    switch ($PSCmdlet.ParameterSetName) {
        default {
            Write-Help
        }
        "Help" {
            Write-Help
        }
        "Edit" {
            Invoke-VaultEdit -VaultPath $Vault
        }
    }
}

function Invoke-VaultEdit([string]$VaultPath) {
    Require-Command "ansible-vault"

    $resolvedVaultPath = Resolve-VaultPath $VaultPath
    Ensure-ActiveVaultPassword

    if (-not (Test-Path -LiteralPath $vaultTempDirectory -PathType Container)) {
        throw "Vault temp directory not found: $vaultTempDirectory"
    }

    # Keep the decrypted editor copy off persistent disk.
    $previousTmpDir = $env:TMPDIR
    try {
        $env:TMPDIR = $vaultTempDirectory
        & ansible-vault edit $resolvedVaultPath --vault-password-file $vaultPasswordScript
        if ($LASTEXITCODE -ne 0) {
            throw "ansible-vault edit failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if ($null -eq $previousTmpDir) {
            Remove-Item Env:TMPDIR -ErrorAction SilentlyContinue
        }
        else {
            $env:TMPDIR = $previousTmpDir
        }
    }
}

function Resolve-VaultPath([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "No vault name specified."
    }

    $vaultFiles = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter "vault.yml" -ErrorAction SilentlyContinue |
        Sort-Object FullName
    )

    $matches = @($vaultFiles | Where-Object { $_.Directory.Name -eq $Name })
    if ($matches.Count -eq 1) {
        return $matches[0].FullName
    }
    if ($matches.Count -gt 1) {
        $paths = ($matches | ForEach-Object {
                [System.IO.Path]::GetRelativePath($PSScriptRoot, $_.FullName)
            }) -join "`n  "
        throw "Vault name '$Name' is ambiguous. Use one of these paths:`n  $paths"
    }

    # Also accept a repository-relative or absolute path when a parent name is
    # ambiguous or when the caller already knows the path.
    $candidatePath = if ([System.IO.Path]::IsPathRooted($Name)) {
        $Name
    }
    else {
        Join-Path $PSScriptRoot $Name
    }

    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $resolvedPath = (Resolve-Path -LiteralPath $candidatePath).Path
        if ([System.IO.Path]::GetFileName($resolvedPath) -ne "vault.yml") {
            throw "Not a vault file: $Name (expected a file named vault.yml)"
        }

        $relativePath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $resolvedPath)
        $parentPrefix = "..$([System.IO.Path]::DirectorySeparatorChar)"
        if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -eq ".." -or $relativePath.StartsWith($parentPrefix)) {
            throw "Vault file must be inside the repository: $Name"
        }

        return $resolvedPath
    }

    $availableNames = ($vaultFiles | ForEach-Object { $_.Directory.Name } | Select-Object -Unique) -join ", "
    throw "Unknown vault '$Name'. Available vaults: $availableNames"
}

function Ensure-ActiveVaultPassword {
    & $vaultPasswordScript | Out-Null
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH. Run this script inside the dev container."
    }
}

Main

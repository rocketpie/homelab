#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
    [Parameter(ParameterSetName = "Help")]
    [switch]$Help,

    [Parameter(ParameterSetName = "InstallApt")]
    [switch]$InstallApt,

    [Parameter(ParameterSetName = "InstallVenv")]
    [switch]$InstallVenv,

    [Parameter(ParameterSetName = "InstallVault")]
    [switch]$InstallVault,

    [Parameter(ParameterSetName = "InstallVault")]
    [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Targets {
    Write-Host "Targets:"
    Write-Host "  -Help                  Show this help (default)"
    Write-Host "  -InstallApt            apt install python3.10-venv python3-pip sshpass; pip install uv"
    Write-Host "  -InstallVenv           Create venv; install requirements via uv; create .collections; install community.general"
    Write-Host "  -InstallVault          Create missing local vault.yml files from checked-in # vault.yml: template comments"
}

Set-Variable -Scope Script -Name 'vEnvPath' -Value (Join-Path $PSScriptRoot ".venv")
Set-Variable -Scope Script -Name 'vEnvPython' -Value (Join-Path $vEnvPath "bin/python")
Set-Variable -Scope Script -Name 'vEnvPip' -Value (Join-Path $vEnvPath "bin/pip")
Set-Variable -Scope Script -Name 'vEnvAnsiblePlaybook' -Value (Join-Path $vEnvPath "bin/ansible-playbook")
Set-Variable -Scope Script -Name 'vEnvAnsibleGalaxy' -Value (Join-Path $vEnvPath "bin/ansible-galaxy")
Set-Variable -Scope Script -Name 'vEnvRequirements' -Value (Join-Path $PSScriptRoot "venv-requirements.txt")
Set-Variable -Scope Script -Name 'ansibleCollectionsDir' -Value (Join-Path $PSScriptRoot ".collections")
Set-Variable -Scope Script -Name 'collectionsRequirements' -Value (Join-Path $PSScriptRoot "collection-requirements.txt")
Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")
Set-Variable -Scope Script -Name 'initializeVaultTemplatesScript' -Value (Join-Path $PSScriptRoot "srv/Initialize-VaultTemplates.ps1")

$localCollections = $(Join-Path $PSScriptRoot ".collections")
if (!"$($env:ANSIBLE_COLLECTIONS_PATH)".Contains($localCollections)) {
    $env:ANSIBLE_COLLECTIONS_PATH = "$($localCollections):$($env:ANSIBLE_COLLECTIONS_PATH)"
}

function Main {
    switch ($PSCmdlet.ParameterSetName) {
        default {
            Write-Targets
        }
        "Help" {
            Write-Targets
        }

        "InstallApt" {
            Install-AptDeps
            Install-UvGlobal
        }
        "InstallVenv" {
            Require-Command "uv"
            Install-Venv
        }
        "InstallVault" {
            Install-VaultTemplates -RepoRoot $RepoRoot
        }
    }

    "Done."
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

function Ensure-vEnvRequirements {
    if (-not (Test-Path $vEnvRequirements)) {
        throw "Missing $vEnvRequirements (expected dev requirements)."
    }
}

function Ensure-ToolsInVenv {
    if (-not (Test-Path $vEnvAnsiblePlaybook)) {
        throw "ansible-playbook not found in venv. Did you run -InstallVenv?"
    }
}

# TODO: read from apt-requirements.txt
function Install-AptDeps {
    Require-Command "sudo"
    Require-Command "apt-get"
    Write-Host "apt-get install -y python3.10-venv python3-pip sshpass xorriso..."
    & sudo apt-get update
    & sudo apt-get install -y python3.10-venv python3-pip sshpass xorriso
}

function Install-UvGlobal {
    Require-Command "python3"
    Require-Command "pip3"

    Write-Host "installing uv using pip (https://docs.astral.sh/uv/)..."
    pip3 install uv

    Write-Host "adding uv to PATH (python3 -m uv tool update-shell)..."
    python3 -m uv tool update-shell

    Write-Host "uv installed globally. restart your shell for PATH changes to take effect."
}

function Install-Venv {
    Ensure-Venv
    Ensure-vEnvRequirements
    Require-Command "uv"

    Write-Host "Installing Python requirements into venv using uv..."
    uv pip install --python $vEnvPython -r $vEnvRequirements

    Write-Host "Ensuring collections directory: $ansibleCollectionsDir"
    New-Item -ItemType Directory -Force -Path $ansibleCollectionsDir | Out-Null

    $requirements = @(get-content $collectionsRequirements)
    foreach ($requirement in $requirements) {
        Write-Host "Installing Ansible collection $($requirement)..."
        & $vEnvAnsibleGalaxy collection install -p $ansibleCollectionsDir $requirement
    }
}

function Install-VaultTemplates([string]$RepoRoot) {
    if (-not (Test-Path -LiteralPath $initializeVaultTemplatesScript)) {
        throw "Missing $initializeVaultTemplatesScript."
    }

    & $initializeVaultTemplatesScript -RepoRoot $RepoRoot
}


Main

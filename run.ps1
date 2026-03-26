#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
    [Parameter(ParameterSetName = "Help")]
    [switch]$Help,

    [Parameter(ParameterSetName = "Run", Position = 1)]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $playbooksPath = Join-Path $PSScriptRoot "playbooks"
            if (-not (Test-Path $playbooksPath)) { return }

            Get-ChildItem -Path $playbooksPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".yml", ".yaml" } |
            ForEach-Object { $_.Name } |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
        })]
    [string]$Playbook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Variable -Scope Script -Name 'vEnvPath' -Value (Join-Path $PSScriptRoot ".venv")
Set-Variable -Scope Script -Name 'vEnvPython' -Value (Join-Path $vEnvPath "bin/python")
Set-Variable -Scope Script -Name 'vEnvAnsiblePlaybook' -Value (Join-Path $vEnvPath "bin/ansible-playbook")
Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")

function Main([string]$PlaybookName) {
    Ensure-Venv
    Ensure-ToolsInVenv

    $inventory = Join-Path $PSScriptRoot "inventory/hosts.yml"
    if (-not (Test-Path $inventory)) {
        throw "Inventory not found: $inventory"
    }

    $playbookPath = Join-Path $PSScriptRoot ("playbooks/{0}" -f $PlaybookName)
    if (-not (Test-Path $playbookPath)) {
        throw "Playbook not found: $playbookPath"
    }

    $vaultPassword = $env:ANSIBLE_VAULT_PASSWORD
    if ([string]::IsNullOrWhiteSpace($vaultPassword)) {
        $vaultPassword = Read-Host -Prompt "Ansible Vault password?"
        $env:ANSIBLE_VAULT_PASSWORD = $vaultPassword
    }

    Write-Host "Running: $playbookPath (inventory: $inventory)"
    if ($PSBoundParameters['Debug']) {
        & $vEnvAnsiblePlaybook -i $inventory $playbookPath -v --vault-password-file $vaultPasswordScript
    }
    else {
        & $vEnvAnsiblePlaybook -i $inventory $playbookPath --vault-password-file $vaultPasswordScript
    }
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
}

Main -PlaybookName $Playbook

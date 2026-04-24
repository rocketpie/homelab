#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$Limit = 'restic_server'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Join-Path $PSScriptRoot '../..'
$ansible = Join-Path $repoRoot '.venv/bin/ansible'
$vaultPasswordScript = Join-Path $repoRoot 'vault_pass.ps1'

if (-not (Test-Path -LiteralPath $ansible)) {
    throw "Missing .venv/bin/ansible. Run this from the repo's WSL workflow."
}

if ([string]::IsNullOrWhiteSpace($env:ANSIBLE_VAULT_PASSWORD)) {
    $vaultPassword = Read-Host -Prompt 'Ansible Vault password?' -AsSecureString
    $env:ANSIBLE_VAULT_PASSWORD = [pscredential]::new('dummy', $vaultPassword).GetNetworkCredential().Password
}

& $ansible $Limit '-i' 'inventory/hosts.yml' '--vault-password-file' $vaultPasswordScript '-b' '-m' 'slurp' '-a' 'src=/etc/restic-client/restic-client.json'

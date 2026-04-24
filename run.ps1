#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
    [Parameter(ParameterSetName = "Help")]
    [switch]$Help,

    [Parameter(ParameterSetName = "Run", Position = 0)]
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
    [string]$Playbook,

    [Parameter(ParameterSetName = "Run", ValueFromRemainingArguments = $true)]
    [string[]]$AnsibleArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Variable -Scope Script -Name 'vEnvPath' -Value (Join-Path $PSScriptRoot ".venv")
Set-Variable -Scope Script -Name 'vEnvPython' -Value (Join-Path $vEnvPath "bin/python")
Set-Variable -Scope Script -Name 'vEnvAnsiblePlaybook' -Value (Join-Path $vEnvPath "bin/ansible-playbook")
Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")
Set-Variable -Scope Script -Name 'defaultAnsibleSshKeyPath' -Value (Join-Path $HOME ".ssh/ansible")

$localCollections = $(Join-Path $PSScriptRoot ".collections")
if (!"$($env:ANSIBLE_COLLECTIONS_PATH)".Contains($localCollections)) {
    $env:ANSIBLE_COLLECTIONS_PATH = "$($localCollections):$($env:ANSIBLE_COLLECTIONS_PATH)"
}

function Main([string]$PlaybookName) {
    Ensure-Venv
    Ensure-ToolsInVenv
    Ensure-AnsibleSshKeyLoaded

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
        $vaultPassword = Read-Host -Prompt "Ansible Vault password?" -AsSecureString
        $env:ANSIBLE_VAULT_PASSWORD = [pscredential]::new('dummy', $vaultPassword).GetNetworkCredential().Password
    }

    Write-Host "Running: $playbookPath (inventory: $inventory)"
    if ($PSBoundParameters['Debug']) {
        & $vEnvAnsiblePlaybook -i $inventory $playbookPath -v @AnsibleArgs --vault-password-file $vaultPasswordScript
    }
    else {
        & $vEnvAnsiblePlaybook -i $inventory $playbookPath @AnsibleArgs --vault-password-file $vaultPasswordScript
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

function Ensure-AnsibleSshKeyLoaded {
    if (-not (Test-Path $defaultAnsibleSshKeyPath)) {
        return
    }

    if (-not (Get-Command "ssh-agent" -ErrorAction SilentlyContinue)) {
        return
    }

    if (-not (Get-Command "ssh-add" -ErrorAction SilentlyContinue)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($env:SSH_AUTH_SOCK)) {
        Start-SshAgent
    }

    if (Test-SshAgentHasKey -PrivateKeyPath $defaultAnsibleSshKeyPath) {
        Write-Host "SSH key already loaded in ssh-agent: $defaultAnsibleSshKeyPath"
        return
    }

    try {
        & ssh-add $defaultAnsibleSshKeyPath | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Ensured SSH key is loaded in ssh-agent: $defaultAnsibleSshKeyPath"
        }
        else {
            Write-Warning "ssh-add could not load the Ansible SSH key. Continuing without ssh-agent bootstrap."
        }
    }
    catch {
        Write-Warning "Could not preload SSH key with ssh-add. Continuing without ssh-agent bootstrap."
    }
}

function Test-SshAgentHasKey([string]$PrivateKeyPath) {
    $publicKeyPath = "{0}.pub" -f $PrivateKeyPath
    if (-not (Test-Path $publicKeyPath)) {
        return $false
    }

    if (-not (Get-Command "ssh-keygen" -ErrorAction SilentlyContinue)) {
        return $false
    }

    $loadedKeys = & ssh-add -l 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $fingerprintOutput = & ssh-keygen -lf $publicKeyPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $keyFingerprint = (($fingerprintOutput | Select-Object -First 1) -split '\s+')[1]
    if ([string]::IsNullOrWhiteSpace($keyFingerprint)) {
        return $false
    }

    return [bool]($loadedKeys | Where-Object { $_ -match [regex]::Escape($keyFingerprint) })
}

function Start-SshAgent {
    $agentOutput = & ssh-agent -s 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not start ssh-agent automatically. Continuing without ssh-agent bootstrap."
        return
    }

    foreach ($line in $agentOutput) {
        if ($line -match '^(SSH_AUTH_SOCK|SSH_AGENT_PID)=([^;]+);') {
            Set-Item -Path ("Env:{0}" -f $matches[1]) -Value $matches[2]
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:SSH_AUTH_SOCK)) {
        Write-Warning "ssh-agent started but SSH_AUTH_SOCK was not exported into this session."
        return
    }

    Write-Host "Started ssh-agent for this PowerShell session."
}

Main -PlaybookName $Playbook

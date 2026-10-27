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

Set-Variable -Scope Script -Name 'activeEnvironmentStatePath' -Value (Join-Path $HOME ".homelab-active/homelab-environment.json")

$debugEnabled = $PSBoundParameters.ContainsKey('Debug')

function Write-Help {
    Write-Host "Usage:"
    Write-Host "  pwsh run.ps1 <playbook> [-Debug]"
    Write-Host "  pwsh run.ps1 -Help"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  <playbook>             Playbook file from playbooks/, e.g. add-vm.yml (tab-completion lists them)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Help                  Show this help (default)"
    Write-Host "  -Debug                 Run ansible-playbook with -v"
    Write-Host ""
    Write-Host "This is a convenience wrapper around ansible-playbook. For the current pwsh session it:"
    Write-Host "  - accepts tab-completion for playbook names"
    Write-Host "  - requires an active environment published by Set-Environment.ps1"
    Write-Host "  - uses the host ssh-agent socket, the tmpfs vault password, and the"
    Write-Host "    environment's Ansible public key from ~/.homelab-active/"
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

        "Run" {
            Invoke-Playbook -PlaybookName $Playbook
        }
    }
}

function Get-ActiveEnvironmentState {
    if (-not (Test-Path -LiteralPath $activeEnvironmentStatePath)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $activeEnvironmentStatePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw | ConvertFrom-Json
}

function Resolve-HomePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ($Path.StartsWith("~")) {
        return Join-Path $HOME $Path.Substring(1).TrimStart("/", "\")
    }
    return $Path
}

function Get-ActiveRuntimePath($State, [string]$ContainerProperty, [string]$HostProperty) {
    $containerPath = Resolve-HomePath $State.$ContainerProperty
    if (-not [string]::IsNullOrWhiteSpace($containerPath) -and (Test-Path -LiteralPath $containerPath)) {
        return $containerPath
    }

    # TODO: this is part of the legacy runtime, which is not supported anymore. 
    $hostPath = $State.$HostProperty
    if (-not [string]::IsNullOrWhiteSpace($hostPath) -and (Test-Path -LiteralPath $hostPath)) {
        return $hostPath
    }

    return $containerPath
}

function Use-ActiveEnvironment($State) {
    $socketPath = Get-ActiveRuntimePath $State "sshAgentSocket" "hostSshAgentSocket"
    if ([string]::IsNullOrWhiteSpace($socketPath) -or -not (Test-Path -LiteralPath $socketPath)) {
        throw "Active environment '$($State.environment)' SSH agent socket not found. Run Set-Environment.ps1 on the container host."
    }

    $env:SSH_AUTH_SOCK = $socketPath
    Remove-Item Env:SSH_AGENT_PID -ErrorAction SilentlyContinue

    if (Get-Command "ssh-add" -ErrorAction SilentlyContinue) {
        & ssh-add -l 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Active environment '$($State.environment)' SSH agent has no key loaded. Run Set-Environment.ps1 on the container host."
        }
    }
}

function Invoke-Playbook([string]$PlaybookName) {
    Require-Command "ansible-playbook"

    $activeEnvironment = Get-ActiveEnvironmentState
    if ($null -eq $activeEnvironment) {
        throw "No active environment. Run Set-Environment.ps1 on the container host."
    }
    Use-ActiveEnvironment $activeEnvironment

    $inventory = Join-Path $PSScriptRoot "inventory/hosts.yml"
    if (-not (Test-Path $inventory)) {
        throw "Inventory not found: $inventory"
    }

    $playbookPath = Join-Path $PSScriptRoot ("playbooks/{0}" -f $PlaybookName)
    if (-not (Test-Path $playbookPath)) {
        throw "Playbook not found: $playbookPath"
    }

    $ansibleArgs = @("-i", $inventory, $playbookPath)
    $activeVaultPasswordFile = Get-ActiveRuntimePath $activeEnvironment "vaultPasswordFile" "hostVaultPasswordFile"
    if (-not [string]::IsNullOrWhiteSpace($activeVaultPasswordFile)) {
        if (-not (Test-Path -LiteralPath $activeVaultPasswordFile)) {
            throw "Active environment vault password file not found. Run Set-Environment.ps1 on the container host."
        }
        $ansibleArgs += @("--vault-password-file", $activeVaultPasswordFile)
    }

    # The active environment is the only key source. 
    # Ansible uses the active agent and public key instead. 
    # Pass the values as JSON so the spaces in a public key survive Ansible's extra-vars parser.
    $extraVars = [ordered]@{    }
    if (-not [string]::IsNullOrWhiteSpace($activeEnvironment.sshPublicKey)) {
        $extraVars['ansible_admin_ssh_public_key'] = $activeEnvironment.sshPublicKey
    }
    $ansibleArgs += @("--extra-vars", ($extraVars | ConvertTo-Json -Compress))

    if ($debugEnabled) {
        Write-Host "Debug enabled: forwarding -v to ansible-playbook"
        $ansibleArgs += "-v"
    }

    Write-Host "Running: $playbookPath (inventory: $inventory)"
    & ansible-playbook @ansibleArgs
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH. Run this script inside the dev container."
    }
}

Main

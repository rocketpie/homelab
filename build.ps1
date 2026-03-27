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

$localCollections = $(Join-Path $PSScriptRoot ".collections")
if (!"$($env:ANSIBLE_COLLECTIONS_PATH)".Contains($localCollections)) {
    $env:ANSIBLE_COLLECTIONS_PATH = "$($localCollections):$($env:ANSIBLE_COLLECTIONS_PATH)"
}

function Main {
    Ensure-Venv
    Ensure-ToolsInVenv

    $ansibleLint = Join-Path $vEnvPath "bin/ansible-lint"

    if (-not (Test-Path $ansibleLint)) { throw "ansible-lint not found in venv. Ensure it's in $vEnvRequirements and run -InstallVenv." }

    Write-Host "Running ansible-lint..."
    & $ansibleLint $PSScriptRoot
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


Main
#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$Limit = 'restic_server'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Join-Path $PSScriptRoot '../..'
$runScript = Join-Path $repoRoot 'run.ps1'

Write-Host "Running playbooks/test-restic-server.yml for inventory consistency warnings..."
& $runScript 'test-restic-server.yml' '--limit' $Limit

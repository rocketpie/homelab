#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$Limit = 'restic_server',
    [string]$RepositoryName = 'restic-server-test-repo1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Join-Path $PSScriptRoot '../..'
$runScript = Join-Path $repoRoot 'run.ps1'
$extraVars = "test_restic_server_run_repository_probe=true test_restic_server_probe_repository_name=$RepositoryName"

Write-Host "Running optional repository probe for $RepositoryName..."
& $runScript 'test-restic-server.yml' '--limit' $Limit '--extra-vars' $extraVars

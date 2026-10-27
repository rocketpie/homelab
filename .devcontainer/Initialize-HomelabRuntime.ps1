#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
Prepares the host-side runtime directory used to hand the active environment's
vault password, SSH agent socket, and published state into the dev container.

.DESCRIPTION
This script is wired as the dev container's initializeCommand, so it runs on
the container host before the container starts.

It guarantees that the runtime directory:

  - exists before Docker creates the container mount;
  - is memory-backed (tmpfs), so the active vault password is not persisted to
    a normal disk directory;
  - has restrictive permissions (0700);
  - is supported by the host, by failing closed on non-Linux or non-tmpfs
    hosts.

Without this pre-flight, Docker could fail on a missing bind source, or the
workflow could silently use a persistent disk directory and keep the active
vault password there.

The runtime directory contains two subtrees:

  control/        host-only state, lock, PID, and rollback data
  homelab-active/ container-visible vault_pass, active.sock, and published state

The dev container mounts only homelab-active/ at ~/.homelab-active.
Set-Environment.ps1 publishes vault_pass, active.sock, and homelab-environment.json there.
run.ps1 consumes them inside the container.
Because the directory lives on tmpfs, a host reboot clears it. 

This script recreates the empty directories at the next container start.
Then, Set-Environment.ps1 must be re-run to republish the password and agent.

.NOTES
Run this on the host, not inside the dev container.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsLinux) {
    throw "The active environment runtime directory requires a Linux container host (eg. WSL) with tmpfs under /dev/shm."
}

$runtimeRoot = if ([string]::IsNullOrWhiteSpace($env:HOMELAB_RUNTIME_ROOT)) {
    "/dev/shm/homelab"
}
else {
    $env:HOMELAB_RUNTIME_ROOT
}

$controlDir = Join-Path $runtimeRoot "control"
$runtimeDir = Join-Path $runtimeRoot "homelab-active"

foreach ($directory in @($runtimeRoot, $controlDir, $runtimeDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    & chmod 700 $directory
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set permissions on '$directory'."
    }
}

$fileSystemType = (& stat -f -c %T $runtimeRoot).Trim()
if ($fileSystemType -ne "tmpfs") {
    throw "Runtime directory '$runtimeRoot' is not tmpfs (detected '$fileSystemType')."
}

#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
Prepares the host-side runtime directory used to hand the active environment's
vault password and SSH agent socket into the dev container.

.DESCRIPTION
This script is wired as the dev container's initializeCommand, so it runs on
the WSL/Linux host before the container starts.

It guarantees that the bind-mount source:

  - exists before Docker creates the container mount;
  - is memory-backed (tmpfs), so the active vault password is not persisted to
    a normal disk directory;
  - has restrictive permissions (0700);
  - is supported by the host, by failing closed on non-Linux or non-tmpfs
    hosts.

Without this pre-flight, Docker could fail on a missing bind source, or the
workflow could silently use a persistent disk directory and keep the active
vault password there.

The dev container mounts this directory at ~/.homelab-active.
Set-Environment.ps1 publishes vault_pass and active.sock there.
run.ps1 consumes them inside the container.
Because the directory lives on tmpfs, a host reboot clears it. 

This script recreates the empty directory at the next
container start, but Set-Environment.ps1 must be re-run to republish the
password and agent.

.NOTES
Run this on the host, not inside the dev container.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsLinux) {
    throw "The active environment runtime directory requires a Linux/WSL host (tmpfs under /dev/shm)."
}

$runtimeDir = "/dev/shm/homelab-active"
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
& chmod 700 $runtimeDir
if ($LASTEXITCODE -ne 0) {
    throw "Could not set permissions on '$runtimeDir'."
}

$fileSystemType = (& stat -f -c %T $runtimeDir).Trim()
if ($fileSystemType -ne "tmpfs") {
    throw "Runtime directory '$runtimeDir' is not tmpfs (detected '$fileSystemType')."
}

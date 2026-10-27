#!/usr/bin/env pwsh
#Requires -Version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$inventory = Join-Path $repoRoot "inventory/hosts.yml"
$playbook = Join-Path $repoRoot "playbooks/add-public-gateway.yml"

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }

    Write-Host "[ok] $Name"
}

function Assert-Path([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing path: $Path"
    }

    Write-Host "[ok] $Path"
}

function Assert-NoLegacyAnsibleKeyMaterial {
    $inventoryRoot = Join-Path $repoRoot "inventory"
    $pattern = '\.ssh/(ansible|id_ed25519)|ssh-(ed25519|rsa)\s+\S+\s+ansible(\s|"|$)'
    $hits = @(
        Get-ChildItem -LiteralPath $inventoryRoot -Recurse -File |
        Select-String -Pattern $pattern
    )
    if ($hits.Count -gt 0) {
        $details = ($hits | ForEach-Object {
                "$($_.Path):$($_.LineNumber): $($_.Line.Trim())"
            }) -join "`n"
        throw "Inventory contains legacy Ansible key material:`n$details"
    }

    Write-Host "[ok] inventory has no legacy Ansible key material"
}

Assert-Command "ansible-playbook"
Assert-Command "ansible-lint"
Assert-Command "ansible-vault"
Assert-Command "sshpass"
Assert-Command "xorriso"

Assert-NoLegacyAnsibleKeyMaterial

Write-Host "[ok] $(& ansible-playbook --version | Select-Object -First 1)"

$collectionsPath = $env:ANSIBLE_COLLECTIONS_PATH
if ([string]::IsNullOrWhiteSpace($collectionsPath)) {
    throw "ANSIBLE_COLLECTIONS_PATH is not set."
}

foreach ($collection in @("community/general", "community/proxmox", "ansible/posix")) {
    Assert-Path (Join-Path $collectionsPath "ansible_collections/$collection")
}

$python = $env:ANSIBLE_PYTHON
if ([string]::IsNullOrWhiteSpace($python)) {
    throw "ANSIBLE_PYTHON is not set."
}

if (-not (Test-Path -LiteralPath $python)) {
    throw "ANSIBLE_PYTHON does not exist: $python"
}

& $python -c "import yaml; print('PyYAML available')"
if ($LASTEXITCODE -ne 0) {
    throw "Python at $python cannot import yaml."
}

Assert-Path $inventory
Assert-Path $playbook

& ansible-inventory -i $inventory --graph | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "ansible-inventory failed for $inventory"
}
Write-Host "[ok] inventory parses"

& ansible-playbook -i $inventory $playbook --syntax-check | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "ansible-playbook --syntax-check failed for $playbook"
}
Write-Host "[ok] add-public-gateway.yml syntax"

Write-Host "devcontainer verification passed"

#!/usr/bin/env pwsh
#Requires -Version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$inventory = Join-Path $repoRoot "inventory/hosts.yml"
$playbook = Join-Path $repoRoot "playbooks/add-public-gateway.yml"

function Assert-Path([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing path: $Path"
    }

    Write-Host "[ok] $Path"
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }

    Write-Host "[ok] $Name"
}

function Get-InventoryGroupHostNames($Group) {
    if ($null -eq $Group -or $null -eq $Group.hosts) {
        return @()
    }

    # ansible-inventory has emitted both an object keyed by host name and a
    # plain list of host names across ansible-core versions.
    if ($Group.hosts -is [System.Management.Automation.PSCustomObject]) {
        return @($Group.hosts.PSObject.Properties.Name)
    }

    return @($Group.hosts)
}

Assert-Command "ansible-inventory"
Assert-Command "ansible-playbook"
Assert-Command "ansible-lint"

Assert-Path $playbook
Assert-Path $inventory

foreach ($role in @("add_firewall", "add_vpn_gateway", "add_website")) {
    Assert-Path (Join-Path $repoRoot "playbooks/roles/$role/tasks/main.yml")
}

$inventoryJson = & ansible-inventory -i $inventory --list | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "ansible-inventory failed for $inventory."
}

$vpnGatewayHosts = Get-InventoryGroupHostNames $inventoryJson.vpn_gateway
$websiteHosts = Get-InventoryGroupHostNames $inventoryJson.website

$vserverHostNames = @(($vpnGatewayHosts + $websiteHosts) | Select-Object -Unique)
if ($vserverHostNames.Count -eq 0) {
    throw "No hosts found in the vpn_gateway or website inventory groups."
}

$allRouteHostnames = @()
$websiteDomains = @()

foreach ($hostName in $vserverHostNames) {
    $inGateway = $vpnGatewayHosts -contains $hostName
    $inWebsite = $websiteHosts -contains $hostName

    if (-not $inGateway -and -not $inWebsite) {
        continue
    }

    Write-Host "[ok] vserver inventory host: $hostName"

    $hostVarsPath = Join-Path $repoRoot "inventory/host_vars/$hostName/host.yml"
    Assert-Path $hostVarsPath

    $hostVarsContent = Get-Content -LiteralPath $hostVarsPath -Raw

    $placeholderPattern = 'example\.com|vpn\.example\.com|admin@example\.com'
    if ($hostVarsContent -match $placeholderPattern) {
        throw "Replace the example domains in $hostVarsPath before running the playbook."
    }

    $forbiddenKeys = @(
        "vmid",
        "proxmox_node",
        "proxmox_iso_filename",
        "host_users",
        "extra_disks"
    )

    foreach ($key in $forbiddenKeys) {
        if ($hostVarsContent -match "(?m)^\s*$([regex]::Escape($key))\s*:") {
            throw "Public gateway host vars must not contain '$key'."
        }
    }

    $hostVarsJson = & ansible-inventory -i $inventory --host $hostName | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "ansible-inventory --host failed for $hostName."
    }

    if ($inGateway) {
        if ($hostVarsContent -notmatch "(?m)^\s*add_vpn_gateway_acme_email\s*:") {
            throw "Missing required host var: add_vpn_gateway_acme_email"
        }
        if ($hostVarsContent -notmatch "(?m)^\s*add_vpn_gateway_routes\s*:") {
            throw "Missing required host var: add_vpn_gateway_routes"
        }
        if ($hostVarsContent -notmatch '(?m)^# vault\.yml:\s*$') {
            throw "Missing '# vault.yml:' template marker in $hostVarsPath"
        }
        if ($hostVarsContent -notmatch 'add_vpn_gateway_wg_easy_init_password') {
            throw "Missing add_vpn_gateway_wg_easy_init_password vault template entry"
        }

        $routes = @($hostVarsJson.add_vpn_gateway_routes)
        if ($routes.Count -eq 0) {
            throw "$hostName has no add_vpn_gateway_routes."
        }

        foreach ($route in $routes) {
            $hostnames = @($route.hostnames)
            if ($hostnames.Count -eq 0) {
                throw "A gateway route on $hostName is missing hostnames."
            }
            if ([string]::IsNullOrWhiteSpace($route.upstream)) {
                throw "A gateway route on $hostName is missing an upstream."
            }
            $allRouteHostnames += $hostnames
        }

        Write-Host "[ok] $hostName gateway routes and vault marker"
    }

    if ($inWebsite) {
        if ($hostVarsContent -notmatch "(?m)^\s*add_website_domain\s*:") {
            throw "Missing required host var: add_website_domain"
        }

        $websiteDomain = $hostVarsJson.add_website_domain
        if ([string]::IsNullOrWhiteSpace($websiteDomain)) {
            throw "$hostName has an empty add_website_domain."
        }

        $websiteDomains += $websiteDomain
        Write-Host "[ok] $hostName website domain: $websiteDomain"
    }
}

$uniqueRouteHostnames = @($allRouteHostnames | Select-Object -Unique)
if ($uniqueRouteHostnames.Count -ne $allRouteHostnames.Count) {
    throw "Gateway route hostnames must be unique across all gateway hosts."
}

foreach ($websiteDomain in $websiteDomains) {
    if ($uniqueRouteHostnames -notcontains $websiteDomain) {
        throw "Website domain '$websiteDomain' is not present in any add_vpn_gateway_routes."
    }
}

Write-Host "[ok] gateway routes cover all website domains"

$playbookContent = Get-Content -LiteralPath $playbook -Raw
if ($playbookContent -match 'add_proxmox_vm|export_autoinstall_seed|proxmox_api') {
    throw "add-public-gateway.yml must not depend on the Proxmox/PXE workflow."
}
Write-Host "[ok] playbook is standalone"

& ansible-playbook -i $inventory $playbook --syntax-check | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "add-public-gateway.yml syntax check failed."
}
Write-Host "[ok] playbook syntax"

$lintTargets = @(
    $playbook,
    (Join-Path $repoRoot "playbooks/roles/add_firewall"),
    (Join-Path $repoRoot "playbooks/roles/add_vpn_gateway"),
    (Join-Path $repoRoot "playbooks/roles/add_website"),
    (Join-Path $repoRoot "playbooks/roles/add_docker")
)

& ansible-lint @lintTargets
if ($LASTEXITCODE -ne 0) {
    throw "ansible-lint failed for the public gateway playbook and roles."
}
Write-Host "[ok] ansible-lint"

Write-Host "public gateway configuration verification passed"

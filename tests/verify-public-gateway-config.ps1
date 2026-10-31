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

$activeVaultPasswordPath = Join-Path $HOME ".homelab-active/vault_pass"
if (-not (Test-Path -LiteralPath $activeVaultPasswordPath)) {
    throw "No active environment. Run Set-Environment.ps1 on the container host."
}
$env:ANSIBLE_VAULT_PASSWORD_FILE = $activeVaultPasswordPath

Assert-Path $playbook
Assert-Path $inventory

foreach ($role in @("add_caddy", "add_firewall", "add_vpn_gateway", "add_website")) {
    Assert-Path (Join-Path $repoRoot "playbooks/roles/$role/tasks/main.yml")
}

if (Test-Path -LiteralPath (Join-Path $repoRoot "playbooks/roles/add_lobby")) {
    throw "add_lobby must be removed; lobby is a published public workload."
}
Write-Host "[ok] add_lobby is removed"

foreach ($template in @(
        "docker-compose.yml.j2",
        "public-deploy.sh.j2",
        "public-deploy.cron.j2",
        "public-deploy.logrotate.j2"
    )) {
    Assert-Path (Join-Path $repoRoot "playbooks/roles/add_website/templates/$template")
}

$inventoryJson = & ansible-inventory -i $inventory --list | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "ansible-inventory failed for $inventory."
}

$vpnGatewayHosts = @(Get-InventoryGroupHostNames $inventoryJson.vpn_gateway)
$websiteHosts = @(Get-InventoryGroupHostNames $inventoryJson.website)

# Co-hosting is allowed: a host may be in both groups. Do not assert they are
# disjoint, and keep the union as the set of public/Caddy hosts.
$vserverHostNames = @(($vpnGatewayHosts + $websiteHosts) | Select-Object -Unique)
if ($vserverHostNames.Count -eq 0) {
    throw "No hosts found in the vpn_gateway or website inventory groups."
}

$allRouteHostnames = @()

foreach ($hostName in $vserverHostNames) {
    $inGateway = $vpnGatewayHosts -contains $hostName
    $inWebsite = $websiteHosts -contains $hostName

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

    foreach ($key in @("add_firewall_allowed_tcp_ports", "add_firewall_allowed_udp_ports")) {
        if ($hostVarsContent -notmatch "(?m)^\s*$([regex]::Escape($key))\s*:") {
            throw "Missing host firewall var on $hostName`: $key"
        }
    }

    $tcpPorts = @($hostVarsJson.add_firewall_allowed_tcp_ports)
    if ($tcpPorts -notcontains 80 -or $tcpPorts -notcontains 443) {
        throw "$hostName must allow TCP 80 and 443."
    }

    $udpPorts = @($hostVarsJson.add_firewall_allowed_udp_ports)
    if ($udpPorts -notcontains 443) {
        throw "$hostName must allow UDP 443 for Caddy HTTP/3."
    }

    Write-Host "[ok] $hostName host firewall exposure"

    # Every public host terminates TLS through add_caddy.
    if ($hostVarsContent -notmatch "(?m)^\s*add_caddy_acme_email\s*:") {
        throw "Missing required host var on $hostName`: add_caddy_acme_email"
    }
    if ($hostVarsContent -notmatch "(?m)^\s*add_caddy_routes\s*:") {
        throw "Missing required host var on $hostName`: add_caddy_routes"
    }

    $routes = @($hostVarsJson.add_caddy_routes)
    if ($routes.Count -eq 0) {
        throw "$hostName has no add_caddy_routes."
    }

    foreach ($route in $routes) {
        $hostnames = @($route.hostnames)
        if ($hostnames.Count -eq 0) {
            throw "A caddy route on $hostName is missing hostnames."
        }
        if ([string]::IsNullOrWhiteSpace($route.upstream)) {
            throw "A caddy route on $hostName is missing an upstream."
        }
        $allRouteHostnames += $hostnames
    }

    Write-Host "[ok] $hostName caddy routes"

    if ($inGateway) {
        if ($hostVarsContent -notmatch '(?m)^# vault\.yml:\s*$') {
            throw "Missing '# vault.yml:' template marker in $hostVarsPath"
        }
        if ($hostVarsContent -notmatch 'add_vpn_gateway_wg_easy_init_password') {
            throw "Missing add_vpn_gateway_wg_easy_init_password vault template entry"
        }
        if ($hostVarsContent -notmatch "(?m)^\s*add_firewall_wireguard_ports\s*:") {
            throw "Missing host firewall var on $hostName`: add_firewall_wireguard_ports"
        }

        $wireguardPorts = @($hostVarsJson.add_firewall_wireguard_ports)
        if ($wireguardPorts -notcontains 51820) {
            throw "$hostName must allow UDP 51820 for WireGuard."
        }

        Write-Host "[ok] $hostName VPN vault marker and WireGuard port"
    }

    if ($inWebsite) {
        $removedWebsiteKeys = @(
            "add_website_domain",
            "add_website_image",
            "add_website_container_name",
            "add_website_content_dir",
            "add_website_publish_bind",
            "add_website_publish_port",
            "add_website_join_proxy_network",
            "add_website_pull_images",
            "add_website_placeholder_enabled",
            "add_lobby_domain"
        )

        foreach ($key in $removedWebsiteKeys) {
            if ($hostVarsContent -match "(?m)^\s*$([regex]::Escape($key))\s*:") {
                throw "Removed website scalar '$key' is still set on $hostName."
            }
        }

        if ($hostVarsContent -notmatch "(?m)^\s*add_website_services\s*:") {
            throw "Missing required host var on $hostName`: add_website_services"
        }

        $services = @($hostVarsJson.add_website_services)
        if ($services.Count -eq 0) {
            throw "$hostName has an empty add_website_services."
        }
        if (@($services | Select-Object -Unique).Count -ne $services.Count) {
            throw "$hostName has duplicate add_website_services entries."
        }

        foreach ($service in $services) {
            if ($service -notin @("website", "lobby")) {
                throw "Unsupported add_website_services entry on $hostName`: $service"
            }

            $routed = @($routes | Where-Object {
                    [string]$_.upstream -like "${service}:*"
                })
            if ($routed.Count -eq 0) {
                throw "$hostName publishes service '$service' but has no add_caddy_routes upstream starting with '${service}:'."
            }
        }

        Write-Host "[ok] $hostName website services: $($services -join ', ')"
    }

    $removedGatewayKeys = @(
        "add_vpn_gateway_acme_email",
        "add_vpn_gateway_routes",
        "add_vpn_gateway_caddy_"
    )

    foreach ($key in $removedGatewayKeys) {
        if ($hostVarsContent -match "(?m)^\s*$([regex]::Escape($key))") {
            throw "Removed gateway scalar '$key' is still set on $hostName."
        }
    }
}

$uniqueRouteHostnames = @($allRouteHostnames | Select-Object -Unique)
if ($uniqueRouteHostnames.Count -ne $allRouteHostnames.Count) {
    throw "Caddy route hostnames must be unique across all public hosts."
}

Write-Host "[ok] caddy routes cover every selected website service"

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
    (Join-Path $repoRoot "playbooks/roles/add_caddy"),
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

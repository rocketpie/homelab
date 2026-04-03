#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string[]]$DnsName,

    [int]$Days = 825,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$caDir = $PSScriptRoot
$clientDir = Join-Path $caDir "client"
$caKeyPath = Join-Path $caDir "ca.key"
$caCertPath = Join-Path $caDir "ca.crt"
$serialPath = Join-Path $caDir "ca.srl"
$clientKeyPath = Join-Path $clientDir "$Name.key"
$clientCsrPath = Join-Path $clientDir "$Name.csr"
$clientCertPath = Join-Path $clientDir "$Name.crt"
$clientExtPath = Join-Path $clientDir "$Name.ext"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw "Missing dependency: openssl"
}

if (-not (Test-Path $caKeyPath)) {
    throw "Missing ca.key. Run context/homelab-ca/new-ca.ps1 first."
}

if (-not (Test-Path $caCertPath)) {
    throw "Missing ca.crt. Run context/homelab-ca/new-ca.ps1 first."
}

New-Item -ItemType Directory -Path $clientDir -Force | Out-Null

$normalizedDnsNames = @(
    $DnsName |
    ForEach-Object { "$_".Trim() } |
    Where-Object { $_ -ne "" } |
    Select-Object -Unique
)

if ($normalizedDnsNames.Count -eq 0) {
    throw "Provide at least one non-empty -DnsName value."
}

if ((Test-Path $clientKeyPath) -or (Test-Path $clientCertPath)) {
    if (-not $Force) {
        throw "$Name.key or $Name.crt already exists. Re-run with -Force to replace them."
    }
    Remove-Item -LiteralPath $clientKeyPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $clientCsrPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $clientCertPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $clientExtPath -Force -ErrorAction SilentlyContinue
}

$altNames = @()
for ($i = 0; $i -lt $normalizedDnsNames.Count; $i++) {
    $altNames += "DNS.$($i + 1) = $($normalizedDnsNames[$i])"
}

@"
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$($altNames -join [Environment]::NewLine)
"@ | Set-Content -LiteralPath $clientExtPath -NoNewline

& openssl genpkey `
    -algorithm RSA `
    -out $clientKeyPath `
    -pkeyopt rsa_keygen_bits:2048

& openssl req `
    -new `
    -key $clientKeyPath `
    -out $clientCsrPath `
    -subj "/CN=$Name"

& openssl x509 `
    -req `
    -in $clientCsrPath `
    -CA $caCertPath `
    -CAkey $caKeyPath `
    -CAcreateserial `
    -CAserial $serialPath `
    -out $clientCertPath `
    -days $Days `
    -sha256 `
    -extfile $clientExtPath `
    -extensions v3_req

Remove-Item -LiteralPath $clientCsrPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $clientExtPath -Force -ErrorAction SilentlyContinue

Write-Host "Generated:"
Write-Host "  client/$Name.crt"
Write-Host "  client/$Name.key"
Write-Host "DNS SANs:"
$normalizedDnsNames | ForEach-Object { Write-Host "  $_" }

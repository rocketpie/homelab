#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$CommonName = "Homelab Internal CA",
    [int]$Days = 3650,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$caDir = $PSScriptRoot
$clientDir = Join-Path $caDir "client"
$caKeyPath = Join-Path $caDir "ca.key"
$caCertPath = Join-Path $caDir "ca.crt"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw "Missing dependency: openssl"
}

New-Item -ItemType Directory -Path $clientDir -Force | Out-Null

if ((Test-Path $caKeyPath) -or (Test-Path $caCertPath)) {
    if (-not $Force) {
        throw "ca.key or ca.crt already exists. Re-run with -Force to replace them."
    }
    Remove-Item -LiteralPath $caKeyPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $caCertPath -Force -ErrorAction SilentlyContinue
}

& openssl genpkey `
    -algorithm RSA `
    -aes-256-cbc `
    -out $caKeyPath `
    -pkeyopt rsa_keygen_bits:3072

& openssl req `
    -x509 `
    -new `
    -key $caKeyPath `
    -sha256 `
    -days $Days `
    -out $caCertPath `
    -subj "/CN=$CommonName" `
    -addext "basicConstraints=critical,CA:TRUE" `
    -addext "keyUsage=critical,keyCertSign,cRLSign" `
    -addext "subjectKeyIdentifier=hash"

Write-Host "Generated:"
Write-Host "  ca.crt"
Write-Host "  ca.key (passphrase protected)"

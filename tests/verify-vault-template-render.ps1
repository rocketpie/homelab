#!/usr/bin/env pwsh
#Requires -Version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$python = if ($env:ANSIBLE_PYTHON) {
    $env:ANSIBLE_PYTHON
}
elseif (Test-Path (Join-Path $repoRoot ".venv/bin/python")) {
    Join-Path $repoRoot ".venv/bin/python"
}
else {
    "python3"
}
$renderer = Join-Path $repoRoot "srv/render-vault-template.py"

if (-not (Test-Path -LiteralPath $python) -and -not (Get-Command $python -ErrorAction SilentlyContinue)) {
    throw "Python not found. Use the dev container, or activate .venv for the legacy WSL workflow."
}

function Assert-Equal {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Message
    )

    if ($Actual -ceq $Expected) {
        return
    }

    throw "$Message`nExpected:`n$Expected`nActual:`n$Actual"
}

$input = @'
host_user_passwords:
  networker: super-secret

add_vpn_client_config: |
  [Interface]
  PrivateKey = top-secret

  [Peer]
  PublicKey = other-secret

add_restic_server_htpasswd_entries:
  - user: archivar
    password: restic-secret
'@

$expected = @'
host_user_passwords:
  networker: "SECRET_VALUE_HERE"

add_vpn_client_config: |
  SECRET_VALUE_HERE

add_restic_server_htpasswd_entries:
  - user: archivar
    password: "SECRET_VALUE_HERE"
'@

$expected = $expected.TrimEnd("`r", "`n")
$actual = @($input | & $python $renderer) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "Renderer exited with code $LASTEXITCODE"
}

Assert-Equal -Actual $actual -Expected $expected -Message "Vault template renderer should preserve blank lines and block scalar style."

Write-Host "verify-vault-template-render.ps1 passed"

#!/usr/bin/env pwsh
$activeVaultPasswordPath = Join-Path $HOME ".homelab-active/vault_pass"
if (-not (Test-Path -LiteralPath $activeVaultPasswordPath)) {
    throw "No active environment. Run Set-Environment.ps1 on the container host."
}

(Get-Content -LiteralPath $activeVaultPasswordPath -Raw).TrimEnd()
exit 0
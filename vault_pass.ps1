#!/usr/bin/env pwsh
$activeVaultPasswordPaths = @(
    (Join-Path $HOME ".homelab-active/vault_pass"),
    "/dev/shm/homelab-active/vault_pass"
)

foreach ($activeVaultPasswordPath in $activeVaultPasswordPaths) {
    if (Test-Path -LiteralPath $activeVaultPasswordPath) {
        (Get-Content -LiteralPath $activeVaultPasswordPath -Raw).TrimEnd()
        exit 0
    }
}

$env:ANSIBLE_VAULT_PASSWORD

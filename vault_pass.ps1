#!/usr/bin/env pwsh
$runtimeRoot = if ([string]::IsNullOrWhiteSpace($env:HOMELAB_RUNTIME_ROOT)) {
    "/dev/shm/homelab"
}
else {
    $env:HOMELAB_RUNTIME_ROOT
}

$activeVaultPasswordPaths = @(
    (Join-Path $HOME ".homelab-active/vault_pass"),
    (Join-Path $runtimeRoot "homelab-active/vault_pass")
)

foreach ($activeVaultPasswordPath in $activeVaultPasswordPaths) {
    if (Test-Path -LiteralPath $activeVaultPasswordPath) {
        (Get-Content -LiteralPath $activeVaultPasswordPath -Raw).TrimEnd()
        exit 0
    }
}

$env:ANSIBLE_VAULT_PASSWORD

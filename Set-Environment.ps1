#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding(DefaultParameterSetName = "Default")]
param(
    [Parameter(ParameterSetName = "Switch", Mandatory, Position = 0)]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $root = if ([string]::IsNullOrWhiteSpace($env:HOMELAB_ENVIRONMENT_STORE)) {
            Join-Path $HOME ".homelab/environments"
        }
        else {
            $env:HOMELAB_ENVIRONMENT_STORE
        }

        if (-not (Test-Path -LiteralPath $root)) { return }

        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "^[A-Za-z0-9][A-Za-z0-9_-]*$" -and
            $_.Name -like "$wordToComplete*"
        } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
    })]
    [string]$Environment,

    [Parameter(ParameterSetName = "Switch")]
    [switch]$NoSave,

    [switch]$Force,

    [Parameter(ParameterSetName = "Deactivate")]
    [switch]$Deactivate,

    [Parameter(ParameterSetName = "Help")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:EnvRoot = if ([string]::IsNullOrWhiteSpace($env:HOMELAB_ENVIRONMENT_STORE)) {
    Join-Path $HOME ".homelab/environments"
}
else {
    $env:HOMELAB_ENVIRONMENT_STORE
}

$script:RuntimeRoot = if ([string]::IsNullOrWhiteSpace($env:HOMELAB_RUNTIME_ROOT)) {
    "/dev/shm/homelab"
}
else {
    $env:HOMELAB_RUNTIME_ROOT
}

# Host-only control data. This directory is deliberately not mounted into the
# container, so the container cannot rewrite the lock, PID, state, or rollback.
$script:ControlDir = Join-Path $RuntimeRoot "control"

# Container-visible runtime data. It must stay writable so the container can
# connect to the Unix socket and read the vault password.
$script:RuntimeDir = Join-Path $RuntimeRoot "homelab-active"

$repoRoot = $PSScriptRoot
$statePath = Join-Path $ControlDir "active-environment.json"
$publishedStatePath = Join-Path $RuntimeDir "homelab-environment.json"
$lockPath = Join-Path $ControlDir "operation.lock"
$vaultPasswordPath = Join-Path $RuntimeDir "vault_pass"
$agentSocketPath = Join-Path $RuntimeDir "active.sock"
$agentPidPath = Join-Path $ControlDir "active.pid"
$containerVaultPasswordPath = "~/.homelab-active/vault_pass"
$containerAgentSocketPath = "~/.homelab-active/active.sock"
$forceEnabled = $PSBoundParameters.ContainsKey("Force") -and $Force

function Main {
    switch ($PSCmdlet.ParameterSetName) {
        "Switch" {
            Invoke-Switch
        }
        "Deactivate" {
            Invoke-Deactivate
        }
        "Help" {
            Write-Help
        }
        default {
            Invoke-Default
        }
    }
}

function Invoke-Default {
    Write-Help
    Write-Host ""

    Assert-Host

    Write-Host "Available environments:"
    Invoke-List
    Write-Host ""
    Write-Host "Current status:"
    Invoke-Status
}

function Write-Help {
    Write-Host "Run this on the container host, not inside the dev container."
    Write-Host "Usage:"
    Write-Host "  pwsh Set-Environment.ps1"
    Write-Host "  pwsh Set-Environment.ps1 [-Environment] <name> [-NoSave] [-Force]"
    Write-Host "  pwsh Set-Environment.ps1 -Deactivate [-Force]"
    Write-Host "  pwsh Set-Environment.ps1 -Help"
    Write-Host ""
    Write-Host "Environment variables:"
    Write-Host "  HOMELAB_ENVIRONMENT_STORE  Override the environment store"
    Write-Host "current environment store: $EnvRoot"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Environment <name>  Switch to an environment; auto-create it if missing"
    Write-Host "  -NoSave              Do not save current repo vaults; discard them when no environment is active"
    Write-Host "  -Force               Allow non-tmpfs runtime root, unmanaged repo vaults, or clearing repo vaults without an active runtime"
    Write-Host "  -Deactivate          Save active vaults, remove them from the repo, stop the agent, and clear the active environment"
}

function Assert-Host {
    $inContainer = (Test-Path -LiteralPath "/.dockerenv") -or (Test-Path -LiteralPath "/run/.containerenv")
    if (-not $inContainer) {
        $cgroupPath = "/proc/1/cgroup"
        if (Test-Path -LiteralPath $cgroupPath) {
            $cgroup = Get-Content -LiteralPath $cgroupPath -Raw -ErrorAction SilentlyContinue
            if ($cgroup -match "(docker|containerd|kubepods)") {
                $inContainer = $true
            }
        }
    }

    $dockerCommand = Get-Command "docker" -ErrorAction SilentlyContinue
    $homelabRoot = Join-Path $HOME ".homelab"
    if ($inContainer -or ($null -eq $dockerCommand -and -not (Test-Path -LiteralPath $homelabRoot))) {
        throw "Set-Environment.ps1 must run on the WSL/container host, not inside the dev container. The host owns ~/.homelab and the tmpfs runtime at '$RuntimeRoot'."
    }
}

function Initialize-RuntimeDir {
    if (-not $IsLinux) {
        throw "The active environment runtime directory requires a Linux/WSL host."
    }

    foreach ($directory in @($RuntimeRoot, $ControlDir, $RuntimeDir)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        & chmod 700 $directory
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set permissions on '$directory'."
        }
    }

    $fileSystemType = ""
    try {
        $fileSystemType = (& stat -f -c %T $RuntimeRoot).Trim()
    }
    catch {
        $fileSystemType = ""
    }

    if ($fileSystemType -ne "tmpfs") {
        $message = "Runtime directory '$RuntimeRoot' is not tmpfs (detected '$fileSystemType')."
        if (-not $forceEnabled) {
            throw "$message Use -Force only if you accept that the vault password may be written to persistent storage."
        }
        Write-Warning $message
    }
}

function Set-PrivateFileMode([string]$Path) {
    if ($IsLinux -or $IsMacOS) {
        & chmod 600 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set permissions on '$Path'."
        }
    }
}

function Get-EnvironmentDir([string]$Name) {
    if ($Name -notmatch "^[A-Za-z0-9][A-Za-z0-9_-]*$") {
        throw "Invalid environment name '$Name'. Use letters, digits, '-' and '_'."
    }
    return Join-Path $EnvRoot $Name
}

function Get-ActiveState {
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $statePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw | ConvertFrom-Json
}

function Get-RepoVaultFiles {
    return @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter "vault.yml" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "[\\/](\.git|\.venv|\.collections|node_modules)[\\/]" }
    )
}

function Get-EnvironmentVaultFiles([string]$EnvDir) {
    $repoVaultsDir = Join-Path $EnvDir "repo"
    if (-not (Test-Path -LiteralPath $repoVaultsDir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $repoVaultsDir -Recurse -File -Filter "vault.yml" -ErrorAction SilentlyContinue
    )
}

function Assert-NoOrphanedRuntime([object]$ActiveState, [object[]]$RepoVaults, [bool]$AllowDiscard = $false) {
    if ($null -ne $ActiveState) {
        return
    }

    $vaultCount = @($RepoVaults).Count
    if ($vaultCount -eq 0) {
        return
    }

    if ($forceEnabled) {
        Write-Warning "Repository contains $vaultCount encrypted vault.yml file(s) but no active runtime environment was found. Continuing because -Force was supplied."
        return
    }

    if ($AllowDiscard) {
        Write-Warning "Repository contains $vaultCount encrypted vault.yml file(s) but no active runtime environment was found. Continuing because -NoSave was supplied; the repository vault files will be discarded."
        return
    }

    throw "Repository contains $vaultCount encrypted vault.yml file(s) but no active runtime environment was found at '$RuntimeRoot'. This usually means the host rebooted or the tmpfs runtime was cleared. Re-run with -Force to override, or move the vault files into their environment store first."
}

function Assert-Encrypted([string]$FilePath) {
    $firstLine = Get-Content -LiteralPath $FilePath -TotalCount 1 -ErrorAction Stop
    if ($firstLine -notlike '$ANSIBLE_VAULT;*') {
        throw "Refusing plaintext vault file '$FilePath'. Encrypt it with ansible-vault before switching environments."
    }
}

function Get-RelativePath([string]$BasePath, [string]$Path) {
    return [System.IO.Path]::GetRelativePath($BasePath, $Path)
}

function Copy-RepoVaultsToEnvironment([string]$EnvDir) {
    $repoVaultsDir = Join-Path $EnvDir "repo"
    New-Item -ItemType Directory -Force -Path $repoVaultsDir | Out-Null

    $pathComparer = if ($IsLinux) {
        [System.StringComparer]::Ordinal
    }
    else {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    $relativePaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)

    foreach ($vault in (Get-RepoVaultFiles)) {
        Assert-Encrypted $vault.FullName
        $relative = Get-RelativePath $repoRoot $vault.FullName
        [void]$relativePaths.Add($relative)
        $destination = Join-Path $repoVaultsDir $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $vault.FullName -Destination $destination -Force
    }

    # Mirror the repository: vaults removed from the repository are also removed
    # from the environment store so a removal persists across switches.
    foreach ($vault in (Get-EnvironmentVaultFiles $EnvDir)) {
        $relative = Get-RelativePath $repoVaultsDir $vault.FullName
        if (-not $relativePaths.Contains($relative)) {
            Remove-Item -LiteralPath $vault.FullName -Force
        }
    }
}

function Remove-RepoVaults {
    foreach ($repoVault in (Get-RepoVaultFiles)) {
        Remove-Item -LiteralPath $repoVault.FullName -Force
    }
}

function Copy-EnvironmentVaultsToRepo([string]$EnvDir) {
    $targetVaults = Get-EnvironmentVaultFiles $EnvDir
    foreach ($vault in $targetVaults) {
        Assert-Encrypted $vault.FullName
    }

    Remove-RepoVaults

    $repoVaultsDir = Join-Path $EnvDir "repo"
    $relativePaths = @()
    foreach ($vault in $targetVaults) {
        $relative = Get-RelativePath $repoVaultsDir $vault.FullName
        $relativePaths += $relative
        $destination = Join-Path $repoRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $vault.FullName -Destination $destination -Force
    }

    return @($relativePaths)
}

function Backup-RepoVaults {
    $backupDir = Join-Path $ControlDir "rollback"
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    foreach ($vault in (Get-RepoVaultFiles)) {
        Assert-Encrypted $vault.FullName
        $relative = Get-RelativePath $repoRoot $vault.FullName
        $destination = Join-Path $backupDir $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $vault.FullName -Destination $destination -Force
    }

    return $backupDir
}

function Restore-RepoVaults([string]$BackupDir) {
    Remove-RepoVaults

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        return
    }

    foreach ($vault in (Get-ChildItem -LiteralPath $BackupDir -Recurse -File -Filter "vault.yml" -ErrorAction SilentlyContinue)) {
        $relative = Get-RelativePath $BackupDir $vault.FullName
        $destination = Join-Path $repoRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $vault.FullName -Destination $destination -Force
    }
}

function Get-EnvironmentKey([string]$EnvDir) {
    $sshDir = Join-Path $EnvDir "ssh"
    $privateKey = Join-Path $sshDir "ansible"
    $publicKey = Join-Path $sshDir "ansible.pub"

    if (-not (Test-Path -LiteralPath $privateKey)) {
        throw "Missing private key: $privateKey"
    }
    if (-not (Test-Path -LiteralPath $publicKey)) {
        throw "Missing public key: $publicKey"
    }

    return [pscustomobject]@{
        PrivateKey = $privateKey
        PublicKey = $publicKey
    }
}

function Stop-Agent {
    if (Test-Path -LiteralPath $agentPidPath) {
        $rawPid = (Get-Content -LiteralPath $agentPidPath -Raw).Trim()
        if ($rawPid -match "^\d+$") {
            $process = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
            if ($null -ne $process -and $process.ProcessName -eq "ssh-agent") {
                Stop-Process -Id ([int]$rawPid) -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $agentPidPath -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $agentSocketPath -Force -ErrorAction SilentlyContinue
    Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue
    Remove-Item Env:SSH_AGENT_PID -ErrorAction SilentlyContinue
}

function Start-Agent([string]$PrivateKeyPath, [string]$PublicKeyPath) {
    foreach ($command in @("ssh-agent", "ssh-add", "ssh-keygen")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Missing dependency: '$command' not found on PATH."
        }
    }

    Stop-Agent
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

    $agentOutput = & ssh-agent -a $agentSocketPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start ssh-agent: $($agentOutput | Out-String)"
    }

    $agentOutputText = $agentOutput | Out-String
    if ($agentOutputText -notmatch "SSH_AGENT_PID=(\d+)") {
        Stop-Agent
        throw "Could not determine ssh-agent PID from: $agentOutputText"
    }
    $agentPid = [int]$matches[1]
    Set-Content -LiteralPath $agentPidPath -Value $agentPid -Encoding utf8NoBOM
    Set-PrivateFileMode $agentPidPath

    $env:SSH_AUTH_SOCK = $agentSocketPath
    $env:SSH_AGENT_PID = "$agentPid"

    & ssh-add $PrivateKeyPath
    if ($LASTEXITCODE -ne 0) {
        Stop-Agent
        throw "ssh-add could not load the environment SSH key."
    }

    $fingerprintOutput = & ssh-keygen -lf $PublicKeyPath
    if ($LASTEXITCODE -ne 0) {
        Stop-Agent
        throw "Could not read the environment SSH public key: $PublicKeyPath"
    }
    $fingerprint = (($fingerprintOutput | Select-Object -First 1) -split "\s+")[1]

    $loadedKeys = & ssh-add -l 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Agent
        throw "ssh-agent did not report a loaded key."
    }
    if (-not ($loadedKeys | Where-Object { $_ -match [regex]::Escape($fingerprint) })) {
        Stop-Agent
        throw "The loaded SSH key does not match '$PublicKeyPath'."
    }

    return $fingerprint
}

function Read-VaultPassword([string]$Name) {
    $securePassword = Read-Host -Prompt "Ansible Vault password for '$Name'?" -AsSecureString
    $plainPassword = [pscredential]::new("dummy", $securePassword).GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($plainPassword)) {
        throw "No vault password supplied."
    }
    return $plainPassword
}

function Write-ActiveVaultPassword([string]$PlainPassword) {
    $tempPath = "$vaultPasswordPath.new"
    [System.IO.File]::WriteAllText($tempPath, $PlainPassword, [System.Text.UTF8Encoding]::new($false))
    Set-PrivateFileMode $tempPath
    Move-Item -LiteralPath $tempPath -Destination $vaultPasswordPath -Force
    Set-PrivateFileMode $vaultPasswordPath
}

function Write-JsonFile([string]$Path, $Value) {
    $tempPath = "$Path.new"
    $json = $Value | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Set-PrivateFileMode $tempPath
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
    Set-PrivateFileMode $Path
}

function Restore-FileContent([string]$Path, [byte[]]$Content) {
    if ($null -eq $Content) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }

    [System.IO.File]::WriteAllBytes($Path, $Content)
    Set-PrivateFileMode $Path
}

function Enter-Lock {
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        throw "Another Set-Environment operation is running (lock: $lockPath). Remove the lock only if you are sure no switch is running."
    }

    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.WriteLine("PID=$PID")
    $writer.WriteLine("Started=$((Get-Date).ToUniversalTime().ToString("o"))")
    $writer.Flush()

    return [pscustomobject]@{
        Stream = $stream
        Writer = $writer
    }
}

function Exit-Lock($Lock) {
    if ($null -eq $Lock) {
        return
    }

    $Lock.Writer.Dispose()
    $Lock.Stream.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

function New-Environment([string]$Name) {
    $envDir = Get-EnvironmentDir $Name
    if (Test-Path -LiteralPath $envDir) {
        Write-Host "Environment '$Name' already exists; leaving it unchanged."
        return
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $envDir "repo") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $envDir "ssh") | Out-Null
    & chmod 700 $envDir
    & chmod 700 (Join-Path $envDir "repo")
    & chmod 700 (Join-Path $envDir "ssh")

    Write-Host "Created environment '$Name' at $envDir"
    Write-Host "Add a key: ssh-keygen -t ed25519 -f $(Join-Path $envDir "ssh/ansible") -C ansible"
    Write-Host "Add encrypted vaults under $(Join-Path $envDir "repo") using repo-relative paths."
}

function Invoke-List {
    if (-not (Test-Path -LiteralPath $EnvRoot)) {
        Write-Host "No environments found in $EnvRoot"
        return
    }

    $activeState = Get-ActiveState
    foreach ($environmentDir in (Get-ChildItem -LiteralPath $EnvRoot -Directory | Sort-Object Name)) {
        $activeMarker = if ($null -ne $activeState -and $activeState.environment -eq $environmentDir.Name) { " (active)" } else { "" }
        $vaultCount = @(Get-EnvironmentVaultFiles $environmentDir.FullName).Count
        $keyExists = Test-Path -LiteralPath (Join-Path $environmentDir.FullName "ssh/ansible")
        Write-Host ("{0}{1}  vaults={2} key={3}" -f $environmentDir.Name, $activeMarker, $vaultCount, $keyExists)
    }
}

function Invoke-Status {
    $activeState = Get-ActiveState
    $repoVaults = @(Get-RepoVaultFiles)
    if ($null -eq $activeState) {
        Write-Host "No active environment."
        if ($repoVaults.Count -gt 0) {
            Write-Warning "Repository contains $($repoVaults.Count) encrypted vault.yml file(s) but no active runtime environment was found at '$RuntimeRoot'. This usually means the host rebooted or the tmpfs runtime was cleared. Re-run a switch with -Force to override, or -Deactivate -Force to clear them."
        }
        return
    }

    Write-Host "Active environment: $($activeState.environment)"
    Write-Host "Generation: $($activeState.generation)"
    Write-Host "Updated: $($activeState.updatedAt)"
    Write-Host "Managed vaults: $(@($activeState.managedVaults).Count)"
    Write-Host "Runtime root: $RuntimeRoot"
    Write-Host "Vault password file: $vaultPasswordPath (exists: $(Test-Path -LiteralPath $vaultPasswordPath))"
    Write-Host "SSH agent socket: $agentSocketPath (exists: $(Test-Path -LiteralPath $agentSocketPath))"
    Write-Host "Published state file: $publishedStatePath (exists: $(Test-Path -LiteralPath $publishedStatePath))"
    Write-Host "SSH public key: $(if ($activeState.sshPublicKey) { 'present' } else { 'missing' })"

    if (Test-Path -LiteralPath $agentPidPath) {
        Write-Host "SSH agent PID: $((Get-Content -LiteralPath $agentPidPath -Raw).Trim())"
    }
}

function Invoke-Deactivate {
    Assert-Host
    Initialize-RuntimeDir

    $lock = $null
    $backupDir = $null
    try {
        $lock = Enter-Lock
        $activeState = Get-ActiveState
        $repoVaults = @(Get-RepoVaultFiles)
        Assert-NoOrphanedRuntime $activeState $repoVaults
        if ($null -ne $activeState) {
            $currentEnvDir = Get-EnvironmentDir $activeState.environment
            if (-not (Test-Path -LiteralPath $currentEnvDir)) {
                throw "Active environment '$($activeState.environment)' directory is missing: $currentEnvDir"
            }

            $backupDir = Backup-RepoVaults
            Copy-RepoVaultsToEnvironment $currentEnvDir
            $savedVaultCount = @(Get-EnvironmentVaultFiles $currentEnvDir).Count
            Remove-RepoVaults

            Stop-Agent
            Remove-Item -LiteralPath $vaultPasswordPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $publishedStatePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue

            Write-Host "Deactivated environment '$($activeState.environment)'."
            Write-Host "Saved $savedVaultCount vault file(s) to $currentEnvDir and removed them from the repository."
        }
        else {
            if ($repoVaults.Count -gt 0) {
                Remove-RepoVaults
            }

            Stop-Agent
            Remove-Item -LiteralPath $vaultPasswordPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $publishedStatePath -Force -ErrorAction SilentlyContinue
            Write-Host "No active environment."
            if ($repoVaults.Count -gt 0) {
                Write-Host "Removed $($repoVaults.Count) unmanaged repository vault file(s)."
            }
        }
    }
    catch {
        if ($null -ne $backupDir -and (Test-Path -LiteralPath $backupDir)) {
            try {
                Restore-RepoVaults $backupDir
            }
            catch {
                Write-Warning "Rollback of repository vaults failed: $_"
            }
        }

        throw
    }
    finally {
        Exit-Lock $lock
    }
}

function Invoke-Switch {
    Assert-Host

    $envDir = Get-EnvironmentDir $Environment
    if (-not (Test-Path -LiteralPath $envDir)) {
        New-Environment $Environment
        Write-Host "Environment '$Environment' did not exist and was created. Add its key and vaults, then re-run the switch."
        return
    }

    Initialize-RuntimeDir
    $key = Get-EnvironmentKey $envDir
    $targetVaults = @(Get-EnvironmentVaultFiles $envDir)
    foreach ($vault in $targetVaults) {
        Assert-Encrypted $vault.FullName
    }

    $currentState = Get-ActiveState
    $currentEnvDir = $null
    if ($null -ne $currentState) {
        $currentEnvDir = Get-EnvironmentDir $currentState.environment
        if (-not (Test-Path -LiteralPath $currentEnvDir)) {
            throw "Active environment '$($currentState.environment)' directory is missing: $currentEnvDir"
        }
    }

    $repoVaults = @(Get-RepoVaultFiles)
    Assert-NoOrphanedRuntime $currentState $repoVaults -AllowDiscard:([bool]$NoSave)

    $adoptUnmanaged = $false
    if ($null -eq $currentState -and $targetVaults.Count -eq 0 -and $repoVaults.Count -gt 0 -and -not $NoSave) {
        $adoptUnmanaged = $true
    }

    $targetVaultPassword = $null
    if ($targetVaults.Count -gt 0) {
        $targetVaultPassword = Read-VaultPassword $Environment
    }
    elseif ($adoptUnmanaged) {
        $targetVaultPassword = Read-VaultPassword "$Environment (import current repo vaults)"
    }

    $lock = $null
    $backupDir = $null
    $previousVaultPassword = $null
    $previousState = $null
    $previousPublishedState = $null
    $agentStarted = $false
    try {
        $lock = Enter-Lock
        if (Test-Path -LiteralPath $statePath) {
            $previousState = [System.IO.File]::ReadAllBytes($statePath)
        }
        if (Test-Path -LiteralPath $publishedStatePath) {
            $previousPublishedState = [System.IO.File]::ReadAllBytes($publishedStatePath)
        }

        $backupDir = Backup-RepoVaults

        if ($null -ne $currentState) {
            if (-not $NoSave) {
                Copy-RepoVaultsToEnvironment $currentEnvDir
            }
        }
        elseif ($adoptUnmanaged) {
            Copy-RepoVaultsToEnvironment $envDir
        }

        $managedVaults = @(Copy-EnvironmentVaultsToRepo $envDir)

        if (Test-Path -LiteralPath $vaultPasswordPath) {
            $previousVaultPassword = Get-Content -LiteralPath $vaultPasswordPath -Raw
        }
        if ($managedVaults.Count -gt 0) {
            Write-ActiveVaultPassword $targetVaultPassword
        }
        else {
            Remove-Item -LiteralPath $vaultPasswordPath -Force -ErrorAction SilentlyContinue
        }

        $fingerprint = Start-Agent $key.PrivateKey $key.PublicKey
        $agentStarted = $true
        $publicKey = (Get-Content -LiteralPath $key.PublicKey -Raw).Trim()

        $state = [ordered]@{
            environment        = $Environment
            generation         = [guid]::NewGuid().ToString("N")
            updatedAt          = (Get-Date).ToUniversalTime().ToString("o")
            vaultPasswordFile  = if ($managedVaults.Count -gt 0) { $containerVaultPasswordPath } else { $null }
            hostVaultPasswordFile = if ($managedVaults.Count -gt 0) { $vaultPasswordPath } else { $null }
            sshAgentSocket     = $containerAgentSocketPath
            hostSshAgentSocket = $agentSocketPath
            sshPublicKey       = $publicKey
            managedVaults      = @($managedVaults)
        }
        Write-JsonFile $statePath $state
        Write-JsonFile $publishedStatePath $state

        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "Active environment: $Environment"
        Write-Host "Vaults: $(@($managedVaults).Count)"
        Write-Host "SSH key fingerprint: $fingerprint"
        Write-Host "Runtime directory: $RuntimeRoot"
    }
    catch {
        if ($null -ne $backupDir -and (Test-Path -LiteralPath $backupDir)) {
            try {
                Restore-RepoVaults $backupDir
            }
            catch {
                Write-Warning "Rollback of repository vaults failed: $_"
            }
        }

        if ($null -ne $previousVaultPassword) {
            try {
                Write-ActiveVaultPassword $previousVaultPassword
            }
            catch {
                Write-Warning "Rollback of the active vault password failed: $_"
            }
        }

        if ($agentStarted) {
            try {
                Stop-Agent
            }
            catch {
                Write-Warning "Rollback of the active SSH agent failed: $_"
            }
        }

        try {
            Restore-FileContent $statePath $previousState
            Restore-FileContent $publishedStatePath $previousPublishedState
        }
        catch {
            Write-Warning "Rollback of the active environment state failed: $_"
        }

        throw
    }
    finally {
        Exit-Lock $lock
    }
}


Main

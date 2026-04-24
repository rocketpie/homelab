#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [switch]$RunSnapshot,
    [switch]$RunRetention,
    [switch]$ShowStatus,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

$script:ThisFileName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition)
$script:ThisFilePath = $MyInvocation.MyCommand.Definition
$script:ThisFileVersion = '1.0'
$script:DefaultCommandTimeoutSeconds = 300
$script:StatusCommandTimeoutSeconds = 5

function Main {
    if (@($RunSnapshot, $RunRetention, $ShowStatus).Where({ $_ }).Count -gt 1) {
        throw 'Use only one of -RunSnapshot, -RunRetention, or -ShowStatus.'
    }

    $resolvedConfigPath = Resolve-ConfigPath -ConfigPath $ConfigPath
    $script:ConfigPath = $resolvedConfigPath
    $script:Config = Read-ConfigFile -ConfigPath $resolvedConfigPath
    $script:ConfigWarnings = @(Get-ConfigurationWarnings -Config $script:Config)

    if ($RunSnapshot) {
        Start-ConfiguredSnapshots
        return
    }

    if ($RunRetention) {
        Start-ConfiguredRetention
        return
    }

    if ($ShowStatus) {
        Show-Status
        return
    }

    Invoke-InteractiveMenu
}

function Resolve-ConfigPath {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $ConfigPath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:RESTIC_CLIENT_CONFIG_FILE)) {
        return $env:RESTIC_CLIENT_CONFIG_FILE
    }

    $siblingConfigPath = Join-Path $PSScriptRoot "$script:ThisFileName.json"
    if (Test-Path -LiteralPath $siblingConfigPath) {
        return $siblingConfigPath
    }

    if ($IsWindows) {
        return $siblingConfigPath
    }

    return '/etc/restic-client/restic-client.json'
}

function Read-ConfigFile {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Cannot find config file '$ConfigPath'."
    }

    $schemaPath = Join-Path $PSScriptRoot "$script:ThisFileName.schema.json"
    if (Test-Path -LiteralPath $schemaPath) {
        Test-Json -LiteralPath $ConfigPath -SchemaFile $schemaPath | Out-Null
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($config.repositories.Count -lt 1) {
        throw 'The config must contain at least one repository.'
    }

    return $config
}

function Get-ConfigurationWarnings {
    [CmdletBinding()]
    param(
        [object]$Config
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($repository in @($Config.repositories)) {
        $hasSnapshotSettings = (-not [string]::IsNullOrWhiteSpace($repository.backupPreCommand)) -or (@($repository.resticBackupOptions).Count -gt 0)

        if (($repository.snapshotAllowed -or $repository.restoreAllowed) -and [string]::IsNullOrWhiteSpace($repository.path)) {
            $warnings.Add("Repository '$($repository.name)' allows snapshot or restore, but path is empty.")
        }

        if ($repository.forgetAllowed -and @($repository.forgetArgs).Count -eq 0) {
            $warnings.Add("Repository '$($repository.name)' allows forget, but forgetArgs is empty.")
        }

        if ($hasSnapshotSettings -and -not $repository.snapshotAllowed) {
            $warnings.Add("Repository '$($repository.name)' defines snapshot settings, but snapshotAllowed is false.")
        }

        if (@($repository.forgetArgs).Count -gt 0 -and -not $repository.forgetAllowed) {
            $warnings.Add("Repository '$($repository.name)' defines forgetArgs, but forgetAllowed is false.")
        }
    }

    return $warnings
}

function Invoke-InteractiveMenu {
    while ($true) {
        Show-Status
        ''
        'Select an action:'
        '  1. Run snapshot now'
        '  2. Run retention now'
        '  3. Show snapshots'
        '  4. Restore files'
        '  5. Run custom restic command'
        '  6. Enable snapshot timer'
        '  7. Disable snapshot timer'
        '  8. Enable retention timer'
        '  9. Disable retention timer'
        '  0. Exit'
        ''

        $choice = Read-Host 'Choice [0-9]'
        switch ($choice) {
            '1' { Start-ConfiguredSnapshots }
            '2' { Start-ConfiguredRetention }
            '3' { Show-ConfiguredSnapshots }
            '4' { Invoke-InteractiveRestore }
            '5' { Invoke-InteractiveCustomResticCommand }
            '6' { Set-ScheduleState -Schedule $script:Config.snapshotSchedule -Enabled $true }
            '7' { Set-ScheduleState -Schedule $script:Config.snapshotSchedule -Enabled $false }
            '8' { Set-ScheduleState -Schedule $script:Config.retentionSchedule -Enabled $true }
            '9' { Set-ScheduleState -Schedule $script:Config.retentionSchedule -Enabled $false }
            '0' { return }
            default {
                "Invalid choice '$choice'."
            }
        }

        ''
        [void](Read-Host 'Press Enter to return to the menu')
    }
}

function Show-Status {
    ''
    "$script:ThisFileName $script:ThisFileVersion"
    "Config: $(Resolve-PathText -Path $script:ConfigPath)"
    "Log path: $($script:Config.log.path)"
    "Snapshot timer: $(Get-ScheduleSummary -Schedule $script:Config.snapshotSchedule)"
    "Retention timer: $(Get-ScheduleSummary -Schedule $script:Config.retentionSchedule)"
    ''
    'Repositories:'

    foreach ($repository in @($script:Config.repositories)) {
        $flags = @()
        if ($repository.snapshotAllowed) { $flags += 'snapshot' }
        if ($repository.restoreAllowed) { $flags += 'restore' }
        if ($repository.forgetAllowed) { $flags += 'forget' }
        $summary = Get-RepositorySnapshotSummary -Repository $repository
        "[{0}] {1}" -f (($flags -join ', ') | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { 'none' } else { $_ } }), $repository.name
        "  repository: $($repository.repositoryDisplay)"
        "  path: $($repository.path)"
        "  snapshots: $($summary.CountText)"
        "  latest snapshot age: $($summary.LatestAgeText)"
    }

    if ($script:ConfigWarnings.Count -gt 0) {
        ''
        'Warnings:'
        foreach ($warning in $script:ConfigWarnings) {
            "  WARN: $warning"
        }
    }
}

function Resolve-PathText {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    catch {
        return $Path
    }
}

function Get-ScheduleSummary {
    [CmdletBinding()]
    param(
        [object]$Schedule
    )

    if ($null -eq $Schedule) {
        return 'not configured'
    }

    if ($IsWindows) {
        return "$(if ($Schedule.enabled) { 'enabled' } else { 'disabled' }) (Windows schedule control not implemented)"
    }

    $configuredState = if ($Schedule.enabled) { 'configured enabled' } else { 'configured disabled' }
    $unitState = Get-SystemdUnitSummary -Unit $Schedule.unit
    return '{0}; {1}; {2}' -f $configuredState, $unitState.Enabled, $unitState.Active
}

function Get-SystemdUnitSummary {
    [CmdletBinding()]
    param(
        [string]$Unit
    )

    if ($IsWindows) {
        return [pscustomobject]@{
            Enabled = 'windows'
            Active  = 'windows'
        }
    }

    $enabled = Invoke-NativeCommand -FileName 'systemctl' -ArgumentList @('is-enabled', $Unit) -AllowFailure -TimeoutSeconds 10
    $active = Invoke-NativeCommand -FileName 'systemctl' -ArgumentList @('is-active', $Unit) -AllowFailure -TimeoutSeconds 10
    return [pscustomobject]@{
        Enabled = Get-FirstNonEmptyLine -Text $enabled.StandardOutput -Default 'unknown'
        Active  = Get-FirstNonEmptyLine -Text $active.StandardOutput -Default 'unknown'
    }
}

function Get-RepositorySnapshotSummary {
    [CmdletBinding()]
    param(
        [object]$Repository
    )

    try {
        $result = Invoke-ResticCommand -Repository $Repository -ArgumentList @('snapshots', '--json') -AllowFailure -TimeoutSeconds $script:StatusCommandTimeoutSeconds
        if ($result.TimedOut) {
            return [pscustomobject]@{
                CountText     = 'timed out'
                LatestAgeText = 'timed out'
            }
        }

        if ($result.ExitCode -ne 0) {
            return [pscustomobject]@{
                CountText     = 'error'
                LatestAgeText = 'error'
            }
        }

        $snapshotOutput = $result.StandardOutput.Trim()
        if ([string]::IsNullOrWhiteSpace($snapshotOutput)) {
            return [pscustomobject]@{
                CountText     = '0'
                LatestAgeText = 'none'
            }
        }

        $snapshots = @($snapshotOutput | ConvertFrom-Json)
        if ($snapshots.Count -eq 0) {
            return [pscustomobject]@{
                CountText     = '0'
                LatestAgeText = 'none'
            }
        }

        $latestSnapshot = $snapshots | Sort-Object { [datetime]$_.time } -Descending | Select-Object -First 1
        return [pscustomobject]@{
            CountText     = [string]$snapshots.Count
            LatestAgeText = Get-AgeText -Time ([datetime]$latestSnapshot.time)
        }
    }
    catch {
        return [pscustomobject]@{
            CountText     = 'error'
            LatestAgeText = 'error'
        }
    }
}

function Get-AgeText {
    [CmdletBinding()]
    param(
        [datetime]$Time
    )

    $age = (Get-Date) - $Time
    if ($age.TotalDays -ge 1) {
        return '{0:N0}d' -f [math]::Floor($age.TotalDays)
    }
    if ($age.TotalHours -ge 1) {
        return '{0:N0}h' -f [math]::Floor($age.TotalHours)
    }
    if ($age.TotalMinutes -ge 1) {
        return '{0:N0}m' -f [math]::Floor($age.TotalMinutes)
    }
    return '{0:N0}s' -f [math]::Max([math]::Floor($age.TotalSeconds), 0)
}

function Start-ConfiguredSnapshots {
    $repositories = @($script:Config.repositories | Where-Object { $_.snapshotAllowed })
    if ($repositories.Count -eq 0) {
        'No repositories allow snapshot.'
        return
    }

    Test-ResticBinary
    Test-WriteAccess -Path $script:Config.log.path
    $logFilePath = Initialize-LogFile -OperationName 'snapshot'

    foreach ($repository in $repositories) {
        try {
            if ([string]::IsNullOrWhiteSpace($repository.path)) {
                throw "Path is empty for repository '$($repository.name)'."
            }

            Test-ReadAccess -Path $repository.path
            "Starting snapshot for '$($repository.name)'..." | Out-Logged -LogFilePath $logFilePath
            Invoke-ResticSnapshot -Repository $repository -LogFilePath $logFilePath
        }
        catch {
            "Snapshot failed for '$($repository.name)'." | Out-Logged -LogFilePath $logFilePath
            Write-LoggedErrorDetails -LogFilePath $logFilePath -ErrorRecord $_
        }
    }

    Remove-ExpiredLogFiles | Out-Logged -LogFilePath $logFilePath
}

function Start-ConfiguredRetention {
    $repositories = @($script:Config.repositories | Where-Object { $_.forgetAllowed })
    if ($repositories.Count -eq 0) {
        'No repositories allow retention.'
        return
    }

    Test-ResticBinary
    Test-WriteAccess -Path $script:Config.log.path
    $logFilePath = Initialize-LogFile -OperationName 'retention'

    foreach ($repository in $repositories) {
        try {
            if (@($repository.forgetArgs).Count -eq 0) {
                throw "forgetArgs is empty for repository '$($repository.name)'."
            }

            "Starting retention for '$($repository.name)'..." | Out-Logged -LogFilePath $logFilePath
            $result = Invoke-ResticCommand -Repository $repository -ArgumentList (@('forget') + @($repository.forgetArgs))
            Write-LoggedCommandResult -LogFilePath $logFilePath -Result $result
        }
        catch {
            "Retention failed for '$($repository.name)'." | Out-Logged -LogFilePath $logFilePath
            Write-LoggedErrorDetails -LogFilePath $logFilePath -ErrorRecord $_
        }
    }

    Remove-ExpiredLogFiles | Out-Logged -LogFilePath $logFilePath
}

function Show-ConfiguredSnapshots {
    Test-ResticBinary

    foreach ($repository in @($script:Config.repositories)) {
        ''
        "Repository: $($repository.name)"
        "Path: $($repository.path)"
        "Allowed: snapshot=$($repository.snapshotAllowed) restore=$($repository.restoreAllowed) forget=$($repository.forgetAllowed)"
        try {
            $result = Invoke-ResticCommand -Repository $repository -ArgumentList @('snapshots')
            if (-not [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
                $result.StandardOutput.TrimEnd("`r", "`n")
            }
            if (-not [string]::IsNullOrWhiteSpace($result.StandardError)) {
                $result.StandardError.TrimEnd("`r", "`n")
            }
        }
        catch {
            Write-Error "Failed to list snapshots for '$($repository.name)': $($_.Exception.Message)"
        }
    }
}

function Invoke-InteractiveRestore {
    $restoreRepositories = @($script:Config.repositories | Where-Object { $_.restoreAllowed })
    if ($restoreRepositories.Count -eq 0) {
        'No repositories allow restore.'
        return
    }

    $repository = Select-Repository -Repositories $restoreRepositories -Prompt 'Choose a repository to restore:'
    if ($null -eq $repository) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($repository.path)) {
        "Repository '$($repository.name)' has no path configured."
        return
    }

    $snapshot = Read-Host "Snapshot [latest]"
    if ([string]::IsNullOrWhiteSpace($snapshot)) {
        $snapshot = 'latest'
    }

    Test-WriteAccess -Path $script:Config.log.path
    $logFilePath = Initialize-LogFile -OperationName ('restore-' + $repository.name)
    "Starting restore for '$($repository.name)' snapshot '$snapshot'..." | Out-Logged -LogFilePath $logFilePath
    $result = Invoke-ResticCommand -Repository $repository -ArgumentList @('restore', $snapshot, '--target', '/', '--include', $repository.path)
    Write-LoggedCommandResult -LogFilePath $logFilePath -Result $result
}

function Invoke-InteractiveCustomResticCommand {
    $repository = Select-Repository -Repositories @($script:Config.repositories) -Prompt 'Choose a repository for a custom command:'
    if ($null -eq $repository) {
        return
    }

    $argumentText = Read-Host 'Enter restic arguments'
    if ([string]::IsNullOrWhiteSpace($argumentText)) {
        'No arguments entered.'
        return
    }

    $arguments = [System.Management.Automation.PSParser]::Tokenize($argumentText, [ref]$null) |
        Where-Object { $_.Type -eq 'CommandArgument' -or $_.Type -eq 'Command' } |
        ForEach-Object { $_.Content }

    if ($arguments.Count -eq 0) {
        'No usable arguments entered.'
        return
    }

    $result = Invoke-ResticCommand -Repository $repository -ArgumentList $arguments
    if (-not [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
        $result.StandardOutput.TrimEnd("`r", "`n")
    }
    if (-not [string]::IsNullOrWhiteSpace($result.StandardError)) {
        $result.StandardError.TrimEnd("`r", "`n")
    }
}

function Select-Repository {
    [CmdletBinding()]
    param(
        [object[]]$Repositories,
        [string]$Prompt
    )

    if ($Repositories.Count -eq 0) {
        return $null
    }

    ''
    $Prompt
    for ($index = 0; $index -lt $Repositories.Count; $index++) {
        '{0}. {1}' -f ($index + 1), $Repositories[$index].name
    }

    $choice = Read-Host "Choice [1-$($Repositories.Count)]"
    if ($choice -notmatch '^[0-9]+$') {
        return $null
    }

    $choiceIndex = [int]$choice - 1
    if ($choiceIndex -lt 0 -or $choiceIndex -ge $Repositories.Count) {
        return $null
    }

    return $Repositories[$choiceIndex]
}

function Set-ScheduleState {
    [CmdletBinding()]
    param(
        [object]$Schedule,
        [bool]$Enabled
    )

    if ($null -eq $Schedule) {
        'Schedule is not configured.'
        return
    }

    if ($IsWindows) {
        'Windows schedule management is not implemented in this script.'
        return
    }

    $command = if ($Enabled) { @('enable', '--now', $Schedule.unit) } else { @('disable', '--now', $Schedule.unit) }
    $result = Invoke-NativeCommand -FileName 'sudo' -ArgumentList (@('systemctl') + $command)
    if (-not [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
        $result.StandardOutput.TrimEnd("`r", "`n")
    }
    if (-not [string]::IsNullOrWhiteSpace($result.StandardError)) {
        $result.StandardError.TrimEnd("`r", "`n")
    }
}

function Test-ResticBinary {
    if ($null -eq (Get-Command $script:Config.resticBinary -ErrorAction SilentlyContinue)) {
        throw "Cannot find restic binary '$($script:Config.resticBinary)'."
    }
}

function Invoke-ResticSnapshot {
    [CmdletBinding()]
    param(
        [object]$Repository,
        [string]$LogFilePath
    )

    $argumentList = @('backup')
    $ignoreFiles = @(Get-ResticIgnoreFiles -Path $Repository.path)
    foreach ($ignoreFile in $ignoreFiles) {
        $argumentList += '--iexclude-file'
        $argumentList += $ignoreFile
    }

    if (-not [string]::IsNullOrWhiteSpace($Repository.backupPreCommand)) {
        "Running pre-backup command: $($Repository.backupPreCommand)" | Out-Logged -LogFilePath $LogFilePath
        Invoke-HostCommand -CommandText $Repository.backupPreCommand | Out-Logged -LogFilePath $LogFilePath
    }

    foreach ($backupOption in @($Repository.resticBackupOptions)) {
        $argumentList += [string]$backupOption
    }

    $argumentList += $Repository.path
    $result = Invoke-ResticCommand -Repository $Repository -ArgumentList $argumentList
    Write-LoggedCommandResult -LogFilePath $LogFilePath -Result $result
}

function Get-ResticIgnoreFiles {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Path -File -Filter $script:Config.backupIgnoreFilename -Depth 1 -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
}

function Invoke-ResticCommand {
    [CmdletBinding()]
    param(
        [object]$Repository,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = $script:DefaultCommandTimeoutSeconds,
        [switch]$AllowFailure
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $script:Config.resticBinary
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true
    $processStartInfo.Environment['RESTIC_REPOSITORY'] = [string]$Repository.resticRepository
    $processStartInfo.Environment['RESTIC_PASSWORD'] = [string]$Repository.repositoryPassword

    foreach ($argument in $ArgumentList) {
        [void]$processStartInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        if (-not $process.Start()) {
            throw 'Unable to start restic.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
            }

            return [pscustomobject]@{
                ExitCode       = -1
                StandardOutput = ''
                StandardError  = "restic timed out after $TimeoutSeconds seconds"
                TimedOut       = $true
            }
        }

        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "restic exited with code $($process.ExitCode)`n$stderrText"
        }

        return [pscustomobject]@{
            ExitCode       = $process.ExitCode
            StandardOutput = $stdoutText
            StandardError  = $stderrText
            TimedOut       = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeCommand {
    [CmdletBinding()]
    param(
        [string]$FileName,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = $script:DefaultCommandTimeoutSeconds,
        [switch]$AllowFailure
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $FileName
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true

    foreach ($argument in $ArgumentList) {
        [void]$processStartInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        if (-not $process.Start()) {
            throw "Unable to start '$FileName'."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
            }

            return [pscustomobject]@{
                ExitCode       = -1
                StandardOutput = ''
                StandardError  = "$FileName timed out after $TimeoutSeconds seconds"
            }
        }

        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "$FileName exited with code $($process.ExitCode)`n$stderrText"
        }

        return [pscustomobject]@{
            ExitCode       = $process.ExitCode
            StandardOutput = $stdoutText
            StandardError  = $stderrText
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-HostCommand {
    [CmdletBinding()]
    param(
        [string]$CommandText
    )

    if ($IsWindows) {
        $result = Invoke-NativeCommand -FileName 'pwsh' -ArgumentList @('-NoProfile', '-Command', $CommandText)
    }
    else {
        $result = Invoke-NativeCommand -FileName '/bin/bash' -ArgumentList @('-lc', $CommandText)
    }

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
        $lines += $result.StandardOutput.TrimEnd("`r", "`n")
    }
    if (-not [string]::IsNullOrWhiteSpace($result.StandardError)) {
        $lines += $result.StandardError.TrimEnd("`r", "`n")
    }

    return ($lines -join [Environment]::NewLine)
}

function Initialize-LogFile {
    [CmdletBinding()]
    param(
        [string]$OperationName
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFilePath = Join-Path $script:Config.log.path "$script:ThisFileName-$OperationName-$timestamp.log"
    Set-Content -LiteralPath $logFilePath -Encoding utf8NoBOM -Value "$script:ThisFilePath $script:ThisFileVersion"
    Add-Content -LiteralPath $logFilePath -Encoding utf8NoBOM -Value "run time $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    return $logFilePath
}

function Out-Logged {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [Parameter(ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$InputObject
    )

    process {
        $InputObject
        Add-Content -LiteralPath $LogFilePath -Encoding utf8NoBOM -Value $InputObject
    }
}

function Write-LoggedCommandResult {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [object]$Result
    )

    if (-not [string]::IsNullOrWhiteSpace($Result.StandardOutput)) {
        foreach ($line in ($Result.StandardOutput -split "\r?\n")) {
            if ($line.Length -gt 0) {
                $line | Out-Logged -LogFilePath $LogFilePath
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Result.StandardError)) {
        foreach ($line in ($Result.StandardError -split "\r?\n")) {
            if ($line.Length -gt 0) {
                $line | Out-Logged -LogFilePath $LogFilePath
            }
        }
    }
}

function Write-LoggedErrorDetails {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = if ($null -ne $ErrorRecord.Exception) {
        $ErrorRecord.Exception.ToString()
    }
    else {
        ($ErrorRecord | Format-List * -Force | Out-String)
    }

    foreach ($line in ($message -split "\r?\n")) {
        if ($line.Length -gt 0) {
            $line | Out-Logged -LogFilePath $LogFilePath
        }
    }
}

function Remove-ExpiredLogFiles {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:Config.log.path -PathType Container)) {
        return 'Log path missing, nothing to clean up.'
    }

    $retention = [timespan]::Parse($script:Config.log.retainLogs)
    $threshold = (Get-Date).Add(-$retention)
    $removed = 0

    foreach ($logFile in @(Get-ChildItem -LiteralPath $script:Config.log.path -File -Filter *.log -ErrorAction SilentlyContinue)) {
        if ($logFile.LastWriteTime -lt $threshold) {
            Remove-Item -LiteralPath $logFile.FullName -Force
            $removed++
        }
    }

    return "Removed $removed expired log file(s)."
}

function Test-ReadAccess {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path '$Path' does not exist."
    }

    Get-ChildItem -LiteralPath $Path -ErrorAction Stop | Out-Null
}

function Test-WriteAccess {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "Cannot use '$Path' as a directory because a file already exists there."
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $testFilePath = Join-Path $Path 'restic-client-write-test.tmp'
    Set-Content -LiteralPath $testFilePath -Encoding utf8NoBOM -Value 'ok'
    Remove-Item -LiteralPath $testFilePath -Force
}

function Get-FirstNonEmptyLine {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$Default
    )

    foreach ($line in ($Text -split "\r?\n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line.Trim()
        }
    }

    return $Default
}

Main

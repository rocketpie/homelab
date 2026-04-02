#!/usr/bin/pwsh
#Requires -Version 7
<#
    .SYNOPSIS
        make a restic snapshot of all paths defined in the configuration file
#>
[CmdletBinding()]
Param(
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

Set-Variable -Scope Script -Name "ThisFileName" -Value ([System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition))
Set-Variable -Scope Script -Name "ThisFileVersion" -Value "0.4"
"$($thisFileName) $($thisFileVersion)"

function Main {
    Read-ConfigFile

    Test-WriteAccess -Path $Config.log.path
    $logFilePath = Initialize-LogFile -LogPath $Config.log.path

    Test-Restic

    foreach ($item in $config.snapshot) {
        try {
            Test-ReadAccess -Path $item.path

            "starting backup of '$($item.path)' to repository '$($item.resticRepository)'..." | Out-Logged -LogfilePath $logFilePath
            Invoke-ResticBackup -SnapshotItem $item -LogFilePath $logFilePath
        }
        catch {
            "backup failed! path:'$($item.path)'" | Out-Logged -LogfilePath $logFilePath
            Write-LoggedErrorDetails -ErrorRecord $_ -LogFilePath $logFilePath
        }
    }

    Remove-ExpiredLogFiles  *>&1 | Out-Logged -LogfilePath $logFilePath
}

function Test-Restic {
    "testing command 'restic'..."
    if ($null -eq (Get-Command 'restic' -ErrorAction SilentlyContinue)) {
        Write-Error "[ERROR] cannot find command 'restic'"
        return
    }
}

function TrySecureString {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    try { 
        UseSecureString -SerializedValue $Value | Out-Null
    }
    catch {
        $serializedSecureString = ConvertTo-SecureString -String $Value -AsPlainText -Force | ConvertFrom-SecureString
        return [pscustomobject]@{
            Success = $true
            SerializedSecureString = $serializedSecureString
        }
    }

    return [pscustomobject]@{
        Success = $false
    }
}

function UseSecureString {
    [CmdletBinding()]
    param(
        [string]$SerializedValue
    )

    $secureValue = ConvertTo-SecureString -String $SerializedValue -ErrorAction Stop
    return [pscredential]::new('dummy', $secureValue).GetNetworkCredential().Password
}

# read the .json config file
function Read-ConfigFile {
    "reading config file..."

    # Workaround: MyInvocation.MyCommand.Definition only contains the path to this file when it's not dot-loaded
    $configFile = Join-Path $PSScriptRoot "$(Get-Variable -Name "ThisFileName" -ValueOnly).json"
    $schemaFile = Join-Path $PSScriptRoot "$(Get-Variable -Name "ThisFileName" -ValueOnly).schema.json"

    Write-Debug "testing config file schema..."
    Test-Json -LiteralPath $configFile -SchemaFile $schemaFile | Out-Null

    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    Write-Debug "using config from file '$($configFile)'"
    
    $configModified = $false
    foreach ($snapshotItem in $Config.snapshot) {
        $result = TrySecureString -Value $snapshotItem.repositoryPassword
        if (-not $result.Success) {
            continue
        }

        $snapshotItem.repositoryPassword = $result.SerializedSecureString
        $configModified = $true
    }

    if ($configModified) {
        Write-Debug "securing config passwords..."      
        Set-Content -LiteralPath $ConfigFile -Encoding utf8NoBOM -Value ($Config | ConvertTo-Json -Depth 10)
    }

    Set-Variable -Scope Script -Name "Config" -Value $config 
}

function Initialize-LogFile {
    Param(
        [string]$LogPath
    )
    $thisFileName = Get-Variable -Name "ThisFileName" -ValueOnly
    $logFilePath = Join-Path $LogPath "$($thisFileName)-$(Get-Date -AsUTC -Format 'yyyy-MM-dd').log"

    $thisFileVersion = Get-Variable -Name "ThisFileVersion" -ValueOnly
    if (Test-Path $LogfilePath) {
        # a logfile from a previous run on the same day exists. eg. restart, reboot, etc.
        Add-Content -LiteralPath $LogfilePath -Encoding utf8NoBOM -Value "`n$(Join-Path $PSScriptRoot $thisFileName).ps1 $($thisFileVersion)" | Out-Null
    }
    else {
        # create a new file
        Set-Content -LiteralPath $LogfilePath -Encoding utf8NoBOM -Value "$(Join-Path $PSScriptRoot $thisFileName).ps1 $($thisFileVersion)" | Out-Null
    }
    Add-Content -LiteralPath $LogfilePath -Encoding utf8NoBOM -Value "log time $(Get-Date -AsUTC -Format "HH:mm:ss") UTC is $(Get-Date -Format "HH:mm:ss") local time"

    return $logFilePath
}

function Out-Logged {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,

        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )
    
    $InputObject
    Add-Content -LiteralPath $LogFilePath -Encoding utf8NoBOM -Value $InputObject | Out-Null
}

function Write-LoggedText {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    foreach ($line in ($Text -split "\r?\n")) {
        if ($line.Length -eq 0) {
            continue
        }

        $line | Out-Logged -LogfilePath $LogFilePath
    }
}

function Write-LoggedErrorDetails {
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -ne $ErrorRecord.Exception) {
        Write-LoggedText -LogFilePath $LogFilePath -Text $ErrorRecord.Exception.ToString()
    }
    else {
        $formattedError = $ErrorRecord | Format-List * -Force | Out-String
        Write-LoggedText -LogFilePath $LogFilePath -Text $formattedError
    }
}

function Invoke-ResticBackup {
    [CmdletBinding()]
    param(
        [object]$SnapshotItem,
        [string]$LogFilePath
    )

    $resticArguments = @('backup', $SnapshotItem.path)
    $resticIgnoreFiles = Get-ResticIgnoreFiles -Path $SnapshotItem.path
    foreach ($resticIgnoreFile in $resticIgnoreFiles) {
        $resticArguments += '--iexclude-file'
        $resticArguments += $resticIgnoreFile
    }
    if ($null -ne $SnapshotItem.resticBackupOptions) {
        $resticArguments += @($SnapshotItem.resticBackupOptions)
    }

    if ($resticIgnoreFiles.Count -gt 0) {
        "using .backupignore files: $($resticIgnoreFiles -join ', ')" | Out-Logged -LogfilePath $LogFilePath
    }

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = 'restic'
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true
    $processStartInfo.Environment['RESTIC_REPOSITORY'] = [string]$SnapshotItem.resticRepository
    $processStartInfo.Environment['RESTIC_PASSWORD'] = UseSecureString -SerializedValue $SnapshotItem.repositoryPassword

    foreach ($argument in $resticArguments) {
        $processStartInfo.ArgumentList.Add([string]$argument) | Out-Null
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        if (-not $process.Start()) {
            throw "unable to start restic"
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()

        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()

        Write-LoggedText -LogFilePath $LogFilePath -Text $stdoutText
        Write-LoggedText -LogFilePath $LogFilePath -Text $stderrText

        if ($process.ExitCode -ne 0) {
            throw "restic exited with code $($process.ExitCode)"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-ResticIgnoreFiles {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $ignoreFiles = Get-ChildItem -Path $Path -File -Filter '.backupignore' -Depth 1
    Write-Debug "found $($ignoreFiles.Count) .backupignore files in '$($Path)'"
    return $ignoreFiles    
}

function Test-ReadAccess {
    Param(
        $Path
    )
    "testing read access to '$($Path)'..."
    try {
        if (-not (Test-path -LiteralPath $Path -PathType Container)) {
            Write-Error "'$($Path)' does not exist"
            return
        }
        Get-ChildItem -Recurse -LiteralPath $Path -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "cannot read from '$($Path)': $($_.Exception)"
        return
    }
}

# make sure the -Path is a directory, and can be written to
function Test-WriteAccess {
    param (
        [string]$Path
    )
    
    "Test-WriteAccess '$($Path)'..."
    if ((Test-path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "cannot use directory '$($Path)': a file with this path exists." -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        try { 
            New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Error "cannot use directory '$($Path)': no such directory, and unable to create it" -ErrorAction Stop
        }
    }

    $testFile = (Join-Path $Path 'file-write-test-5636bb')
    try {
        New-Item -ItemType File -Path $testFile -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $testFile -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Error "cannot write to directory '$($Path)': $($_.Exception)"
        Remove-Item -LiteralPath $testFile -ErrorAction SilentlyContinue | Out-Null
    }
}

function Remove-ExpiredLogFiles {
    Write-Debug "Remove-ExpiredLogFiles ($($Config.log.retainLogs))..."    
    $allLogfiles = Get-ChildItem -LiteralPath $Config.log.path -File -Filter *.log
    
    $logfileRetentionDuration = [timespan]::Parse($Config.log.retainLogs)
    $expirationThreshold = (Get-Date).Add(-$logfileRetentionDuration)
    $expiredLogfiles = $allLogfiles | Where-Object { $_.LastWriteTime -lt $expirationThreshold }
    foreach ($expiredLogfile in $expiredLogfiles) {
        "removing expired logfile '$($expiredLogfile.Name)'..."
        Remove-Item -LiteralPath $expiredLogfile.FullName
    }
}

Main

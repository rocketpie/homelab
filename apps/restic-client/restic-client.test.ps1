#!/usr/bin/pwsh
#Requires -Version 7
[CmdletBinding()]
Param(
    [switch]$Cleanup,
    [switch]$NoWait
)

Set-StrictMode -Version Latest

if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

$script:TestContext = [PSCustomObject]@{
    NoWait                   = $NoWait
    TestBasePath             = "" # root directory for temporary data, will be created and removed by the tests
    TestRepositoryPath       = "" # (base)/test-repo
    TestResticRepositoryPath = "" # (base)/restic-repo
    TestLogPath              = "" # (base)/logs
    ResticClientPs1          = "" # script under test 
    ConfigFile               = "" # path to the .json config file
    Config                   = $null # deserialized config object

    CurrentTestName          = "" # name of the currently running test, for logging purposes
    CurrentLogFile           = "" # log file for the currently running test
    CurrentResults           = [System.Collections.ArrayList]::new() # assert results of the currently running test
}

$global:ScheduledTaskStore = @{}

function Invoke-Tests([string]$TestFilter) {
    Initialize-TestBasePath
    
    # logging, log retention
    Test_RunSnapshot_UnintializedRepo_EnsureLogging
    Wait 3    
    Test_RunSnapshot_UnintializedRepo_EnsureLogging
     
    # interactive mode
    Test_InteractiveSetEnvironmentVariables_SetsEnvVariables
    Initialize-TestResticRepository
     
    # snapshots
    Test_RunSnapshot_Success
    Test_ShowSnapshots_HasSnapshot
    
    Test_InteractiveRunSnapshot_Success

    # restore
    Test_InteractiveRestore_Success
    
    # snapshot retention
    Test_RunSnapshot_Success
    Test_RunRetention_RemovesFirstSnapshot
    
    # timer 
    Test_EnableTimer_InstallsTimer
    Test_DisableTimer_Success
    
    
    # TODO: test log for WARN: Repository 'test-repo' allows forget, but forgetArgs is empty.

    # TODO: use rest:// repo. if rest repo is used, resticRepository contains access password, ensure it's not logged
    #Invoke-Assert { $logContent -notmatch [regex]::Escape($TestContext.Config.repositories[0].resticRepository) }

    "Done."
    Read-Host "press return to remove test directory..."
    Remove-TestBasePath
}


<#
######## ########  ######  ########  ######
   ##    ##       ##    ##    ##    ##    ##
   ##    ##       ##          ##    ##
   ##    ######    ######     ##     ######
   ##    ##             ##    ##          ##
   ##    ##       ##    ##    ##    ##    ##
   ##    ########  ######     ##     ######
#>
function Test_RunSnapshot_UnintializedRepo_EnsureLogging {

    # minimize retention to test removal
    $TestContext.Config.log.retainLogs = "00:00:00:02"
    
    # write file into test-repo
    $newFilePath = New-TestRepositoryFile -Name 'first-test-file.txt'

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -RunSnapshot | Out-Null
    
    # assert missing repo message was logged
    $logContent = Get-ChildItem $TestContext.TestLogPath -File | Sort-Object -Property CreationTime -Descending | Select-Object -First 1 | Get-Content -Raw
    Invoke-Assert { $logContent -match "Fatal: repository does not exist" }

    # assert log file was created, and previous log files were removed by retention
    Invoke-Assert { @(Get-ChildItem $TestContext.TestLogPath).Count -eq 1 }
        
    # TODO: assert repositoryPassword has been protected with SecureString
    
    Set-ContextConcludeRun
    
    Remove-Item $newFilePath
    Reset-DefaultTestConfig
}


function Test_InteractiveSetEnvironmentVariables_SetsEnvVariables {
    
    # verify / clear restic env vars
    $env:RESTIC_REPOSITORY = $null
    $env:RESTIC_PASSWORD = $null
    
    # pre-dial 'run custom command' 
    $dial = @('5', '1') 
    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial $dial | Add-Content -Path $TestContext.CurrentLogFile

    # check log for success message
    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "snapshots: error" } 
    Invoke-Assert { $env:RESTIC_REPOSITORY -eq $TestContext.Config.repositories[0].resticRepository }
    Invoke-Assert { $env:RESTIC_PASSWORD -eq $TestContext.Config.repositories[0].repositoryPassword }
    
    Set-ContextConcludeRun
}

function Test_RunSnapshot_Success {
    # write file into test-repo
    Set-Content -Path (Join-Path $TestContext.TestRepositoryPath "test-file-$([guid]::NewGuid().ToString().Substring(28)).txt") -Value ([guid]::NewGuid().ToString())
    
    $beforeSnapshots = @(Get-TestSnapshots)
    
    # run 
    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -RunSnapshot | Add-Content -Path $TestContext.CurrentLogFile
    
    # check log for success message
    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Files:\s+1 new" } 
    Invoke-Assert { $logContent -match "snapshot \w+ saved" }
    
    # check snapshot count
    $afterSnapshots = @(Get-TestSnapshots)
    Invoke-Assert { $afterSnapshots.Count -eq ($beforeSnapshots.Count + 1) }
   
    Set-ContextConcludeRun
}

function Test_ShowSnapshots_HasSnapshot {
    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial @('3') | Add-Content -Path $TestContext.CurrentLogFile

    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    $snapshots = @(Get-TestSnapshots)
    Invoke-Assert { $logContent -match "Repository: test-repo" }
    Invoke-Assert { $logContent -match "Allowed: snapshot=True restore=True forget=True" }
    Invoke-Assert { $logContent -match "(?m)^ID\s+Time" }
    Invoke-Assert { $snapshots.Count -ge 1 }

    Set-ContextConcludeRun
}

function Test_InteractiveRunSnapshot_Success {
    $beforeSnapshots = @(Get-TestSnapshots)
    New-TestRepositoryFile -Name 'interactive-test-file.txt' | Out-Null

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial @('1') | Add-Content -Path $TestContext.CurrentLogFile

    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Select an action:" }
    Invoke-Assert { $logContent -match "Starting snapshot for 'test-repo'" }
    Invoke-Assert { $logContent -notmatch [regex]::Escape($TestContext.Config.repositories[0].repositoryPassword) }
    
    $afterSnapshots = @(Get-TestSnapshots)
    Invoke-Assert { $afterSnapshots.Count -eq ($beforeSnapshots.Count + 1) }   

    Set-ContextConcludeRun
}

function Test_InteractiveRestore_Success {
    $restoreFilePath = New-TestRepositoryFile -Name 'restore-test-file.txt'
    & $TestContext.ResticClientPs1 -RunSnapshot | Out-Null
    Remove-Item -Path $restoreFilePath -Force

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial @('4', '1', 'latest') | Add-Content -Path $TestContext.CurrentLogFile

    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Starting restore for 'test-repo' snapshot 'latest'" }
    Invoke-Assert { $logContent -match "Summary:\s+Restored" }
    Invoke-Assert { Test-Path -Path $restoreFilePath }

    Set-ContextConcludeRun
}

function Test_RunRetention_RemovesFirstSnapshot {
    $beforeSnapshots = @(Get-TestSnapshots | Sort-Object { [datetime]$_.time })
    $oldestSnapshotId = $beforeSnapshots[0].id
    $TestContext.Config.repositories[0].forgetArgs = @('--keep-last', '1', '--prune')

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -RunRetention | Add-Content -Path $TestContext.CurrentLogFile

    $afterSnapshots = @(Get-TestSnapshots | Sort-Object { [datetime]$_.time })
    $afterSnapshotIds = @($afterSnapshots | Select-Object -ExpandProperty id)
    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Starting retention for 'test-repo'" }
    Invoke-Assert { $afterSnapshots.Count -eq 1 }
    Invoke-Assert { $afterSnapshotIds -notcontains $oldestSnapshotId }

    Set-ContextConcludeRun
}

function Test_EnableTimer_InstallsTimer {
    if (-not $IsWindows) {
        return
    }

    Reset-ScheduledTaskMocks

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial @('6', '19:00') | Add-Content -Path $TestContext.CurrentLogFile

    $task = $global:ScheduledTaskStore['restic-client-RunSnapshot']
    Invoke-Assert { $null -ne $task }
    Invoke-Assert { ($null -ne $task) -and ($task.Settings.Enabled -eq $true) }
    Invoke-Assert { ($null -ne $task) -and ($task.Actions[0].Argument -match "-RunSnapshot") }

    Set-ContextConcludeRun
}

function Test_DisableTimer_Success {
    if (-not $IsWindows) {
        return
    }

    Reset-ScheduledTaskMocks
    $global:ScheduledTaskStore['restic-client-RunSnapshot'] = New-MockScheduledTask -TaskName 'restic-client-RunSnapshot' -Enabled $true -Time '19:00'

    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -Dial @('7') | Add-Content -Path $TestContext.CurrentLogFile

    $task = $global:ScheduledTaskStore['restic-client-RunSnapshot']
    Invoke-Assert { $null -ne $task }
    Invoke-Assert { ($null -ne $task) -and ($task.Settings.Enabled -eq $false) }

    Set-ContextConcludeRun
}




<#
88  88 888888 88     88""Yb 888888 88""Yb .dP"Y8
88  88 88__   88     88__dP 88__   88__dP `Ybo."
888888 88""   88  .o 88"""  88""   88"Yb  o.`Y8b
88  88 888888 88ood8 88     888888 88  Yb 8bodP'
#>
function Wait([int]$Seconds) {
    "`nwaiting $($Seconds)s..."
    Start-Sleep -Seconds $Seconds
}

function Invoke-TestRestic {
    param(
        [string[]]$ArgumentList,
        [switch]$AllowFailure
    )

    $repository = $TestContext.Config.repositories[0]
    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = [string]$TestContext.Config.resticBinary
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.CreateNoWindow = $true
    $processStartInfo.Environment['RESTIC_REPOSITORY'] = [string]$repository.resticRepository
    $processStartInfo.Environment['RESTIC_PASSWORD'] = [string]$repository.repositoryPassword

    foreach ($argument in $ArgumentList) {
        [void]$processStartInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo

    try {
        if (-not $process.Start()) {
            throw "Unable to start '$($processStartInfo.FileName)'."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        $result = [pscustomobject]@{
            ExitCode       = $process.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError  = $stderrTask.GetAwaiter().GetResult()
        }

        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "restic exited with code $($result.ExitCode)`n$($result.StandardError)"
        }

        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Initialize-TestResticRepository {
    "`nrestic init..."
    Invoke-TestRestic -ArgumentList @('init') | Out-Null
}

function Get-TestSnapshots {
    $result = Invoke-TestRestic -ArgumentList @('snapshots', '--json') -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
        return @()
    }

    return @($result.StandardOutput | ConvertFrom-Json)
}

function New-TestRepositoryFile {
    param(
        [string]$Name,
        [string]$Value = ([guid]::NewGuid().ToString())
    )

    $filePath = Join-Path $TestContext.TestRepositoryPath $Name
    Set-Content -Path $filePath -Value $Value
    return $filePath
}

function Reset-ScheduledTaskMocks {
    $global:ScheduledTaskStore = @{}
}

function New-MockScheduledTask {
    param(
        [string]$TaskName,
        [bool]$Enabled,
        [string]$Time
    )

    return [pscustomobject]@{
        TaskName = $TaskName
        Actions  = @()
        Triggers = @(
            [pscustomobject]@{
                StartBoundary = [datetime]::Today.Add([timespan]::Parse($Time))
            }
        )
        Settings = [pscustomobject]@{
            Enabled = $Enabled
        }
    }
}

function Get-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskName
    )

    if ($global:ScheduledTaskStore.ContainsKey($TaskName)) {
        return $global:ScheduledTaskStore[$TaskName]
    }

    return $null
}

function New-ScheduledTaskAction {
    param(
        [string]$Execute,
        [string]$Argument
    )

    return [pscustomobject]@{
        Execute  = $Execute
        Argument = $Argument
    }
}

function New-ScheduledTaskTrigger {
    param(
        [switch]$Daily,
        [string]$At
    )

    return [pscustomobject]@{
        StartBoundary = [datetime]::Today.Add([timespan]::Parse($At))
    }
}

function New-ScheduledTaskSettingsSet {
    param(
        [switch]$StartWhenAvailable
    )

    return [pscustomobject]@{
        Enabled = $false
    }
}

function Register-ScheduledTask {
    param(
        [string]$TaskPath,
        [string]$TaskName,
        [string]$Description,
        [object]$Action,
        [object]$Trigger,
        [object]$Settings,
        [switch]$Force
    )

    $task = [pscustomobject]@{
        TaskPath    = $TaskPath
        TaskName    = $TaskName
        Description = $Description
        Actions     = @($Action)
        Triggers    = @($Trigger)
        Settings    = [pscustomobject]@{
            Enabled = $true
        }
    }

    $global:ScheduledTaskStore[$TaskName] = $task
    return $task
}

function Set-ScheduledTask {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject
    )

    if ($null -ne $InputObject) {
        $global:ScheduledTaskStore[$InputObject.TaskName] = $InputObject
    }

    return $InputObject
}

$Script:LogCounter = 0
function Set-ContextPrepareRun {
    # update config file
    $TestContext.Config | ConvertTo-Json -Depth 9 | Set-Content -Path $TestContext.ConfigFile

    $Script:LogCounter++
    $TestContext.CurrentTestName = (Get-PSCallStack)[1].Command
    $TestContext.CurrentLogFile = Join-Path $TestContext.TestLogPath ("{0:D2}-$($TestContext.CurrentTestName).log" -f $LogCounter)
    $TestContext.CurrentResults.Clear()

    "`nTEST: $($TestContext.CurrentTestName)"
}

function Invoke-Assert {
    param (
        [scriptblock]$assertScript
    )
    
    $result = & $assertScript
    
    if ($result -and ($result -is [bool])) {
        $TestContext.CurrentResults.Add("   OK: $($assertScript.ToString())") | Out-Null
    }
    else {
        $TestContext.CurrentResults.Add(" FAIL: $($assertScript.ToString()) ($($result.GetType().Name):$($result))") | Out-Null
    }
}

function Set-ContextConcludeRun {
    $TestContext.CurrentResults -join [System.Environment]::NewLine

    $TestContext.CurrentTestName = $null
    $TestContext.CurrentLogFile = $null
    $TestContext.CurrentResults.Clear()
    
    if (-not $TestContext.NoWait) {
        Read-Host "press return to continue..."
    }
}

<#
 ######  ########    ###    ######## ########     ######   #######  ##    ## ######## ########   #######  ##
##    ##    ##      ## ##      ##    ##          ##    ## ##     ## ###   ##    ##    ##     ## ##     ## ##
##          ##     ##   ##     ##    ##          ##       ##     ## ####  ##    ##    ##     ## ##     ## ##
 ######     ##    ##     ##    ##    ######      ##       ##     ## ## ## ##    ##    ########  ##     ## ##
      ##    ##    #########    ##    ##          ##       ##     ## ##  ####    ##    ##   ##   ##     ## ##
##    ##    ##    ##     ##    ##    ##          ##    ## ##     ## ##   ###    ##    ##    ##  ##     ## ##
 ######     ##    ##     ##    ##    ########     ######   #######  ##    ##    ##    ##     ##  #######  ########
#>

function Initialize-TestBasePath {
    $TestContext.TestBasePath = Join-Path $PSScriptRoot 'test'
    $TestContext.TestRepositoryPath = Join-Path $TestContext.TestBasePath 'test-repo'
    $TestContext.TestResticRepositoryPath = Join-Path $TestContext.TestBasePath 'restic-repo'
    $testContext.TestLogPath = Join-Path $TestContext.TestBasePath 'logs'

    "initializing test directory '$($TestContext.TestBasePath)'..."
    Remove-Item $TestContext.TestBasePath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $TestContext.TestBasePath -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory $TestContext.TestRepositoryPath -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory $TestContext.TestResticRepositoryPath -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory $TestContext.TestLogPath -ErrorAction SilentlyContinue | Out-Null

    "copy original script and example config..."
    Copy-Item -Path (Join-Path $PSScriptRoot 'restic-client*.*') -Destination $TestContext.TestBasePath
    Move-Item -path (join-path $testContext.TestBasePath 'restic-client.example.json') -Destination (join-path $TestContext.TestBasePath 'restic-client.json')
    
    $TestContext.ResticClientPs1 = Join-Path $TestContext.TestBasePath 'restic-client.ps1'
    $TestContext.ConfigFile = Join-Path $TestContext.TestBasePath 'restic-client.json'
    "Target: $($TestContext.ResticClientPs1)"
    "Config: $($TestContext.ConfigFile)"
    
    $TestContext.Config = Get-Content -Raw -LiteralPath $TestContext.ConfigFile | ConvertFrom-Json
    Reset-DefaultTestConfig
}

function Remove-TestBasePath {
    $testBasePath = (Join-Path $PSScriptRoot 'test')

    if (($null -ne $TestContext) -and ![string]::IsNullOrWhiteSpace($TestContext.TestBasePath)) {        
        $testBasePath = $TestContext.TestBasePath
    }

    Remove-Item $testBasePath -Recurse -Force -ErrorAction SilentlyContinue
}
    
function Reset-DefaultTestConfig {
    "`nResetting test config to default..."   
    $TestContext.Config.log.path = $TestContext.TestLogPath
    $TestContext.Config.log.retainLogs = "30:00:00:00"
    $TestContext.Config.resticBinary = "restic"
    $TestContext.Config.backupIgnoreFilename = ".backupignore"
    $TestContext.Config.repositories = @(
        @{
            name                = "test-repo"
            path                = $TestContext.TestRepositoryPath
            snapshotAllowed     = $true
            restoreAllowed      = $true
            forgetAllowed       = $true
            resticRepository    = "$($TestContext.TestResticRepositoryPath)"
            repositoryPassword  = [guid]::NewGuid().ToString() 
            backupPreCommand    = ""
            resticBackupOptions = @()
            forgetArgs          = @()
        }
    )
}  


<#
##     ##    ###    #### ##    ##     ######     ###    ##       ##
###   ###   ## ##    ##  ###   ##    ##    ##   ## ##   ##       ##
#### ####  ##   ##   ##  ####  ##    ##        ##   ##  ##       ##
## ### ## ##     ##  ##  ## ## ##    ##       ##     ## ##       ##
##     ## #########  ##  ##  ####    ##       ######### ##       ##
##     ## ##     ##  ##  ##   ###    ##    ## ##     ## ##       ##
##     ## ##     ## #### ##    ##     ######  ##     ## ######## ########
#>

if ($Cleanup) {
    Remove-TestBasePath
    return
}

Invoke-Tests

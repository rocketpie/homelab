#!/usr/bin/pwsh
#Requires -Version 7
[CmdletBinding()]
Param(
    [switch]$Cleanup
)

Set-StrictMode -Version Latest

if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

$script:TestContext = [PSCustomObject]@{
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

function Invoke-Tests([string]$TestFilter) {
    Initialize-TestBasePath

    # snapshots, interactive mode for init
    Test_RunSnapshot_UnintializedRepo_EnsureLogging
    Test_InteractiveSetEnvironmentVariables_SetsEnvVariables
    "restic init..."; 
    restic init | Out-Null
    Test_RunSnapshot_Success
    Test_ShowSnapshots_HasSnapshot
    
    Test_InteractiveRunSnapshot_Success # TODO: also ensure rest secret is protected in repo status output

    # restore
    Test_InteractiveRestore_Success
    
    # retention
    Test_RunSnapshotNow_Success
    Test_RunRetentionNow_RemovesFirstSnapshot
    
    # timer 
    Test_EnableTimer_InstallsTimer
    Test_DisableTimer_Success
    

    # TODO: test log for WARN: Repository 'test-repo' allows forget, but forgetArgs is empty.

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
    
    # write file into test-repo
    Set-Content -Path (Join-Path $TestContext.TestRepositoryPath 'first-test-file.txt') -Value ([guid]::NewGuid().ToString())
    
    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -RunSnapshot | Add-Content -Path $TestContext.CurrentLogFile

    # assert missing repo message was logged
    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Fatal: repository does not exist" }

    # TODO: assert repositoryPassword has been protected with SecureString

    Set-ContextConcludeRun
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
    Set-Content -Path (Join-Path $TestContext.TestRepositoryPath 'first-test-file.txt') -Value ([guid]::NewGuid().ToString())
    
    # run 
    Set-ContextPrepareRun
    & $TestContext.ResticClientPs1 -RunSnapshot | Add-Content -Path $TestContext.CurrentLogFile

    # check log for success message
    $logContent = Get-Content -Path $TestContext.CurrentLogFile -Raw
    Invoke-Assert { $logContent -match "Files:\s+1 new" } 
    Invoke-Assert { $logContent -match "snapshot \w+ saved" }
   
    Set-ContextConcludeRun
}




<#
88  88 888888 88     88""Yb 888888 88""Yb .dP"Y8
88  88 88__   88     88__dP 88__   88__dP `Ybo."
888888 88""   88  .o 88"""  88""   88"Yb  o.`Y8b
88  88 888888 88ood8 88     888888 88  Yb 8bodP'
#>
function Wait([int]$Seconds) {
    "waiting $($Seconds)s..."
    Start-Sleep -Seconds $Seconds
}

function Set-ContextPrepareRun {
    # update config file
    $TestContext.Config | ConvertTo-Json -Depth 9 | Set-Content -Path $TestContext.ConfigFile

    $TestContext.CurrentTestName = (Get-PSCallStack)[1].Command
    $TestContext.CurrentLogFile = Join-Path $TestContext.TestLogPath "$($TestContext.CurrentTestName).log"    
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
    
    Read-Host "press return to continue..."
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

    Remove-Item $testBasePath -Recurse -Force
}
    
function Reset-DefaultTestConfig {
    "Resetting test config to default..."   
    $TestContext.Config.log.path = $TestContext.TestLogPath
    $TestContext.Config.log.retainLogs = "00:00:00:10" # 10 seconds, for testing purposes
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

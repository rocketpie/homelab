#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$Server = "127.0.0.1",
    [string]$LocalTld = "lan",
    [string[]]$LocalNames = @("netcontroller1", "netcontroller2", "n2.pxe.lan"),
    [string]$BlockedDomain = "",
    [switch]$SkipServiceChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "== $Title =="
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }
}

function Get-DigLines([string[]]$Arguments) {
    $digArguments = @("@$Server") + $Arguments
    $result = & dig @digArguments 2>&1
    $lines = @($result | ForEach-Object { "$_" })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines = $lines
    }
}

function Get-DigShort([string]$Name, [string]$Type, [switch]$Tcp) {
    $arguments = @($Name, $Type, "+short", "+time=2", "+tries=1")
    if ($Tcp) {
        $arguments += "+tcp"
    }

    $result = Get-DigLines $arguments
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Lines = $result.Lines
        Answers = @($result.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Test-QueryHasAnswer([string]$Name, [string]$Type) {
    $udpResult = Get-DigShort -Name $Name -Type $Type
    $tcpResult = Get-DigShort -Name $Name -Type $Type -Tcp
    $ok = ($udpResult.ExitCode -eq 0 -and $udpResult.Answers.Count -gt 0) -or ($tcpResult.ExitCode -eq 0 -and $tcpResult.Answers.Count -gt 0)

    $details = @()
    if ($udpResult.ExitCode -eq 0 -and $udpResult.Answers.Count -gt 0) {
        $details += "UDP ok: $($udpResult.Answers -join ', ')"
    }
    elseif ($udpResult.ExitCode -eq 0) {
        $details += "UDP no answer"
    }
    else {
        $details += "UDP failed: $($udpResult.Lines -join ' ')"
    }

    if ($tcpResult.ExitCode -eq 0 -and $tcpResult.Answers.Count -gt 0) {
        $details += "TCP ok: $($tcpResult.Answers -join ', ')"
    }
    elseif ($tcpResult.ExitCode -eq 0) {
        $details += "TCP no answer"
    }
    else {
        $details += "TCP failed: $($tcpResult.Lines -join ' ')"
    }

    [pscustomobject]@{
        Name = $Name
        Type = $Type
        Passed = $ok
        Details = $details -join "; "
    }
}

function Test-LocalRecord([string]$Name) {
    $fqdn = if ($Name.Contains(".")) { $Name } else { "$Name.$LocalTld" }
    return Test-QueryHasAnswer -Name $fqdn -Type "A"
}

function Test-BlockedRecord([string]$Name) {
    $result = Get-DigLines @($Name, "A", "+time=2", "+tries=1")
    $lines = $result.Lines
    $statusLine = $lines | Where-Object { $_ -match "status:" } | Select-Object -First 1
    $answerCountLine = $lines | Where-Object { $_ -match "ANSWER: " } | Select-Object -First 1
    $shortResult = Get-DigShort -Name $Name -Type "A"
    $shortAnswers = $shortResult.Answers

    $looksBlocked = ($result.ExitCode -eq 0) -and (($shortAnswers.Count -eq 0) -or ($statusLine -match "NXDOMAIN") -or ($answerCountLine -match "ANSWER: 0"))

    [pscustomobject]@{
        Name = $Name
        Type = "A"
        Passed = $looksBlocked
        Details = if ($looksBlocked) {
            ($statusLine, $answerCountLine | Where-Object { $_ }) -join "; "
        }
        else {
            if ($result.ExitCode -ne 0) {
                "UDP failed: $($lines -join ' ')"
            }
            else {
                "Unexpected answer: $($shortAnswers -join ', ')"
            }
        }
    }
}

function Show-Result([pscustomobject]$Result) {
    $prefix = if ($Result.Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host ("{0} {1} {2} - {3}" -f $prefix, $Result.Name, $Result.Type, $Result.Details)
}

Require-Command "dig"

$results = New-Object System.Collections.Generic.List[object]

Write-Section "Resolver"
Write-Host "Server: $Server"
Write-Host "Local TLD: $LocalTld"

if (-not $SkipServiceChecks -and $Server -eq "127.0.0.1") {
    Write-Section "Service Checks"

    try {
        & systemctl is-active unbound | Out-Null
        $active = $LASTEXITCODE -eq 0
        $results.Add([pscustomobject]@{
                Name = "unbound"
                Type = "service"
                Passed = $active
                Details = if ($active) { "systemctl reports active" } else { "systemctl did not report active" }
            })
    }
    catch {
        $results.Add([pscustomobject]@{
                Name = "unbound"
                Type = "service"
                Passed = $false
                Details = $_.Exception.Message
            })
    }

    try {
        & unbound-checkconf | Out-Null
        $configOk = $LASTEXITCODE -eq 0
        $results.Add([pscustomobject]@{
                Name = "unbound-checkconf"
                Type = "config"
                Passed = $configOk
                Details = if ($configOk) { "configuration is valid" } else { "configuration check failed" }
            })
    }
    catch {
        $results.Add([pscustomobject]@{
                Name = "unbound-checkconf"
                Type = "config"
                Passed = $false
                Details = $_.Exception.Message
            })
    }
}

Write-Section "Recursive DNS"
$results.Add((Test-QueryHasAnswer -Name "google.com" -Type "A"))
$results.Add((Test-QueryHasAnswer -Name "google.com" -Type "AAAA"))
$results.Add((Test-QueryHasAnswer -Name "cloudflare.com" -Type "NS"))

Write-Section "Local DNS"
foreach ($name in $LocalNames) {
    $results.Add((Test-LocalRecord -Name $name))
}

if (-not [string]::IsNullOrWhiteSpace($BlockedDomain)) {
    Write-Section "Blocklist"
    $results.Add((Test-BlockedRecord -Name $BlockedDomain))
}

Write-Section "Results"
foreach ($result in $results) {
    Show-Result -Result $result
}

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "All DNS checks passed."
    exit 0
}

Write-Host ("{0} DNS check(s) failed." -f $failed.Count)
exit 1

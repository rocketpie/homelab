#!/usr/bin/env pwsh
#Requires -Version 7

[CmdletBinding()]
param(
    [string]$Server = "127.0.0.1",
    [string]$LocalTld = "lan",
    [string[]]$LocalNames = @("netcontroller1", "netcontroller2", "n2.pxe"),
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
    if ($LASTEXITCODE -ne 0) {
        throw "dig failed: $($lines -join [Environment]::NewLine)"
    }
    return $lines
}

function Get-DigShort([string]$Name, [string]$Type) {
    $lines = Get-DigLines @($Name, $Type, "+short")
    return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-QueryHasAnswer([string]$Name, [string]$Type) {
    $answers = Get-DigShort -Name $Name -Type $Type
    $ok = $answers.Count -gt 0

    [pscustomobject]@{
        Name = $Name
        Type = $Type
        Passed = $ok
        Details = if ($ok) { $answers -join ", " } else { "No answer returned" }
    }
}

function Test-LocalRecord([string]$Name) {
    $fqdn = if ($Name.Contains(".")) { $Name } else { "$Name.$LocalTld" }
    return Test-QueryHasAnswer -Name $fqdn -Type "A"
}

function Test-BlockedRecord([string]$Name) {
    $lines = Get-DigLines @($Name, "A")
    $statusLine = $lines | Where-Object { $_ -match "status:" } | Select-Object -First 1
    $answerCountLine = $lines | Where-Object { $_ -match "ANSWER: " } | Select-Object -First 1
    $shortAnswers = Get-DigShort -Name $Name -Type "A"

    $looksBlocked = ($shortAnswers.Count -eq 0) -or ($statusLine -match "NXDOMAIN") -or ($answerCountLine -match "ANSWER: 0")

    [pscustomobject]@{
        Name = $Name
        Type = "A"
        Passed = $looksBlocked
        Details = if ($looksBlocked) {
            ($statusLine, $answerCountLine | Where-Object { $_ }) -join "; "
        }
        else {
            "Unexpected answer: $($shortAnswers -join ', ')"
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

#!/usr/bin/pwsh
#Requires -Version 7
<#
    .SYNOPSIS
        make a restic snapshot of all paths defined in the configuration file
#>
[CmdletBinding()]
Param(
    [ValidateSet('vpn', 'lan')]
    [string]$NetworkType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

Set-Variable -Scope Script -Name "ThisFileName" -Value ([System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition))
Set-Variable -Scope Script -Name "ThisFileVersion" -Value "0.1"
"$($thisFileName) $($thisFileVersion)"

function Main {
    $configFile = Join-Path $PSScriptRoot "New-ResticSnapshot.json"
    if (-not (Test-Path $configFile)) {
        throw "Configuration file not found: $($configFile)"
    }

    $config = Get-Content -Path $configFile -Raw
    $allMatches = [regex]::Matches($config, '"(rest:https?://\S+:\S+@)([^/:]+)(:\d+)?(/\S+)"')
    
    Write-Debug "found $($allMatches.Count) 'rest:http...' matches in $($configFile)"
    
    foreach ($match in $allMatches) {
        $fullHostname = $match.Groups[2].Value
        $hostname = ($fullHostname -replace '\.vpn', '') -replace '\.lan', ''
        switch ($NetworkType) {
            'vpn' {
                $newHostname = "$($hostname).vpn.lan"
            }
            'lan' {
                $newHostname = "$($hostname).lan"
            }
        }
        $newUrlString = "`"$($match.Groups[1].Value)$($newHostname)$($match.Groups[3].Value)$($match.Groups[4].Value)`""
        "Updating URL: $($match.Groups[2].Value) -> $($newHostname)"
        $config = $config.Replace($match.Value, $newUrlString)

        Set-Content -Path $configFile -Value $config
    }
}

Main

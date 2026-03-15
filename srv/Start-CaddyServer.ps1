#Requires -Version 7
Push-Location $PSScriptRoot
.\caddy_windows_amd64.exe start   # run in background
#.\caddy_windows_amd64.exe run     # run foreground/blocking
Pop-Location
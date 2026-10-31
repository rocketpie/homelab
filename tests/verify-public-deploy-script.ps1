#!/usr/bin/env pwsh
#Requires -Version 7

# Goals:
# - Render the add_website public-deploy.sh template with the same Ansible
#   templating that runs on the gateway.
# - Exercise the rendered script against fake docker/zstd binaries on PATH, so
#   the test needs no Docker daemon, gateway, or network access.
# - Verify the deploy safety rules: consume the marker first, verify an optional
#   checksum, require the exact image tag and labels, keep the archive on
#   failure, delete it only after a successful restart, and prune after success.
# - Cover no marker, missing archive, checksum mismatch, wrong tag, wrong
#   labels, load failure, service not selected in compose, and a full deploy.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$templatePath = Join-Path $repoRoot "playbooks/roles/add_website/templates/public-deploy.sh.j2"

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }
}

function Write-UnixText([string]$Path, [string]$Content) {
    $normalized = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized)
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$CaseName) {
    if (-not $Text.Contains($Needle)) {
        throw "[$CaseName] expected output to contain '$Needle'. Output:`n$Text"
    }
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$CaseName) {
    if ($Text.Contains($Needle)) {
        throw "[$CaseName] expected output to not contain '$Needle'. Output:`n$Text"
    }
}

function Invoke-DeployScript {
    $output = & bash $scriptPath 2>&1 | Out-String
    return [pscustomobject]@{
        Output = $output
        ExitCode = $LASTEXITCODE
    }
}

function Get-DockerLog {
    $raw = Get-Content -LiteralPath $dockerLog -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) {
        return ""
    }
    return $raw
}

function Reset-DeployState {
    Get-ChildItem -LiteralPath $triggerDir -Filter "*.restart" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force

    if (Test-Path -LiteralPath $serviceDir) {
        Remove-Item -LiteralPath $serviceDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null

    [System.IO.File]::WriteAllText($dockerLog, "")

    foreach ($name in @(
            "FAKE_DOCKER_LOAD_OUTPUT",
            "FAKE_DOCKER_LOAD_RC",
            "FAKE_DOCKER_LABELS",
            "FAKE_DOCKER_SERVICES",
            "FAKE_DOCKER_UP_RC"
        )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }

    $env:FAKE_DOCKER_LOG = $dockerLog
    $env:FAKE_DOCKER_SERVICES = "website"
    $env:FAKE_DOCKER_LOAD_OUTPUT = "Loaded image: homelab/website:latest"
    $env:FAKE_DOCKER_LABELS = "public|website"
    $env:FAKE_DOCKER_LOAD_RC = "0"
    $env:FAKE_DOCKER_UP_RC = "0"
}

function New-Archive([string]$Name = "website") {
    $archivePath = Join-Path $serviceDir "$Name.tar.zst"
    Write-UnixText $archivePath "fake image archive"
    return $archivePath
}

function New-Marker([string]$Name = "website") {
    New-Item -ItemType File -Path (Join-Path $triggerDir "$Name.restart") -Force | Out-Null
}

function New-Checksum([string]$ArchivePath, [bool]$Valid) {
    if ($Valid) {
        $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    else {
        $hash = "0" * 64
    }

    $fileName = Split-Path -Leaf $ArchivePath
    Write-UnixText "$ArchivePath.sha256" "$hash  $fileName`n"
}

Assert-Command "ansible-playbook"
Assert-Command "bash"
Assert-Command "chmod"

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("public-deploy-" + [guid]::NewGuid().ToString("N"))
$projectDir = Join-Path $workRoot "project"
$triggerDir = Join-Path $projectDir "triggers"
$serviceDir = Join-Path $projectDir "website"
$fakeBin = Join-Path $workRoot "bin"
$dockerLog = Join-Path $workRoot "docker.log"
$scriptPath = Join-Path $workRoot "public-deploy"
$renderPlaybook = Join-Path $workRoot "render.yml"

New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

$oldPath = $env:PATH

try {
    $render = @"
---
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    add_website_project_dir: '$projectDir'
    add_website_trigger_dir: '$triggerDir'
    add_website_compose_file: '$projectDir/docker-compose.yml'
    add_website_image_prefix: homelab
  tasks:
    - name: Render the public deploy script
      ansible.builtin.template:
        src: '$templatePath'
        dest: '$scriptPath'
        mode: '0755'
"@
    Write-UnixText $renderPlaybook $render

    $renderOutput = & ansible-playbook -i "localhost," -c local $renderPlaybook 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to render the public deploy script:`n$renderOutput"
    }

    $rendered = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True $rendered.Contains($projectDir) "Rendered deploy script does not contain the project directory."

    $fakeDocker = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  compose)
    case "$sub" in
      config) printf '%s\n' "${FAKE_DOCKER_SERVICES:-website}"; exit 0 ;;
      up) exit "${FAKE_DOCKER_UP_RC:-0}" ;;
    esac
    ;;
  load)
    if [ -n "${FAKE_DOCKER_LOAD_OUTPUT:-}" ]; then printf '%s\n' "$FAKE_DOCKER_LOAD_OUTPUT"; fi
    exit "${FAKE_DOCKER_LOAD_RC:-0}"
    ;;
  image)
    case "$sub" in
      inspect) printf '%s\n' "${FAKE_DOCKER_LABELS:-public|website}"; exit 0 ;;
      rm|prune) exit 0 ;;
    esac
    ;;
esac
exit 0
'@
    $fakeZstd = @'
#!/usr/bin/env bash
# The fake docker load does not read stdin; consume nothing and succeed.
exit 0
'@

    $fakeDockerPath = Join-Path $fakeBin "docker"
    $fakeZstdPath = Join-Path $fakeBin "zstd"
    Write-UnixText $fakeDockerPath $fakeDocker
    Write-UnixText $fakeZstdPath $fakeZstd
    & chmod 0755 $fakeDockerPath $fakeZstdPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to make fake docker/zstd executable."
    }

    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$oldPath"

    # 1. No marker: nothing runs.
    Reset-DeployState
    New-Archive | Out-Null
    $result = Invoke-DeployScript
    Assert-True ($result.ExitCode -eq 0) "missing marker: expected exit 0, got $($result.ExitCode)"
    Assert-True ((Get-DockerLog).Trim().Length -eq 0) "missing marker: docker must not run"
    Write-Host "[ok] missing marker does nothing"

    # 2. Marker without archive: marker is consumed and no load happens.
    Reset-DeployState
    New-Marker
    $result = Invoke-DeployScript
    Assert-True ($result.ExitCode -eq 0) "missing archive: expected exit 0, got $($result.ExitCode)"
    Assert-Contains $result.Output "skipping website: missing" "missing archive"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $triggerDir "website.restart"))) "missing archive: marker was not consumed"
    Assert-NotContains (Get-DockerLog) "load" "missing archive"
    Write-Host "[ok] missing archive consumes the marker"

    # 3. Checksum mismatch: no load, archive kept.
    Reset-DeployState
    $archive = New-Archive
    New-Checksum $archive $false
    New-Marker
    $result = Invoke-DeployScript
    Assert-Contains $result.Output "checksum mismatch" "checksum mismatch"
    Assert-True (Test-Path -LiteralPath $archive) "checksum mismatch: archive must be kept"
    Assert-NotContains (Get-DockerLog) "load" "checksum mismatch"
    Write-Host "[ok] checksum mismatch is rejected"

    # 4. Archive with the wrong tag is rejected and pruned.
    Reset-DeployState
    $archive = New-Archive
    New-Marker
    $env:FAKE_DOCKER_LOAD_OUTPUT = "Loaded image: homelab/other:latest"
    $result = Invoke-DeployScript
    Assert-Contains $result.Output "archive did not contain homelab/website:latest" "wrong tag"
    Assert-True (Test-Path -LiteralPath $archive) "wrong tag: archive must be kept"
    Assert-Contains (Get-DockerLog) "image prune -af --filter label=com.co3d.service=public" "wrong tag"
    Write-Host "[ok] wrong archive tag is rejected"

    # 5. Wrong labels are rejected and the loaded image is removed.
    Reset-DeployState
    $archive = New-Archive
    New-Marker
    $env:FAKE_DOCKER_LABELS = "public|other"
    $result = Invoke-DeployScript
    Assert-Contains $result.Output "expected labels public|website" "wrong labels"
    Assert-True (Test-Path -LiteralPath $archive) "wrong labels: archive must be kept"
    Assert-Contains (Get-DockerLog) "image rm homelab/website:latest" "wrong labels"
    Write-Host "[ok] wrong image labels are rejected"

    # 6. Load failure: no restart, archive kept.
    Reset-DeployState
    $archive = New-Archive
    New-Marker
    $env:FAKE_DOCKER_LOAD_RC = "1"
    $result = Invoke-DeployScript
    Assert-Contains $result.Output "docker load failed" "load failure"
    Assert-True (Test-Path -LiteralPath $archive) "load failure: archive must be kept"
    Assert-NotContains (Get-DockerLog) "compose up" "load failure"
    Write-Host "[ok] load failure keeps the archive"

    # 7. A service missing from the compose file is rejected before loading.
    Reset-DeployState
    $archive = New-Archive
    New-Marker
    $env:FAKE_DOCKER_SERVICES = "lobby"
    $result = Invoke-DeployScript
    Assert-Contains $result.Output "not a service" "unknown service"
    Assert-True (Test-Path -LiteralPath $archive) "unknown service: archive must be kept"
    Assert-NotContains (Get-DockerLog) "load" "unknown service"
    Write-Host "[ok] service missing from compose is rejected"

    # 8. Successful deploy: load, restart, prune, delete archive and marker.
    Reset-DeployState
    $archive = New-Archive
    New-Checksum $archive $true
    New-Marker
    $result = Invoke-DeployScript
    Assert-True ($result.ExitCode -eq 0) "success: expected exit 0, got $($result.ExitCode)"
    Assert-Contains $result.Output "loading website" "success"
    Assert-Contains $result.Output "restarting website" "success"
    Assert-Contains $result.Output "website deploy complete" "success"
    Assert-True (-not (Test-Path -LiteralPath $archive)) "success: archive must be deleted"
    Assert-True (-not (Test-Path -LiteralPath "$archive.sha256")) "success: checksum file must be deleted"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $triggerDir "website.restart"))) "success: marker must be consumed"

    $dockerCalls = Get-DockerLog
    Assert-Contains $dockerCalls "compose up -d --no-deps --force-recreate website" "success"
    Assert-Contains $dockerCalls "image prune -af --filter label=com.co3d.service=public" "success"
    Assert-Contains $dockerCalls "image prune -f" "success"

    # Running again without a marker must not call docker or recreate containers.
    [System.IO.File]::WriteAllText($dockerLog, "")
    $secondRun = Invoke-DeployScript
    Assert-True ($secondRun.ExitCode -eq 0) "second run: expected exit 0"
    Assert-True ((Get-DockerLog).Trim().Length -eq 0) "second run: marker must be consumed exactly once"
    Write-Host "[ok] successful deploy loads, restarts, prunes, and deletes the archive"

    Write-Host "public deploy script verification passed"
}
finally {
    $env:PATH = $oldPath
    foreach ($name in @(
            "FAKE_DOCKER_LOG",
            "FAKE_DOCKER_LOAD_OUTPUT",
            "FAKE_DOCKER_LOAD_RC",
            "FAKE_DOCKER_LABELS",
            "FAKE_DOCKER_SERVICES",
            "FAKE_DOCKER_UP_RC"
        )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

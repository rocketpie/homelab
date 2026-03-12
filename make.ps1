# Make.ps1
# PowerShell 7+ (pwsh) on Linux recommended.

[CmdletBinding(DefaultParameterSetName = "Help")]
param(
    [Parameter(ParameterSetName = "Help")]
    [switch]$Help,

    [Parameter(ParameterSetName = "Install")]
    [switch]$Install,

    # a.k.a. "Restore"?
    [Parameter(ParameterSetName = "Setup")]
    [switch]$Setup,

    [Parameter(ParameterSetName = "Build")]
    [switch]$Build,

    [Parameter(ParameterSetName = "Run")]
    [switch]$Run,

    # For -Run
    [Parameter(ParameterSetName = "Run", Position = 0)]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $inventoriesPath = Join-Path $PSScriptRoot "inventories"
            if (-not (Test-Path $inventoriesPath)) { return }

            Get-ChildItem -Path $inventoriesPath -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name } |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
        })]
    [string]$EnvName,

    [Parameter(ParameterSetName = "Run", Position = 1)]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $playbooksPath = Join-Path $PSScriptRoot "playbooks"
            if (-not (Test-Path $playbooksPath)) { return }

            Get-ChildItem -Path $playbooksPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".yml", ".yaml" } |
            ForEach-Object { $_.Name } |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
        })]
    [string]$Playbook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Targets {
    Write-Host "Targets:"
    Write-Host "  -Help                  Show this help (default)"
    Write-Host "  -Install               apt install python3.10-venv python3-pip sshpass; pip install uv"
    Write-Host "  -Setup                 Create venv; install requirements via uv; create .collections; install community.general"
    Write-Host "  -Build                 Run yamllint + ansible-lint on /inventories and /playbooks"
    Write-Host "  -Run <env> <playbook>  Prompt for vault pass, set env; run playbook with inventories/<env>/hosts.yml"
}

Set-Variable -Scope Script -Name 'vEnvPath' -Value (Join-Path $PSScriptRoot ".venv")
Set-Variable -Scope Script -Name 'vEnvPython' -Value (Join-Path $vEnvPath "bin/python")
Set-Variable -Scope Script -Name 'vEnvPip' -Value (Join-Path $vEnvPath "bin/pip")
Set-Variable -Scope Script -Name 'vEnvAnsiblePlaybook' -Value (Join-Path $vEnvPath "bin/ansible-playbook")
Set-Variable -Scope Script -Name 'vEnvAnsibleGalaxy' -Value (Join-Path $vEnvPath "bin/ansible-galaxy")
Set-Variable -Scope Script -Name 'vEnvRequirements' -Value (Join-Path $PSScriptRoot "venv-requirements.txt")
Set-Variable -Scope Script -Name 'ansibleCollectionsDir' -Value (Join-Path $PSScriptRoot ".collections")
Set-Variable -Scope Script -Name 'collectionsRequirements' -Value (Join-Path $PSScriptRoot "collection-requirements.txt")
Set-Variable -Scope Script -Name 'vaultPasswordScript' -Value (Join-Path $PSScriptRoot "vault_pass.ps1")


function Main {
    switch ($PSCmdlet.ParameterSetName) {
        default {
            Write-Targets
        }
        "Help" {
            Write-Targets
        }
        
        "Install" {
            Install-AptDeps
            Install-UvGlobal
        }
        "Setup" {
            Require-Command "uv"
            Setup-Venv
        }
        "Build" {
            Build-Checks
        }
        "Run" {
            Run-Playbook -EnvironmentName $EnvName -PlaybookName $Playbook
        }  
    }

    "Done."
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: '$Name' not found on PATH."
    }
}

function Ensure-Venv {
    if (-not (Test-Path $vEnvPython)) {
        Require-Command "python3"
        Write-Host "Creating venv at $vEnvPath"
        & python3 -m venv $vEnvPath
    }
}

function Ensure-vEnvRequirements {
    if (-not (Test-Path $vEnvRequirements)) {
        throw "Missing $vEnvRequirements (expected dev requirements)."
    }
}

function Ensure-ToolsInVenv {
    if (-not (Test-Path $vEnvAnsiblePlaybook)) {
        throw "ansible-playbook not found in venv. Did you run -Setup?"
    }
}

function Install-AptDeps {
    Require-Command "sudo"
    Require-Command "apt-get"
    Write-Host "apt-get install -y python3.10-venv python3-pip sshpass..."
    & sudo apt-get update
    & sudo apt-get install -y python3.10-venv python3-pip sshpass
}

function Install-UvGlobal {
    Require-Command "python3"
    Require-Command "pip3"
    
    Write-Host "installing uv using pip (https://docs.astral.sh/uv/)..."
    pip3 install uv
    
    Write-Host "adding uv to PATH (python3 -m uv tool update-shell)..."
    python3 -m uv tool update-shell    

    Write-Host "uv installed globally. restart your shell for PATH changes to take effect."
}

function Setup-Venv {
    Ensure-Venv
    Ensure-vEnvRequirements
    Require-Command "uv"

    Write-Host "Installing Python requirements into venv using uv..."
    uv pip install --python $vEnvPython -r $vEnvRequirements

    Write-Host "Ensuring collections directory: $ansibleCollectionsDir"
    New-Item -ItemType Directory -Force -Path $ansibleCollectionsDir | Out-Null

   $requirements = @(get-content $collectionsRequirements)
foreach ($requirement in $requirements) {
    Write-Host "Installing Ansible collection $($requirement)..."
    & $vEnvAnsibleGalaxy collection install -p $ansibleCollectionsDir $requirement
}
}

function Build-Checks {
    Ensure-Venv
    Ensure-ToolsInVenv

    $yamllint = Join-Path $vEnvPath "bin/yamllint"
    $ansibleLint = Join-Path $vEnvPath "bin/ansible-lint"

    if (-not (Test-Path $yamllint)) { throw "yamllint not found in venv. Ensure it's in $vEnvRequirements and run -Setup." }
    if (-not (Test-Path $ansibleLint)) { throw "ansible-lint not found in venv. Ensure it's in $vEnvRequirements and run -Setup." }

    $inventoriesPath = Join-Path $PSScriptRoot "inventories"
    $playbooksPath = Join-Path $PSScriptRoot "playbooks"

    if (-not (Test-Path $inventoriesPath)) { throw "Missing path: $inventoriesPath" }
    if (-not (Test-Path $playbooksPath)) { throw "Missing path: $playbooksPath" }

    Write-Host "Running yamllint on inventories/ and playbooks/ ..."
    & $yamllint $inventoriesPath
    & $yamllint $playbooksPath

    Write-Host "Running ansible-lint on inventories/ and playbooks/ ..."
    & $ansibleLint $inventoriesPath
    & $ansibleLint $playbooksPath
}

function Run-Playbook([string]$EnvironmentName, [string]$PlaybookName) {
    if ([string]::IsNullOrWhiteSpace($EnvironmentName) -or [string]::IsNullOrWhiteSpace($PlaybookName)) {
        throw "Usage: ./Make.ps1 -Run <env> <playbook.yml>"
    }

    Ensure-Venv
    Ensure-ToolsInVenv

    $inventory = Join-Path $PSScriptRoot ("inventories/{0}/hosts.yml" -f $EnvironmentName)
    if (-not (Test-Path $inventory)) {
        throw "Inventory not found: $inventory"
    }

    $playbookPath = Join-Path $PSScriptRoot ("playbooks/{0}" -f $PlaybookName)
    if (-not (Test-Path $playbookPath)) {
        throw "Playbook not found: $playbookPath"
    }

    $vaultPassword = $env:ANSIBLE_VAULT_PASSWORD
    if ([string]::IsNullOrWhiteSpace($vaultPassword)) {
        $vaultPassword = Read-Host -Prompt "Ansible Vault password?"
        $env:ANSIBLE_VAULT_PASSWORD = $vaultPassword
    }

    Write-Host "Running: $playbookPath (inventory: $inventory)"
    & $vEnvAnsiblePlaybook -i $inventory $playbookPath --vault-password-file $vaultPasswordScript
}


Main
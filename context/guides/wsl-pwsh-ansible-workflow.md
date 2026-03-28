# WSL PowerShell Ansible Workflow

Use this repo from inside WSL.

Recommended shell flow:
1. Activate `.venv`
2. Start `pwsh`
3. Run `./run.ps1 <playbook.yml>`

Why:
- the repo uses Linux-style tool paths inside `.venv`
- the shared Ansible SSH key lives at `~/.ssh/ansible`
- `run.ps1` bootstraps `ssh-agent` for the current PowerShell session when `SSH_AUTH_SOCK` is missing

Notes:
- `run.ps1` still prompts for the SSH key passphrase when the key is not yet loaded
- once loaded into `ssh-agent`, parallel SSH connections are much more reliable

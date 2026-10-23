# Build / CI
- wire the `tests/verify-*.ps1` checks into the build/CI path; `build.ps1` currently only runs `ansible-lint`.
- `tests/verify-public-gateway-config.ps1` is manual and intentionally fails while example placeholders are present, so give it an explicit opt-in/skip flag before it runs unattended.
- make the cross-host route hostname uniqueness check fail before SSH; keep the per-host runtime assert in `add_vpn_gateway`.

# long-term image update strategy?

# Dev Container
- [x] how to handle ansible ssh key? vault files? (see context/guides/environment-switching.md)
- [x] some changes for Set-Environment:
    - please add tab completion / autocomplete for the available environments during switch. 
    - remove EnvRoot, RuntimeDir parameters. Here, i prefer static variables that can be overriden with an environment variable if needed. 
    - remove Create parameter. auto-create environments that don't exist and report.
    - remove Status and List parameters. both can be done automatic after showing help without any parameters.
        > Set-Environment.ps1
        (helptext)
        (available environments)
        (current status)
- [] environment-switching.md: **"Refusing plaintext vault file"** — encrypt the file with `ansible-vault` before switching.
    why not auto-encrypt?

- devcontainer verified. Remove the legacy WSL setup route, wsl, python, ansible etc. setup and interactive key handling from all init / run etc. scripts.

- move venv-requirements.txt collection-requirements.txt to .devcontainer?


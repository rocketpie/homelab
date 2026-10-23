# VPN Gateway Setup
- add_firewall task says 
    'Allow HTTP and HTTPS TCP ports through the firewall' and 
    'Allow HTTP/3 and other configured UDP ports through the firewall'
    etc. 
    BUT: the actual ports come from defaults, may not translate to HTTP, HTTPS, HTTP/3
- add_vpn_gateway 'Assert vpn_gateway route hostnames are unique' - smells config validation - which should be build-time, not runtime. check.
- add_website defaults add_website_publish_bind see comment
- check / remove add-website publishing content from the ansible host

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


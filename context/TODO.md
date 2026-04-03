# renaming:
    'kea' inventory role -> 'dhcp'
    'unbound' inventory rule -> 'dns-resolver'
    'configure_disks' role -> 'set_vm_disks'
    'configure-netcontroller' play -> 'set-dns'

# rest-server-role.md TODO
- add a second-stage smoke test that uses the `restic` CLI to create a
  disposable repository, write one backup, list snapshots, and restore it
  again once this repo has a proper way to install `restic` for tests

# VPN and VPN DNS
    - .vpn names must always resolve to the hosts vpn overlay ip, not the local ip.
    - add the netcontrollers to the vpn as dns resolvers
    - add vpn client install to all VMs.

# duplicate documentation 
- restic-retention-role.md
    -> focus on role function details
- use-restic-server.md / Server-side retention config
    -> focus on extending the config, like adding a new repo or changing retention

# restic client log
    - process runtime output live streaming to the console
    - DEBUG_LOG=restic-debug.log

# context/restic-client scheduling
    - make script interactive
    - show snapshots
    - add / remove scheduled task option

# restic server play
    - add extensive testing, including restic repository access / restore and backup
    since this is frequently re-run when adding htaccess users.
    maybe handle user changes differently?

# docker hostname binding
    - to the docker role, add a haproxy reverse proxy
    - bind to dns_aliases, forward to container ports (set where?) 

# adding restic client repo guide
    - restic1/host.yml/add_restic_retention_repositories
    - restic1/vault.yml/add_restic_server_htpasswd_entries
    - repo init 
```bash
set -a
source /etc/restic-client/repos.d/paperless.env
restic init
```

# vault template handling
    - add a function to build.ps1, that:
        - reads all vault.yml files
        - replaces all values and list items with a static placeholder
        - replaces the host.yml template comment with the generated placeholder.
    this way, we keep the template and the vaults in sync, without exposing secrets.


# Lint
Running ansible-lint...
WARNING  Listing 2 violation(s) that are fatal
load-failure[not-found]: File or directory not found. (warning)
context/guides/docker-reverse-proxy.md:1

no-handler: Tasks that run when changed should likely be handlers.
playbooks/roles/set_vm_network/tasks/main.yml:42:13 Task/Handler: Flush netplan apply handler
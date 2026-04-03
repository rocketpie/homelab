# renaming:
    'kea' inventory role -> 'dhcp'
    'unbound' inventory rule -> 'dns-resolver'
    'configure_disks' role -> 'set_vm_disks'

# rest-server-role.md TODO
- add a second-stage smoke test that uses the `restic` CLI to create a
  disposable repository, write one backup, list snapshots, and restore it
  again once this repo has a proper way to install `restic` for tests


# duplicate documentation 
- restic-retention-role.md
    -> focus on role function details
- use-restic-server.md / Server-side retention config
    -> focus on extending the config, like adding a new repo or changing retention

# restic client log
    - process runtime output live streaming to the console
    - DEBUG_LOG=restic-debug.log

# restic server play
    - add extensive testing, including restic repository access / restore and backup
    since this is frequently re-run when adding htaccess users.
    maybe handle user changes differently?

# docker hostname binding
    - to the docker role, add a haproxy reverse proxy
    - bind to dns_aliases, forward to container ports (set where?) 

# adding restic client repo
    - restic1/host.yml/add_restic_retention_repositories
    - restic1/vault.yml/add_restic_server_htpasswd_entries
    - repo init 
```bash
set -a
source /etc/restic-client/repos.d/paperless.env
restic init
```
# renaming:
    'kea' inventory role -> 'dhcp'
    'unbound' inventory rule -> 'dns-resolver'
    'configure_disks' role -> 'set_vm_disks'
    'configure-netcontroller' play -> 'set-dns'
    'add-rest-server' play -> 'add-restic-server'

# all VMs
    MOTD
        remove 10-help-text
        add /media/DISK usage info after 50-landscape-sysinfo
        remove 50-motd-news
        move host-status here, link home/user/host-status here.

# duplicate documentation 
- restic-retention-role.md
    -> focus on role function details
- use-restic-server.md / Server-side retention config
    -> focus on extending the config, like adding a new repo or changing retention

# restic 
## server play
    - add extensive testing, including restic repository access / restore and backup
    - make sure to check if all existing repos on the host 
    have a matching add_restic_retention_repositories
    - make sure all add_restic_retention_repositories have a add_restic_retention_repository_passwords
    - log retention application
    - improve retention application service
        - service script is repo specific.
        it should read config file(s) which contain repository details.
    -         

## client 
    - update (0.16.4 is < 2024!)
        - 0.17
            - skip-if-unchanged
            - reduces prune memory use
            - report snapshot size

## add guide 'adding a client repo'
    - restic1/host.yml/add_restic_retention_repositories
    - restic1/vault.yml/add_restic_server_htpasswd_entries
    - repo init 
```bash
set -a
source /etc/restic-client/repos.d/paperless.env
restic init
```

# add-docker 
    - daily scan active container versions
    - log changes

# add ansible execution vm
    - play should focus:
        - add install pwsh role
        - git clone repository in host user home    
    - do *not* create missing local `vault.yml` files.
    - remove other clutter


# Lint
Running ansible-lint...
WARNING  Listing 3 violation(s) that are fatal
no-changed-when: Commands should not change things if nothing needs doing.
playbooks/roles/add_docker/tasks/main.yml:171 Task/Handler: Refresh host CA trust store

yaml[line-length]: Line too long (161 > 160 characters)
playbooks/roles/add_immich/defaults/main.yml:21

no-handler: Tasks that run when changed should likely be handlers.
playbooks/roles/set_vm_network/tasks/main.yml:42:13 Task/Handler: Flush netplan apply handler


# warnings
TASK [add_rclone : Validate host platform for rclone install] ***********************************************************************
[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.
Origin: /home/talos/homelab/playbooks/roles/add_rclone/tasks/main.yml:5:9

3   ansible.builtin.assert:
4     that:
5       - ansible_system == 'Linux'
          ^ column 9

Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.

[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.
Origin: /home/talos/homelab/playbooks/roles/add_rclone/tasks/main.yml:6:9

4     that:
5       - ansible_system == 'Linux'
6       - ansible_architecture in ['x86_64', 'amd64']
          ^ column 9

Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.



# debug, test immich restore

encoded-video (readable and writable)
library (readable and writable)
upload (readable and writable)
profile (readable and writable)
thumbs (readable and writable)
backups (readable and writable)
encoded-video has 2 folder(s)
library is missing files!
    Using storage template? You may be missing files
upload has 2 folder(s)
profile is missing files!
    You may be missing important files
thumbs has 2 folder(s)

second error:
Error: /usr/lib/postgresql/14/bin/psql non-zero exit code (3)
ERROR:  DROP DATABASE cannot run inside a transaction block


# User updates
    - set-vm-user.yml 
        update user passwords, ssh keys


# paperless: reverse-proxy CSRF Issues
    - when recovering, initial user setup fails.
    regular login fails as well.
    only when connected to https://paperless.lan/ 
    with 'CSRF verification failed. Request aborted.'

    to fix, resolve this from template
    docker-compose.env.j2:
        PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan,https://paperless.vpn.lan
        PAPERLESS_ALLOWED_HOSTS=paperless.lan,paperless.vpn.lan

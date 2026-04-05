# renaming:
    'kea' inventory role -> 'dhcp'
    'unbound' inventory rule -> 'dns-resolver'
    'configure_disks' role -> 'set_vm_disks'
    'configure-netcontroller' play -> 'set-dns'

# duplicate documentation 
- restic-retention-role.md
    -> focus on role function details
- use-restic-server.md / Server-side retention config
    -> focus on extending the config, like adding a new repo or changing retention

# restic server play
    - add extensive testing, including restic repository access / restore and backup
    - make sure to check if all existing repos on the host 
    have a matching add_restic_retention_repositories
    - make sure all add_restic_retention_repositories have a add_restic_retention_repository_passwords
    - log retention application

# adding restic client repo guide
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
    - a vm with a clone of this repo, and all vaults
    - able to connect to pxe, run playbooks.

```prompt
let's not overthink the autoinstall right now, keep it simple.
we've got dns resolvers now - we cloud just use autoinstall.lan and point that to whatever host ip we need with a dns update.
and for the server executable - the files srv/http_root is the important part. we could just point add {hostname}.ps1 to start the server.

i've reverted the autoinstall changes.
ansible1 was renamed admin1.
```

-> branch ansible-vm


# Lint
Running ansible-lint...
WARNING  Listing 3 violation(s) that are fatal
no-changed-when: Commands should not change things if nothing needs doing.
playbooks/roles/add_docker/tasks/main.yml:171 Task/Handler: Refresh host CA trust store

yaml[line-length]: Line too long (161 > 160 characters)
playbooks/roles/add_immich/defaults/main.yml:21

no-handler: Tasks that run when changed should likely be handlers.
playbooks/roles/set_vm_network/tasks/main.yml:42:13 Task/Handler: Flush netplan apply handler


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
        PAPERLESS_URL=https://paperless.lan
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
      have a matching local restic client repo for retention
    
# rclone sync
    - admin script should be interactive
    - show status, log path, timer interval, last run time and result,
    - option to actvivate / deactivate
    - option to run sync (up) / run sync (down)
    - option to adjust timer

## client 
    - update (ubuntu apt version 0.16.4 is < 2024!)
        - 0.17
            - skip-if-unchanged
            - reduces prune memory use
            - report snapshot size
        - 0.18 various fixes
    - use the official builds:
      https://github.com/restic/restic/releases/tag/v0.18.1
    - changes to the client, the admin scripts:
        - one script, repo details (path, repo, password, options, retention params) > config
            take a look at New-ResticSnapshot.json
            add retention params
            if a repo's path is empty, prevent snapshot / restore options
        - no parameters: interactive mode
            - show status, log path, configured repos, snapshot count and latest snapshot age. (timeout: 5s)
            - enable / disable options
            - run snapshot / restore / retention now options
            - interactive option
        - scheduler / service should just run `client.ps1 -RunSnapshot` 
        - `client.ps1 -RunRetention` should be available for retention service
        - Unify one Powershell restic-client.ps1 script to be used on windows and ubuntu servers. 
          make powershell a dependency on ubuntu servers / restic client play. 
        - client script should log backup and retention output.

# retention service     
    - refactor:
        - use restic client as a dependency, but disable timer / snapshot automation
        - instead, use timer / RunRetention automation
        - for add_restic_client_repositories, just use the local rest-server locations
        - leave path empty, so snapshot / restore won't work
        - admin script is just the restic client script


## add guide 'adding a client repo'
    - target-vm/host.yml/add_restic_client_repositories
    - target-vm/vault.yml/repository_password
    - restic-client update
    - repo init 
    - restic1/host.yml/add_restic_client_repositories
    - restic1/vault.yml/repository_password
    - restic1/vault.yml/add_restic_server_htpasswd_entries
    - restic-server update
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

# lint line endings
    - sometimes, dos2unix some file solves a problem.
    - build / lint should make sure to check for this

# Lint
Running ansible-lint...
WARNING  Listing 3 violation(s) that are fatal
no-changed-when: Commands should not change things if nothing needs doing.
playbooks/roles/add_docker/tasks/main.yml:171 Task/Handler: Refresh host CA trust store

yaml[line-length]: Line too long (161 > 160 characters)
playbooks/roles/add_immich/defaults/main.yml:21

no-handler: Tasks that run when changed should likely be handlers.
playbooks/roles/set_vm_network/tasks/main.yml:42:13 Task/Handler: Flush netplan apply handler


# depreaction warnings
TASK [record_deployment : Materialize immutable deployment history values] **********************************************************
[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.
[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.
Origin: /home/talos/homelab/playbooks/roles/record_deployment/tasks/main.yml:33:42

31           )
32       }}
33     record_deployment_entry_recorded_at: "{{ record_deployment_entry_recorded_at | default(ansible_date_time.iso86...
                                            ^ column 42

Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.



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


TASK [add_restic_retention : Validate restic retention inputs] **********************************************************************
[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.
Origin: /home/talos/homelab/playbooks/roles/add_restic_retention/tasks/main.yml:5:9

3   ansible.builtin.assert:
4     that:
5       - ansible_system == 'Linux'
          ^ column 9

Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.


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

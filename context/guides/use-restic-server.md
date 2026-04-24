# Use Restic Server

This guide covers how to connect a `restic` client to the homelab
`rest-server` deployment after `playbooks/add-rest-server.yml` has completed.

## Rest-Server Users

`rest-server` access users are managed through
`add_restic_server_htpasswd_entries`.

Add the template comment to the relevant host file, then place the real secrets
in that host's `vault.yml`.

For `restic1`, see the template comment at the bottom of
`inventory/host_vars/restic1/host.yml`.

After adding, removing, or changing users, rerun:

```powershell
./run.ps1 playbooks/add-rest-server.yml
```

That play updates the managed htpasswd file and restarts `rest-server` if
needed.

## Repository Names

This homelab `rest-server` runs with private repositories enabled.

That means the repository path must live under the authenticated username:

- good: `rest:http://restic1.lan:8000/restic-server-test/repo1`
- bad: `rest:http://restic1.lan:8000/repo1`

If the username is `restic-server-test`, use paths under
`/restic-server-test/...`.

### Reserved repository names

Do not use a repository path whose final segment is one of the internal REST
backend type names:

- `data`
- `keys`
- `locks`
- `snapshots`
- `index`
- `config`

For example, this bad repository path:
`rest:http://restic1.lan:8000/test-user/data`
collides with the REST backend's internal route structure and can produce
`405 Method Not Allowed` during `restic init`.

## Append-only mode

Append-only mode is enabled by default in this repo's `add_restic_server` role.

That means clients can create new backups and read existing data, but they
cannot delete or overwrite existing repository data through `rest-server`.

In practice:

- `restic backup` works
- `restic snapshots` works
- `restic restore` works
- `restic forget` and `restic prune` do not work through the append-only
  `rest-server` endpoint

This is intentional. It reduces the damage a compromised backup client can do.

### Retention in append-only mode

Retention still works, but not from the normal append-only backup client.
To actually remove old snapshots and reclaim space, `restic forget` and
`restic prune` need full read, write, and delete access to the repository.

Here, we use a separate maintenance service on the server.

For append-only repositories, upstream `restic` recommends using
`--keep-within` based retention rules when forgetting snapshots.

Why?

- calendar-style rules like `--keep-daily`, `--keep-weekly`, or `--keep-last`
  can be tricked by attacker-created snapshots with manipulated timestamps
- `--keep-within*` rules are safer for append-only workflows because they keep
  all snapshots within the time window instead of only the newest one in each
  bucket

### Server-side forget config

`restic1` now uses the same `add_restic_client` role as normal clients.
Server-side maintenance is modeled as local repositories with explicit
capabilities.

Example shape:

```yaml
add_restic_client_service_user: "archivar"
add_restic_client_retention_schedule_enabled: true
add_restic_client_repositories_template_file: "add_restic_client_repositories.json.j2"
```

```json
[
  {
    "name": "dockerhost2-paperless",
    "path": "",
    "resticRepository": "/media/backups/restic-data/dockerhost2/paperless",
    "repositoryPassword": "{{ add_restic_client_repository_secrets['dockerhost2-paperless'].repository_password }}",
    "snapshotAllowed": false,
    "restoreAllowed": false,
    "forgetAllowed": true,
    "resticBackupOptions": [],
    "forgetArgs": [
      "--keep-within",
      "7d",
      "--keep-weekly",
      "4",
      "--keep-monthly",
      "6",
      "--prune"
    ],
    "restUsername": "",
    "repositoryDisplay": "/media/backups/restic-data/dockerhost2/paperless"
  }
]
```

`add_restic_client_repositories` uses the same field names as the generated
runtime JSON, so the inventory is already the final repo-config shape. If you
prefer, keep passwords and REST credentials in vaulted helper vars such as
`add_restic_client_repository_secrets`.

The generated runtime operates against the local on-disk repository path, not
through the append-only HTTP endpoint.

The test play warns when:

- a VM-side repo has no matching server-side forget config
- an on-disk repo has no forget-managed config entry
- a configured access user has no client-side repos
- a client-side access user is missing from `add_restic_server_htpasswd_entries`

## Client-Side Environment Variables

You can either:

- put the `rest-server` username and password into `RESTIC_REST_USERNAME` and
  `RESTIC_REST_PASSWORD`
- or embed them in `RESTIC_REPOSITORY` like this:
  `RESTIC_REPOSITORY` = `'rest:http://$($username):$($password)@restic1.lan:8000/$($username)/repo1'`

### PowerShell

```powershell
$env:RESTIC_REST_USERNAME = 'restic-server-test'
$env:RESTIC_REST_PASSWORD = 'REST_SERVER_PASSWORD'
$env:RESTIC_REPOSITORY = "rest:http://restic1.lan:8000/$($env:RESTIC_REST_USERNAME)/repo1"
$env:RESTIC_PASSWORD = 'RESTIC_REPOSITORY_PASSWORD'
```
or
```powershell
$env:RESTIC_REPOSITORY = "rest:http://$($username):$($password)@restic1.lan:8000/$($username)/$($repository)"
$env:RESTIC_PASSWORD = 'RESTIC_REPOSITORY_PASSWORD'
```

There are two different passwords involved:

- `RESTIC_REST_PASSWORD` is the HTTP basic-auth password for `rest-server`
- `RESTIC_PASSWORD` is the repository encryption password used by `restic`

These are independent. A working server login does not replace the repository
password, and a valid repository password does not authenticate you to
`rest-server`.

## Troubleshooting

- `401 Unauthorized` usually means the `rest-server` username or password is
  wrong, or the repository path is outside the authenticated user's namespace
- `405 Method Not Allowed` during `restic init` can mean the repository path
  ended in a reserved name like `data`
- `404` on `HEAD .../config` is normal before `restic init`

## Sources

- restic preparing a new repository:
  https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- restic REST backend API:
  https://restic.readthedocs.io/en/latest/REST_backend.html
- rest-server upstream repository:
  https://github.com/restic/rest-server

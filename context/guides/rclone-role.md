# Rclone Role

The `add_rclone` role installs `rclone`, writes a reusable sync script, and
installs a systemd service plus timer for a generic `rclone` transfer job.
It also installs the vaulted `rclone.conf` content for the selected remote.

## Current assumptions

- the role runs on Linux `amd64`
- `rclone` is installed from the official upstream Linux binary archive
- the role is generic and does not assume any particular backup tool or remote
- the timer is intentionally left disabled and stopped after install

## Recovery-first workflow

The timer is installed only as prepared infrastructure.

Do not enable it during initial provisioning. First recover data from the
remote, verify the restored state, and only then enable the timer when the host
is ready to publish new syncs again.

## Remote config pattern

Keep the token-bearing `rclone.conf` content in the host-specific vault.

Example template for `inventory/host_vars/restic1/host.yml`:

```yaml
add_rclone_remote_path: "pCloud:restic1"

# vault.yml:
# add_rclone_remote_config_content: |
#   [pCloud]
#   type = pcloud
#   token = {"access_token":"...","token_type":"bearer","expiry":"0001-01-01T00:00:00Z"}
#   hostname = eapi.pcloud.com
```

# Automatic Updates

Use `playbooks/add-autoupdate.yml` to enable Ubuntu unattended security updates on hosts in the `ubuntu_auto_update` inventory group.

New VMs created through `playbooks/add-vm.yml` also receive this role by default during guest configuration.

Current behavior:

- installs `unattended-upgrades`
- enables `apt-daily.timer` and `apt-daily-upgrade.timer`
- configures automatic package list refreshes and unattended upgrades
- limits unattended upgrades to the Ubuntu security origin by default
- removes unused dependencies and old kernel packages
- does not automatically reboot after upgrades unless overridden

Role defaults live under `playbooks/roles/add_autoupdate/defaults/main.yml`.

Override the role variables if a host or group needs different origins, cleanup timing, or reboot behavior.

Set `enable_autoupdate: false` in a VM's host vars to skip automatic update configuration during `playbooks/add-vm.yml`.

Successful runs also append a deployment entry on the host in `/var/lib/homelab/deploy-history.yml`.

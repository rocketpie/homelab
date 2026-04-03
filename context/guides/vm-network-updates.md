# VM Network Updates

Use `playbooks/set-vm-network.yml` when a VM's static network settings need to be reapplied after changing the shared autoinstall network variables.

## When to use it

- `inventory/group_vars/all/autoinstall.yml` changed for:
  - `autoinstall_vm_ipv4_gateway`
  - `autoinstall_vm_ipv4_nameservers`
  - `autoinstall_vm_ipv4_prefix`
- existing VMs still have the old resolver or gateway in netplan
- a service fails because the guest still points at an outdated DNS server

Changing `autoinstall_*` values only affects future autoinstall renders by itself. Existing guests need `set-vm-network.yml` to rewrite their netplan file and run `netplan apply`.

## Targeting

- The playbook targets non-netcontroller VMs from the `vm` inventory group.
- Hosts in the `unbound` group are excluded, so `netcontroller1` and `netcontroller2` are not part of the default rollout.
- When prompted, enter a single VM name such as `dockerhost2` to update one host first, or press Enter to update all affected VMs.

## Recommended rollout

1. Run `run.ps1 set-vm-network.yml`
2. Enter `dockerhost2` first and confirm the host can resolve the expected names
3. Run the playbook again and press Enter to update the remaining affected VMs

## What it updates

- rewrites `/etc/netplan/50-cloud-init.yaml`
- keeps the host's static `ansible_host` address
- reapplies the shared gateway, prefix, and nameserver values from `inventory/group_vars/all/autoinstall.yml`
- validates with `netplan generate`
- applies with `netplan apply`

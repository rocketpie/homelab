# VM Network Updates

Use `playbooks/set-vm-network.yml` when a VM's static network settings need to
be reapplied after changing the shared autoinstall network variables or when a
VM's vaulted WireGuard client config needs to be refreshed in place.

## When to use it

- `inventory/group_vars/all/autoinstall.yml` changed for:
  - `autoinstall_vm_ipv4_gateway`
  - `autoinstall_vm_ipv4_nameservers`
  - `autoinstall_vm_ipv4_prefix`
- existing VMs still have the old resolver or gateway in netplan
- a service fails because the guest still points at an outdated DNS server

Changing `autoinstall_*` values only affects future autoinstall renders by itself. Existing guests need `set-vm-network.yml` to rewrite their netplan file and run `netplan apply`.

## Targeting

- The playbook targets hosts from the `vm` inventory group.
- When prompted, enter a single VM name such as `dockerhost2` to update one
  host first, or press Enter to update all affected VMs.

## Recommended rollout

1. Run `run.ps1 set-vm-network.yml`
2. Enter `dockerhost2` first and confirm the host can resolve the expected names
3. Update the remaining VMs one at a time if the change also touches the
   WireGuard client config or DNS-sensitive hosts such as the netcontrollers

## What it updates

- rewrites `/etc/netplan/50-cloud-init.yaml`
- keeps the host's static `ansible_host` address
- reapplies the shared gateway, prefix, and nameserver values from `inventory/group_vars/all/autoinstall.yml`
- reapplies the vaulted WireGuard client config when `add_vpn_client_config` is
  present for the host
- validates with `netplan generate`
- applies with `netplan apply`

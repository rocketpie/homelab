# Summary

## Environment
Homelab with two Proxmox hosts (inventory group proxmox: n2, n5).
ansible automation user setup: playbooks/add-proxmox-api-user-ansible.yml

Network bridge vmbr0.
Notes/docs in Obsidian + Git.

Automation goal: One tool only, Ansible for both:
* Provisioning via Proxmox API (no SSH to Proxmox nodes required)
* Guest configuration via SSH after install completes

OS target: Ubuntu Server 24.04 LTS.

Provisioning approach:
ISO-only unattended installs (no VM templates) using Ubuntu autoinstall (cloud-init NoCloud).

A remastered Ubuntu 24.04 live-server ISO boots with kernel params:
autoinstall ds=nocloud-net;s=http://<workstation-fqdn>:8080/ubuntu2404/ ---

Workstation runs a minimal Caddy HTTP server, serving:
/srv/http_root/ubuntu2404/user-data and /srv/http_root/ubuntu2404/meta-data

Autoinstall config installs/enables qemu-guest-agent + openssh-server, creates a shared ansible admin user with a locked password + key-only SSH + passwordless sudo, optionally creates host-specific users with their own SSH keys and vault-backed passwords, uses DHCP, shutdown: poweroff

## Ansible provisioning flow
* Create VM via Proxmox API: attach remastered ISO from storage local-pve-rpool-ISOs, create disk on chosen VM storage, NIC on vmbr0, boot from CD, enable QEMU agent.

* create VM via Proxmox API
* start VM
* when install finishes, VM powers off
* Ansible polls Proxmox until VM is stopped
* remove attached installer CD-ROM
* boot the VM
* remove any old SSH host key for that address with ssh-keygen -R
* adds VM to in-memory inventory with relaxed first-connect SSH options
* second play: wait for a SSH connection
* guest configuration then applies baseline roles such as disk setup (except no disks) and automatic Ubuntu security updates (except enable_autoupdate: false)
* successful guest configuration appends a deployment record to /var/lib/homelab/deploy-history.yml on the VM

## Day-2 VM updates
`playbooks/set-vm-hardware.yml` reuses the same Proxmox reconciliation logic for
existing VMs, so inventory remains the desired-state source for node placement,
replication targets, CPU, memory, and attached extra disks after initial
provisioning.

* reconcile the VM's desired day-2 Proxmox settings from inventory:
  `proxmox_node`, `proxmox_replica_nodes`, `cores`, `memory_mb`, and
  `extra_disks`
* if `proxmox_node` changed, the workflow prefers live migration with local
  disks for running VMs and uses offline migration for already-stopped VMs
* replication jobs are reconciled from `proxmox_replica_nodes`; removed jobs are
  deleted with `keep=1` so replicated target volumes are not removed implicitly
* missing `extra_disks` are attached to the existing VM without recreating it,
  then the guest-side disk workflow formats and mounts them by stable
  `disk_id`-derived `/dev/disk/by-id` paths

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
autoinstall ds=nocloud-net;s=http://<workstation>:8080/ubuntu2404/ ---

Workstation runs a minimal Caddy HTTP server, serving:
/srv/autoinstall/ubuntu2404/user-data and /srv/autoinstall/ubuntu2404/meta-data

Autoinstall config installs/enables qemu-guest-agent + openssh-server, creates a shared ansible admin user with a locked password + key-only SSH + passwordless sudo, optionally creates host-specific users with their own SSH keys and vault-backed passwords, uses DHCP, shutdown: poweroff

## Ansible provisioning flow
* Create VM via Proxmox API: attach remastered ISO from storage local-pve-rpool-ISOs, create disk on chosen VM storage, NIC on vmbr0, boot from CD, enable QEMU agent.

* create VM via Proxmox API
* start VM
* when install finishes, VM powers off
* Ansible polls Proxmox until VM is stopped
* remove attached installer CD-ROM
* boot the VM
* poll qemu-guest-agent via Proxmox API until it reports a non-loopback IPv4
* waits for SSH
* remove any old SSH host key for that IP with ssh-keygen -R
* adds VM to in-memory inventory with relaxed first-connect SSH options and the inventory-defined ansible_user
* second play: connect over SSH, run ping to confirm


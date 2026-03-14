# Summary

## Environment
Homelab with two Proxmox hosts (inventory group proxmox: n2, n5).
ansible automation user setup: playbooks/bootstrap-proxmox-ansible-user.yml

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

Autoinstall config installs/enables qemu-guest-agent + openssh-server, creates user (e.g. homelab), injects SSH key, uses DHCP.

## Ansible provisioning flow
* Create VM via Proxmox API: attach remastered ISO from storage local-pve-rpool-ISOs, create disk on chosen VM storage, NIC on vmbr0, boot from CD, enable QEMU agent.

Start VM → unattended install → reboot.

Discover DHCP IP (prefer qemu-guest-agent / DHCP reservation), wait for SSH, then run post-install roles/playbooks.


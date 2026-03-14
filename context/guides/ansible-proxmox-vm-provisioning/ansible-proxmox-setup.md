# Host Autoinstall config 

we'll go with ubuntu server 24.04 LTS,
with ISO-only unattended flow driven by ansible.
ISO Storage pool is 'local-pve-rpool-ISOs'
proxmox local network bridge is 'vmbr0'

1) A place to host per-VM autoinstall configs (HTTP)
    user-data (your autoinstall YAML)
    meta-data (can be minimal but must exist)

minimal caddy server on workstation, which should be network reachable from the new VM.
-> srv/Start-CaddyServer.ps1



# Remaster the Ubuntu 24.04 Server ISO (one-time)

```bash
sudo apt-get update
sudo apt-get install -y xorriso rsync
```

https://ubuntu.com/download/server
download original ISO somewhere, e.g. ~/iso/ubuntu-24.04.4-live-server-amd64.iso

Extract ISO:
``` bash
ORIG=/mnt/c/Users/lars/Downloads/ubuntu-24.04.4-live-server-amd64.iso
WORK=~/iso/work
OUT=~/iso/out/ubuntu-24.04.4-live-server-autoinstall.iso

mkdir -p ~/iso/work ~/iso/mnt ~/iso/out
sudo mount -o loop "$ORIG" ~/iso/mnt
rsync -aH --exclude=TRANS.TBL ~/iso/mnt/ ~/iso/work/
sudo umount ~/iso/mnt

sudo xorriso -indev "$ORIG" \
  -osirrox on \
  -extract_boot_images "$WORK/boot-images"
```

Edit GRUB config(s) to add autoinstall parameters
Edit BIOS GRUB:
    ~/iso/work/boot/grub/grub.cfg

Edit UEFI GRUB:
    ~/iso/work/boot/grub/loopback.cfg (sometimes used)
    and/or ~/iso/work/EFI/boot/grub.cfg (varies slightly by ISO)

Search for the menuentry that boots “Try or Install Ubuntu Server” and append to the linux line:

autoinstall ds=nocloud-net;s=http://{{caddy-hostname}}:8080/ubuntu2404/ ---

Example (illustrative):
linux  /casper/vmlinuz ... autoinstall ds=nocloud-net;s=http://{{caddy-hostname}}:8080/ubuntu2404/ ---

**Important:**
    The URL must end with a trailing slash.
    Keep the final --- (it separates kernel params cleanly).

Repack ISO:
``` bash

sudo cp -f "$WORK/boot-images/eltorito_img1_bios.img" "$WORK/boot/grub/i386-pc/eltorito.img"
sudo cp -f "$WORK/boot-images/eltorito_img2_uefi.img" "$WORK/boot/grub/efi.img"

xorriso -as mkisofs \
  -r -V "UBUNTU2404AUTO" \
  -o "$OUT" \
  -J -joliet-long -l \
  -isohybrid-gpt-basdat \
  \
  -eltorito-boot boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
    -no-emul-boot \
  "$WORK"
```

If your extracted tree doesn’t have isolinux/isohdpfx.bin or boot/grub/efi.img, the exact xorriso flags may need minor adjustment depending on the ISO build. If you hit that, tell me the file paths present under ~/iso/work/isolinux/ and ~/iso/work/boot/grub/ and I’ll give you the exact working command.


# Upload the remastered ISO to Proxmox ISO storage


# playbooks/provision.yml

* creates VM
* attaches ISO on ide2
* boots from CD
* waits for guest agent to report an IP
* adds that IP as a dynamic host and runs a simple “post” task

# Environment
Homelab with Proxmox hosts.
Goal: use Ansible for 
* VM provisioning via Proxmox API
* guest configuration via SSH after install
* OS target: Ubuntu Server 24.04 LTS
* Provisioning approach: ISO-only unattended installs, no templates
* Autoinstall is served over HTTP by Caddy
* Only one VM provision runs at a time

Current autoinstall design
* A remastered Ubuntu server ISO boots directly into autoinstall.
* The autoinstall seed is served from the workstation via http://lc3win:8080/ubuntu2404/
Inventory / vars model
VM selection
* The play prompts for vm_name
* vm_name must match an inventory hostname
* The play does:
    * assert vm_name in hostvars
    * set_fact: vm: "{{ hostvars[vm_name] }}"
VM host_vars shape
Example shape now in use:
* vmid: 22001
* proxmox_node: "n2"
* proxmox_ostype: "l26"
* proxmox_iso_filename: "ubuntu-24.04.4-live-server-amd64-autoinstall.iso"
* cores: 2
* memory_mb: 2048
* os_disk_gb: 20
* username: "archivar"
* password_hash: "..."
* ssh_public_keys:
  - "..."
* extra_disks:
  - disk_gb: 50
    pve_storage: "local-pve-rpool"
    mount_path: "/media/backups"

Notes:
* proxmox_iso_filename is intentionally a VM fact to document which ISO/template source created the VM.
* extra_disks is a list of VM-specific disks.
* mount_path is not used during VM creation yet; it is intended for later in-guest disk setup.

group_vars layout
group_vars/all/autoinstall.yml
Autoinstall-related global vars were moved to all, because the role runs on localhost and should not depend on a special inventory group.
Important vars include:
* autoinstall_export_directory: "{{ playbook_dir }}/../srv/autoinstall/ubuntu2404"
* autoinstall_base_url: "http://lc3win:8080/ubuntu2404"
* autoinstall_controller_probe_url: "http://127.0.0.1:8080/ubuntu2404"
roles/export_autoinstall_seed/defaults/main.yml

Proxmox vars
Cluster/global Proxmox vars include things like:
    proxmox_api_host
    proxmox_api_user
    proxmox_api_token_id
    proxmox_api_token_secret
    proxmox_api_verify_ssl
    proxmox_api_iso_storage
    proxmox_api_vm_storage
    proxmox_api_default_bridge
    proxmox_api_qemu_agent
Roles currently in use
export_autoinstall_seed
Purpose:
    render autoinstall seed files
    ensure Caddy is started if needed
Current behavior:
    validates required vars:
        vm_name
        vm.username
        vm.password_hash
        vm.ssh_public_keys
        autoinstall_export_directory
    ensures export dir exists
    renders:
        user-data
        meta-data
        vendor-data
    starts Caddy if controller-side probe says seed is not being served
Important nuance:
    WSL cannot reach the Windows-hosted service via lc3win, but can via 127.0.0.1
    so the role’s internal probe should use autoinstall_controller_probe_url
Caddy startup:
    calling the Windows exe from WSL works
    caddy start blocked
    command with async/poll: 0 was used to launch Caddy
    controller-side readiness should be checked against 127.0.0.1, not lc3win
Proxmox preflight role
proxmox_api_preflight
Purpose:
    verify Proxmox API access and required token permissions
Important implementation notes:
    query permissions with uri
    register full response as something like proxmox_api_permissions_response
    then materialize:
        proxmox_api_permissions: "{{ proxmox_api_permissions_response.json.data }}"
    the bug was that proxmox_api_permissions was referenced before being set
Permissions check:
    assert against explicit keys like:
        '/storage/' ~ proxmox_api_vm_storage
        '/storage/' ~ proxmox_api_iso_storage
        '/vms'
    use concatenation in assert expressions, not nested {{ }} inside string keys
Provision play flow
playbooks/provision-vm.yml
Current high-level flow:
    prompt for vm_name
    assert vm_name in hostvars
    vm: "{{ hostvars[vm_name] }}"
    debug selected VM
    include role export_autoinstall_seed
    include role proxmox_api_preflight
    include role proxmox_api_vm_create
    poll qemu guest agent for IP
    wait for SSH
    remove old host key
    add_host to in-memory group
    second play pings over SSH
Important note:
    ansible_user in add_host should come from vm.username, not be hardcoded
VM create role
roles/proxmox_api_vm_create/tasks/main.yml
Important final behavior:
    validates required vars
    checks VM does not already exist by vmid or name
    creates VM with:
        only OS disk initially on scsi0
        installer ISO on ide2
    starts VM
    waits until installer powers off
    removes ISO
    sets boot order to scsi0
    attaches extra disks after install
    starts VM again
Disk strategy
This was changed intentionally:
Initial create
Only attach:
    scsi0 = OS disk
    ide2 = install ISO
Do not attach extra_disks initially.
After autoinstall shutdown
    remove ide2
    attach extra_disks as scsi1, scsi2, ...
    boot from scsi0
This fixed confusion during install and made the VM boot correctly.
Correct boot order is:
    during install:
        boot: "order=ide2"
    after install:
        boot: "order=scsi0"

The next task is:
configure the extra disks inside the guest VM
Desired direction:
    detect the attached extra disks in the guest
    partition/format them if needed
    mount them at the configured extra_disks[].mount_path
    persist mounts, likely by UUID in /etc/fstab

let's detail this out, and draft it.





















Yes — I’d structure this as a dedicated **guest-side role** that runs only after the VM is reachable over SSH, and I’d make one upstream change first: give every extra disk a deterministic identity when you attach it in Proxmox. That avoids fragile “take the second unmounted disk” logic inside Ubuntu. For the guest work, the clean module set is `community.general.parted` for partitioning, `community.general.filesystem` for formatting, `ansible.posix.mount` for `/etc/fstab` + mounted state, and normal gathered facts / commands for discovery. The current Ansible docs also note recent templating changes in ansible-core 2.19 / Ansible 12, so keeping expressions simple and explicit is a good idea. ([Ansible Documentation][1])

## Recommended design

### 1) Extend `extra_disks` with a stable guest-visible identity

Your current shape is close, but for in-guest configuration I’d add one field that becomes the Proxmox disk serial. Something like:

```yaml
extra_disks:
  - disk_id: "backups"
    disk_gb: 50
    pve_storage: "local-pve-rpool"
    mount_path: "/media/backups"
    fs_type: "ext4"
    mount_options: "defaults,nofail"
```

Then, in the Proxmox create role, attach the disk with a serial derived from VM + disk ID, for example:

```yaml
serial=vm{{ vm.vmid }}-{{ item.disk_id }}
```

That gives you a stable path in the guest under `/dev/disk/by-id/`, which is much safer than relying on `sdb`, `sdc`, and so on.

I would also validate that:

* `disk_id` is unique within `vm.extra_disks`
* `mount_path` is unique within `vm.extra_disks`
* `fs_type` defaults to `ext4`
* `mount_options` defaults to `defaults,nofail`

### 2) Keep provisioning and guest config as separate phases

Your current flow already supports this nicely:

1. create VM
2. install Ubuntu
3. power off after install
4. remove ISO
5. attach extra disks
6. boot VM
7. wait for SSH
8. run guest configuration role

That is the right place to add a role like `guest_extra_disks`.

### 3) Make the guest role explicitly conservative

The role should:

* resolve each configured disk by serial / by-id path
* inspect current partition/filesystem state
* create a GPT label only if needed
* create exactly one partition if none exists
* create a filesystem only if none exists
* mount by UUID
* persist with `/etc/fstab`
* fail loudly if a disk already contains something unexpected

That last point matters. You do **not** want “idempotent” to quietly mean “reformat an existing disk”.

---

## Suggested inventory shape

I’d move toward this:

```yaml
vmid: 22001
proxmox_node: "n2"
proxmox_ostype: "l26"
proxmox_iso_filename: "ubuntu-24.04.4-live-server-amd64-autoinstall.iso"
cores: 2
memory_mb: 2048
os_disk_gb: 20

username: "archivar"
password_hash: "..."
ssh_public_keys:
  - "..."

extra_disks:
  - disk_id: "backups"
    disk_gb: 50
    pve_storage: "local-pve-rpool"
    mount_path: "/media/backups"
    fs_type: "ext4"
    mount_options: "defaults,nofail"

  - disk_id: "media"
    disk_gb: 200
    pve_storage: "local-pve-rpool"
    mount_path: "/srv/media"
    fs_type: "ext4"
    mount_options: "defaults,nofail"
```

---

## Suggested play flow change

After your second play can reach the guest, include the new role:

```yaml
- name: Configure new VM over SSH
  hosts: provisioned_vms
  become: true
  gather_facts: true

  roles:
    - role: guest_extra_disks
```

I would keep this separate from first-boot reachability tasks.

---

## Draft role contract

### `roles/guest_extra_disks/defaults/main.yml`

```yaml
guest_extra_disks: "{{ vm.extra_disks | default([]) }}"

guest_extra_disk_fs_type_default: "ext4"
guest_extra_disk_mount_options_default: "defaults,nofail"

# serial format used when attaching disks in Proxmox
guest_extra_disk_serial_prefix: "vm{{ vm.vmid }}-"

# whether a pre-existing filesystem is allowed
guest_extra_disks_allow_existing_filesystem: true

# whether to fail if filesystem exists but differs from desired fs_type
guest_extra_disks_fail_on_fs_type_mismatch: true
```

### `roles/guest_extra_disks/meta/main.yml`

```yaml
dependencies: []
galaxy_info:
  author: you
  description: Configure extra attached disks inside guest
  min_ansible_version: "2.16"
  platforms:
    - name: Ubuntu
      versions:
        - noble
```

### Collections needed

```yaml
collections:
  - community.general
  - ansible.posix
```

`community.general.parted`, `community.general.filesystem`, and `ansible.posix.mount` are documented in the current Ansible collection docs. ([Ansible Documentation][1])

---

## Draft task flow

### `roles/guest_extra_disks/tasks/main.yml`

```yaml
---
- name: Skip when no extra disks are defined
  ansible.builtin.meta: end_host
  when: guest_extra_disks | length == 0

- name: Validate extra disk definitions
  ansible.builtin.assert:
    that:
      - item.disk_id is defined
      - item.disk_id | length > 0
      - item.disk_gb is defined
      - item.disk_gb | int > 0
      - item.mount_path is defined
      - item.mount_path | length > 1
    fail_msg: "Invalid extra_disks entry: {{ item | to_nice_yaml }}"
  loop: "{{ guest_extra_disks }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Validate disk_id uniqueness
  ansible.builtin.assert:
    that:
      - (guest_extra_disks | map(attribute='disk_id') | list | unique | length)
        == (guest_extra_disks | length)
    fail_msg: "extra_disks[].disk_id values must be unique"

- name: Validate mount_path uniqueness
  ansible.builtin.assert:
    that:
      - (guest_extra_disks | map(attribute='mount_path') | list | unique | length)
        == (guest_extra_disks | length)
    fail_msg: "extra_disks[].mount_path values must be unique"

- name: Build normalized extra disk list
  ansible.builtin.set_fact:
    guest_extra_disks_normalized: >-
      {{
        guest_extra_disks_normalized | default([]) + [
          item | combine({
            'fs_type': item.fs_type | default(guest_extra_disk_fs_type_default),
            'mount_options': item.mount_options | default(guest_extra_disk_mount_options_default),
            'disk_serial': guest_extra_disk_serial_prefix ~ item.disk_id,
            'disk_by_id_path': '/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_' ~ (guest_extra_disk_serial_prefix ~ item.disk_id)
          })
        ]
      }}
  loop: "{{ guest_extra_disks }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Check disk by-id paths exist
  ansible.builtin.stat:
    path: "{{ item.disk_by_id_path }}"
  loop: "{{ guest_extra_disks_normalized }}"
  loop_control:
    label: "{{ item.disk_id }}"
  register: guest_extra_disk_path_stats

- name: Fail when expected extra disk is missing in guest
  ansible.builtin.assert:
    that:
      - item.stat.exists
    fail_msg: "Expected disk path not found in guest: {{ item.item.disk_by_id_path }}"
  loop: "{{ guest_extra_disk_path_stats.results }}"
  loop_control:
    label: "{{ item.item.disk_id }}"

- name: Resolve canonical disk device path
  ansible.builtin.command:
    cmd: "readlink -f {{ item.disk_by_id_path }}"
  loop: "{{ guest_extra_disks_normalized }}"
  loop_control:
    label: "{{ item.disk_id }}"
  register: guest_extra_disk_realpaths
  changed_when: false

- name: Build resolved disk map
  ansible.builtin.set_fact:
    guest_extra_disks_resolved: >-
      {{
        guest_extra_disks_resolved | default([]) + [
          item.item | combine({
            'disk_device': item.stdout
          })
        ]
      }}
  loop: "{{ guest_extra_disk_realpaths.results }}"
  loop_control:
    label: "{{ item.item.disk_id }}"

- name: Inspect block devices as JSON
  ansible.builtin.command:
    cmd: >
      lsblk --json --output
      NAME,KNAME,PATH,PKNAME,TYPE,FSTYPE,UUID,MOUNTPOINTS,PTTYPE {{ item.disk_device }}
  loop: "{{ guest_extra_disks_resolved }}"
  loop_control:
    label: "{{ item.disk_id }}"
  register: guest_extra_disk_lsblk
  changed_when: false

- name: Parse lsblk output into disk facts
  ansible.builtin.set_fact:
    guest_extra_disks_inspected: >-
      {{
        guest_extra_disks_inspected | default([]) + [
          item.item | combine({
            'lsblk': (item.stdout | from_json).blockdevices[0]
          })
        ]
      }}
  loop: "{{ guest_extra_disk_lsblk.results }}"
  loop_control:
    label: "{{ item.item.disk_id }}"

- name: Fail if whole disk already has mounted filesystem
  ansible.builtin.assert:
    that:
      - item.lsblk.mountpoints is not defined
        or (item.lsblk.mountpoints | reject('equalto', None) | list | length == 0)
    fail_msg: >-
      Disk {{ item.disk_device }} for {{ item.disk_id }} already appears mounted:
      {{ item.lsblk.mountpoints | default([]) }}
  loop: "{{ guest_extra_disks_inspected }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Create GPT label when missing
  community.general.parted:
    device: "{{ item.disk_device }}"
    label: gpt
    state: present
  when: item.lsblk.pttype | default('') == ''
  loop: "{{ guest_extra_disks_inspected }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Refresh kernel partition table view
  ansible.builtin.command:
    cmd: "udevadm settle"
  changed_when: false

- name: Create single primary partition when missing
  community.general.parted:
    device: "{{ item.disk_device }}"
    number: 1
    state: present
    part_start: "1MiB"
    part_end: "100%"
  when: (item.lsblk.children | default([]) | length) == 0
  loop: "{{ guest_extra_disks_inspected }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Refresh block device view after partitioning
  ansible.builtin.command:
    cmd: >
      lsblk --json --output
      NAME,KNAME,PATH,PKNAME,TYPE,FSTYPE,UUID,MOUNTPOINTS,PTTYPE {{ item.disk_device }}
  loop: "{{ guest_extra_disks_inspected }}"
  loop_control:
    label: "{{ item.disk_id }}"
  register: guest_extra_disk_postpart_lsblk
  changed_when: false

- name: Build final partition targets
  ansible.builtin.set_fact:
    guest_extra_disks_final: >-
      {{
        guest_extra_disks_final | default([]) + [
          item.item | combine({
            'partition': ((item.stdout | from_json).blockdevices[0].children[0].path),
            'partition_fstype': ((item.stdout | from_json).blockdevices[0].children[0].fstype | default('')),
            'partition_uuid': ((item.stdout | from_json).blockdevices[0].children[0].uuid | default(''))
          })
        ]
      }}
  loop: "{{ guest_extra_disk_postpart_lsblk.results }}"
  loop_control:
    label: "{{ item.item.disk_id }}"

- name: Fail on unexpected existing filesystem type
  ansible.builtin.assert:
    that:
      - not (
          guest_extra_disks_fail_on_fs_type_mismatch
          and item.partition_fstype | length > 0
          and item.partition_fstype != item.fs_type
        )
    fail_msg: >-
      Disk {{ item.disk_id }} already has filesystem {{ item.partition_fstype }},
      expected {{ item.fs_type }}.
  loop: "{{ guest_extra_disks_final }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Create filesystem when missing
  community.general.filesystem:
    dev: "{{ item.partition }}"
    fstype: "{{ item.fs_type }}"
  when: item.partition_fstype | length == 0
  loop: "{{ guest_extra_disks_final }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Read blkid UUID after filesystem creation
  ansible.builtin.command:
    cmd: "blkid -o export {{ item.partition }}"
  loop: "{{ guest_extra_disks_final }}"
  loop_control:
    label: "{{ item.disk_id }}"
  register: guest_extra_disk_blkid
  changed_when: false

- name: Build mount definitions
  ansible.builtin.set_fact:
    guest_extra_disk_mounts: >-
      {{
        guest_extra_disk_mounts | default([]) + [
          item.item | combine({
            'mount_uuid': (
              item.stdout_lines
              | select('match', '^UUID=')
              | first
              | regex_replace('^UUID=', '')
            )
          })
        ]
      }}
  loop: "{{ guest_extra_disk_blkid.results }}"
  loop_control:
    label: "{{ item.item.disk_id }}"

- name: Ensure mount directories exist
  ansible.builtin.file:
    path: "{{ item.mount_path }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop: "{{ guest_extra_disk_mounts }}"
  loop_control:
    label: "{{ item.disk_id }}"

- name: Mount and persist extra disks by UUID
  ansible.posix.mount:
    path: "{{ item.mount_path }}"
    src: "UUID={{ item.mount_uuid }}"
    fstype: "{{ item.fs_type }}"
    opts: "{{ item.mount_options }}"
    state: mounted
  loop: "{{ guest_extra_disk_mounts }}"
  loop_control:
    label: "{{ item.disk_id }}"
```

---

## One important upstream change in the Proxmox role

The draft above assumes your Proxmox role attaches each extra disk with a known serial. I’d change your “attach extra disks after install” task to include that.

Conceptually:

```yaml
- name: Attach extra disks after install
  ansible.builtin.uri:
    url: >-
      https://{{ proxmox_api_host }}:8006/api2/json/nodes/{{ vm.proxmox_node }}/qemu/{{ vm.vmid }}/config
    method: PUT
    headers:
      Authorization: "PVEAPIToken={{ proxmox_api_user }}!{{ proxmox_api_token_id }}={{ proxmox_api_token_secret }}"
    validate_certs: "{{ proxmox_api_verify_ssl }}"
    body_format: form-urlencoded
    body:
      "{{ 'scsi' ~ (loop_index + 1) }}": >-
        {{ item.pve_storage }}:{{ item.disk_gb }},
        serial=vm{{ vm.vmid }}-{{ item.disk_id }}
  loop: "{{ vm.extra_disks | default([]) }}"
  loop_control:
    index_var: loop_index
```

I would sanitize the exact formatting in your real task, but the key idea is the `serial=` parameter.

---

## Why I prefer serial-based detection over size-based detection

You *could* detect disks by matching `disk_gb` to `lsblk` size, but that gets messy fast:

* two disks may be the same size
* size reporting can differ slightly
* a rebuilt VM may reorder devices
* future changes to SCSI bus layout can break assumptions

A Proxmox-provided serial gives you a direct host-to-guest mapping, which is much easier to reason about operationally.

---

## Safety / idempotency rules I’d enforce

I’d bake these into the role:

1. **Never format a partition that already has a filesystem unless explicitly allowed.**
2. **Fail if the existing filesystem type differs from requested type.**
3. **Fail if mount path is already mounted from a different source.**
4. **Only manage one partition per extra disk.**
5. **Only manage disks declared in inventory.**

That makes reruns safe and makes operator mistakes obvious.

---

## Things I would not automate in v1

I would skip these initially:

* LVM
* multiple partitions per disk
* resize logic
* filesystem tuning
* ownership changes on mount points beyond root:root
* destructive “wipe and recreate” behavior

Those can come later once the basic path is stable.

---

## Small refinement to the role interface

I’d support this normalized schema:

```yaml
extra_disks:
  - disk_id: "backups"
    disk_gb: 50
    pve_storage: "local-pve-rpool"
    mount_path: "/media/backups"
    fs_type: "ext4"
    mount_options: "defaults,nofail"
    owner: "root"
    group: "root"
    mode: "0755"
```

Then the directory task can use `owner/group/mode` with defaults.

---

## One caveat to verify in your environment

The exact `/dev/disk/by-id/...` naming for QEMU/Proxmox SCSI disks can vary a bit depending on bus / model presentation. The role pattern above is correct in direction, but I would first boot one test VM, inspect `/dev/disk/by-id/`, and confirm the final by-id name generated from your chosen `serial=` value before hardcoding the string template. The general approach remains the same even if the precise prefix differs.

---

## Repo layout I’d use

```text
roles/
  guest_extra_disks/
    defaults/
      main.yml
    tasks/
      main.yml
    meta/
      main.yml
```

And in your VM provisioning flow:

```text
playbooks/provision-vm.yml
  play 1: localhost
    - export_autoinstall_seed
    - proxmox_api_preflight
    - proxmox_api_vm_create
    - wait/reachability/add_host

  play 2: provisioned_vms
    - guest_extra_disks
```

That keeps the boundary clean:

* localhost role = Proxmox lifecycle
* guest role = in-OS storage config

If you want, I can turn this into a tighter, repo-ready role with `defaults`, `asserts`, and the corresponding Proxmox attach task updated to set per-disk serials.

[1]: https://docs.ansible.com/projects/ansible/latest/collections/community/general/parted_module.html?utm_source=chatgpt.com "community.general.parted module - Ansible Documentation"


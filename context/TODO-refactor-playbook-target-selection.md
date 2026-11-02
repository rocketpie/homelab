# Refactor: Playbook Target Selection

Status: DRAFT
Scope: `run.ps1` target selection for playbooks that can target multiple hosts.

## Current behavior

```bash
pwsh run.ps1 <playbook> [-Limit <host>] [-Debug]
```

`-Limit` is passed straight through to `ansible-playbook --limit`. Without it,
Ansible targets every host matched by the playbook's `hosts:` pattern.

## Problem

Some playbooks intentionally target multiple hosts, for example
`add-public-gateway.yml` targets `vpn_gateway:website`. Running without a limit
can converge more hosts than intended.

The convention for playbooks that can target multiple hosts is to either ask
which host(s) to target, or use a declared default such as:

```yaml
# run-default-limit: gateway1
```

Single-VM playbooks already use a related pattern: they prompt for a VM and
fall back to `autoinstall_default_vm_name`.

## Proposed approach

Use `ansible-playbook --list-hosts` to discover targets without executing the
playbook. `run.ps1` already builds the real run arguments; add `--list-hosts`
and parse the result.

```bash
ansible-playbook -i inventory/hosts.yml playbooks/add-public-gateway.yml \
  --vault-password-file <active-vault> \
  --extra-vars '<active-env-json>' \
  --list-hosts
```

Example output:

```text
play #1 (vpn_gateway:website): Configure public gateway
  pattern: ['vpn_gateway:website']
  hosts (2):
    gateway1
    gateway2
```

Flow:

1. If `-Limit` was supplied, use it and skip the prompt.
2. Parse the `hosts (N):` block from `--list-hosts`.
3. If exactly one host is targeted, run normally.
4. If more than one host is targeted, prompt before running:

   ```text
   This playbook targets 2 hosts:
     [1] gateway1
     [2] gateway2

   Target host(s) [all]:
   ```

   Accept `a` or `all`, comma-separated names, or numbers.
   Blank is invalid input.
   Invalid input, invalid names or out-of-range numbers must re-prompt.
5. If zero hosts match, run normally and let Ansible report the empty target.

This respects inventory groups and patterns such as `vpn_gateway:website`.
VM playbooks that target `localhost` return one host and do not prompt.

## Open design points

- Default selection convention: use `# run-default-limit: gateway1` in the
  playbook header.
- `autoinstall_default_vm_name` is an actual Ansible variable used inside the
  VM playbooks. Reading it in `run.ps1` would make it a global default for every
  host-targeting playbook. Only use it as a fallback when the value matches one
  of the discovered hosts, if at all.
- Playbooks with multiple plays produce several host blocks. The investigation
  below recommends a sorted, de-duplicated union of all play hosts, because a
  single `--limit` applies to the whole run.
- Dynamic targets created with `add_host` are invisible to `--list-hosts`. The
  wrapper cannot protect `configure-netcontroller.yml` or `set-vm-network.yml`
  with discovery alone.
- `--list-hosts` still needs the active vault password to parse inventory that
  contains encrypted `vault.yml` files.
- Parsing `--list-hosts` output assumes a stable format across the Ansible
  versions used in the dev container. Verified with core 2.21.5 only.

## Investigation (2026-11-02)

Checked in the dev container with `ansible-playbook` core 2.21.5 against the
current inventory. All commands used the real run arguments from `run.ps1`.

### `--list-hosts` behavior

- Single play, multiple hosts (`add-public-gateway.yml`):
  `hosts (2):` followed by `gateway2` and `gateway1`.
- Multiple plays (`add-docker.yml`): one `play #N ...` block per play, each with
  its own `hosts (N):` block. The same host appears in all three blocks.
- `localhost` plays (`add-vm.yml`, `set-vm-network.yml`) list `localhost` and do
  not reach the later dynamic plays.
- Empty groups produce `hosts (0):` and exit 0 (`add-pwsh-ubuntu.yml` with the
  undefined `targets` group, `kea`, `provisioned_vms`).
- Host order is not the inventory order and is not stable enough for numeric
  selection. Sort and de-duplicate the union before displaying `[1]`, `[2]`.
- `--limit <unknown>` makes `--list-hosts` exit 1 with
  `Specified inventory, host pattern and/or --limit leaves us with no hosts to
  target.` Exit 1 must not be treated as "zero hosts" automatically.
- Ansible writes playbook deprecation warnings and unmatched-pattern warnings to
  stderr. Parse stdout only; do not merge stderr into the host list.
- `--list-hosts` needs the vault password for inventory that contains encrypted
  `vault.yml` files, but it does not connect to any host.

### Target matrix

| Playbook | Static hosts seen by `--list-hosts` | New behavior |
| --- | --- | --- |
| `add-public-gateway.yml` | `gateway1`, `gateway2` | Prompt |
| `add-vpn-client.yml` | 5 hosts in `vm` | Prompt unless a default is declared |
| `add-autoupdate.yml` | 5 hosts in `ubuntu_auto_update` | Prompt unless a default is declared |
| `add-proxmox-api-user-ansible.yml` | `n2`, `n5` | **Do not prompt**; the play is `run_once` |
| `add-docker.yml` | `dockerhost2` in 3 plays | No prompt today; union is 1 host |
| `add-ansible-execution.yml` | `admin1` | No prompt |
| `add-rest-server.yml` | `restic1` | No prompt |
| `add-restic-client.yml` | `dockerhost2` | No prompt |
| `test-restic-server.yml` | `restic1` | No prompt |
| `add-vm.yml` | `localhost` | No run.ps1 prompt; existing VM prompt inside the play |
| `remove-vm.yml` | `localhost` | No run.ps1 prompt; existing VM prompt inside the play |
| `set-vm-hardware.yml` | `localhost` | No run.ps1 prompt; existing VM prompt inside the play |
| `set-vm-network.yml` | `localhost` | No run.ps1 prompt; existing prompt inside the play |
| `configure-netcontroller.yml` | `localhost` only | No prompt; later plays use runtime `add_host` groups |
| `add-pwsh-ubuntu.yml` | none (`targets` is undefined) | No prompt; Ansible reports the empty target |

### Findings that change the design

- Multiple plays do not imply multiple targets. `add-docker.yml` has three plays
  but one host. Use the sorted union of all play host blocks, not per-play
  prompts: a single `--limit` applies to the whole run, so a per-play choice is
  not expressible through Ansible.
- Dynamic targets are invisible to `--list-hosts`.
  `configure-netcontroller.yml` builds `unbound_rollout_passive` and
  `unbound_rollout_active` with `add_host` in play #1, so `--list-hosts` warns
  about unmatched patterns and reports zero hosts for those plays. The wrapper
  must not claim those plays have no targets, and this refactor cannot protect
  them. `set-vm-network.yml` has the same shape.
- In-play VM prompts are a separate case. `add-vm.yml`, `remove-vm.yml`,
  `set-vm-hardware.yml`, and `set-vm-network.yml` prompt after `--list-hosts`
  has already seen only `localhost`. Blank is already meaningful there:
  `add-vm`/`remove-vm`/`set-vm-hardware` use it to accept
  `autoinstall_default_vm_name`, and `set-vm-network` uses it to mean all VMs.
  Do not globally reject blank in those prompts unless that UX is deliberately
  changed too.
- `run_once` plays should not prompt. `add-proxmox-api-user-ansible.yml` targets
  both Proxmox nodes but only the first one executes; asking the operator to
  choose would be misleading.
- The prompt needs a non-interactive path. On EOF or when stdin is not a TTY,
  fail with a message that names the playbook and tells the caller to use
  `-Limit all` (or an explicit host list). Silent fallback to all would recreate
  the current accidental-blast-radius problem.
- `-Limit` should still short-circuit discovery entirely. It is the explicit
  override and the safest path for scripts and runbooks.

### Runbook impact

| Runbook | Impact |
| --- | --- |
| `context/guides/public-gateway-setup.md` | Line 268 says "Omit `-Limit` to run every public host." Omission will now prompt. Change it to `-Limit all` for the all-hosts case and document the prompt. |
| `context/guides/vpn-client-role.md` | `pwsh run.ps1 add-vpn-client.yml` now prompts for one of 5 VMs. If the intent is still the whole `vm` group, use `-Limit all` or declare an all-hosts default. |
| `context/guides/vm-network-updates.md` | Says press Enter to update all affected VMs. That prompt lives in `set-vm-network.yml`, not `run.ps1`. If blank becomes invalid, both the play and this runbook must change to `all`/`a`. Otherwise document the intentional exception. |
| `context/guides/pwsh-ansible-workflow.md` | Must describe target discovery, the `all`/`a` selector, and the blank-is-invalid rule. |
| `README.md` and `run.ps1 -Help` | Usage text should mention the target prompt and `-Limit all` for non-interactive runs. |
| `context/guides/automatic-updates.md` | No command today, but a manual `add-autoupdate.yml` run now prompts for 5 hosts. Decide whether to declare an all-hosts default. |
| `context/guides/dns-records-guide.md`, `context/guides/network/design.md` | `configure-netcontroller.yml` stays non-interactive because its real targets are dynamic. Mention that `--list-hosts` cannot see them if the warning output becomes operator-facing. |
| `context/guides/docker-hosts.md`, `context/guides/use-restic-server.md` | Single-host targets today; no behavior change. `add-docker.yml` would start prompting if the `docker`, `paperless`, and `immich` groups ever diverge. |
| `context/llm/gateway1-public-publishing-rollout.md` | Uses `-Limit gateway1`, so it skips the prompt and is unaffected. |

### Suggested default convention

Use a playbook header comment as the opt-out, for example:

```yaml
# run-default-limit: all
```

Resolution order:

1. `-Limit` supplied by the caller.
2. `# run-default-limit:` from the playbook header.
3. Exactly one discovered host: run without prompting.
4. More than one discovered host: prompt, with no blank default.
5. Zero discovered hosts: run normally and let Ansible report the result.

Recommended headers: `all` for `add-autoupdate.yml`, `add-vpn-client.yml`, and
`add-proxmox-api-user-ansible.yml`. Leave `add-public-gateway.yml` without a
header so it prompts. Keep `set-vm-network.yml` on its existing in-play prompt
until that prompt is aligned separately.

## First step

Investigate required changes before implementing:

- [x] Confirm `ansible-playbook --list-hosts` output format in the dev container
      for single-play, multi-play, `localhost`, and empty-target playbooks.
- [x] Identify which playbooks should prompt and which should keep converging
      all matched hosts by default.
- [ ] Decide the exact default convention (`# run-default-limit:` vs an
      inventory variable).
- [ ] Define how the prompt handles multiple plays and invalid input.
- [ ] Align the `set-vm-network.yml` in-play prompt and its runbook with the
      blank-is-invalid rule, or record it as an intentional exception.
- [ ] Add a PowerShell test with mocked `ansible-playbook --list-hosts` output,
      including stderr warnings, exit 1, duplicate hosts, and invalid prompt
      input.
- [ ] Update `context/guides/pwsh-ansible-workflow.md` and the affected runbooks
      with the final behavior.

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

   Accept `all`, blank for all, names, comma-separated names, or numbers.
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
- Playbooks with multiple plays may produce several host blocks. Decide whether
  the prompt is a union of all play hosts or per play.
- `--list-hosts` still needs the active vault password to parse inventory that
  contains encrypted `vault.yml` files.
- Parsing `--list-hosts` output assumes a stable format across the Ansible
  versions used in the dev container.

## First step

Investigate required changes before implementing:

- [ ] Confirm `ansible-playbook --list-hosts` output format in the dev container
      for single-play, multi-play, `localhost`, and empty-target playbooks.
- [ ] Identify which playbooks should prompt and which should keep converging
      all matched hosts by default.
- [ ] Decide the exact default convention (`# run-default-limit:` vs an
      inventory variable).
- [ ] Define how the prompt handles multiple plays and invalid input.
- [ ] Add a PowerShell test with mocked `ansible-playbook --list-hosts` output.
- [ ] Update `context/guides/pwsh-ansible-workflow.md` with the final behavior.

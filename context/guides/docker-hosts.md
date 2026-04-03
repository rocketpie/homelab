# Docker Hosts

This guide covers the base Docker host workflow from `playbooks/add-docker.yml`
and the `add_docker` role.

It is intentionally generic.

A Docker host may run Paperless, or it may run completely different container
stacks. Host-level Docker and reverse proxy behavior belongs here.

## Scope

The Docker host base currently manages:

- Docker Engine
- Docker CLI and Compose plugin
- optional host-local HAProxy reverse proxy
- internal TLS termination for the reverse proxy
- Docker host admin scripts

Application-specific stacks such as Paperless belong in their own guides and
roles.

## Host Variables

Base Docker hosts currently use:

- `add_docker_users`
- `dns_aliases`
- `add_docker_reverse_proxy_bindings`

`add_docker_users` controls which existing host users should be added to the
`docker` group.

`dns_aliases` controls hostnames that should resolve to the host IP even when
they are not reverse-proxied by Docker host HAProxy.

`add_docker_reverse_proxy_bindings` controls which hostnames should be routed
by HAProxy to a published host port. These hostnames are also exported into the
DNS workflow automatically, so they do not need to be duplicated in
`dns_aliases`.

When reverse proxy bindings exist, the role expects:

- `context/homelab-ca/ca.crt`
- `context/homelab-ca/client/<inventory_hostname>.crt`
- `context/homelab-ca/client/<inventory_hostname>.key`

## Reverse Proxy Bindings

Example:

```yaml
add_docker_reverse_proxy_bindings:
  - port: 8000
    hostnames:
      - "paperless.lan"
      - "paperless.vpn"
  - port: 8080
    hostnames:
      - "whoami.lan"
```

Rules:

- `port` is the host port published by the container stack
- `hostnames` is the list of names that should route to that backend
- `backend_host` is optional and defaults to `127.0.0.1`
- each binding hostname is also added to host-level DNS automatically
- use `dns_aliases` separately only for names that should resolve to the host
  without a reverse proxy binding

The current HAProxy setup:

- redirects HTTP on port `80` to HTTPS
- serves HTTPS on port `443`
- terminates TLS with the host certificate from `context/homelab-ca/client/`

## Service Management

When reverse proxy bindings exist, `add_docker` also manages `haproxy` on the
Docker host.

The admin scripts exposed through `add_admin_scripts` cover:

- Docker service control
- reverse proxy service control
- host status

## Example: dockerhost2

`dockerhost2` currently uses:

```yaml
add_docker_users:
  - "captain"

add_docker_reverse_proxy_bindings:
  - port: 8000
    hostnames:
      - "paperless.lan"
      - "paperless.vpn"
```

That means:

- `paperless.lan` resolves to the host IP through the DNS workflow
- `paperless.vpn` resolves to the host IP through the DNS workflow
- HAProxy redirects HTTP on port `80` to HTTPS
- HAProxy serves HTTPS on port `443` with `context/homelab-ca/client/dockerhost2.crt`
- requests for both names are forwarded to `127.0.0.1:8000`

## Operational Notes

- generate the CA and host certificate before rerunning `run.ps1 add-docker.yml`
- The backend service must still publish a host port that HAProxy can reach
- changing Docker host bindings requires rerunning `run.ps1 add-docker.yml`
- changing hostnames that feed DNS, including reverse proxy bindings, also
  requires rerunning `run.ps1 configure-netcontroller.yml`

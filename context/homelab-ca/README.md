# Homelab CA

This directory stores the local certificate-authority workflow for internal
services.

## Files

- `ca.crt`
  the tracked CA certificate that clients can trust
- `ca.key`
  the CA private key
- `client/<name>.crt`
  a tracked server certificate for one host
- `client/<name>.key`
  the matching private key for that server certificate

The CA private key must be protected with a passphrase.

The server private keys under `client/` are intentionally not passphrase
protected because services such as HAProxy need to start unattended.

`.gitignore` excludes the private keys and helper files so the certificate
workflow can live here without committing the secret material.

## Commands

Create or refresh the CA:

```powershell
pwsh context/homelab-ca/new-ca.ps1
```

Create a host certificate with SANs:

```powershell
pwsh context/homelab-ca/new-client-certificate.ps1 -Name dockerhost2 -DnsName paperless.lan,paperless.vpn
```

For Docker hosts, the default HAProxy certificate lookup is:

- `context/homelab-ca/client/<inventory_hostname>.crt`
- `context/homelab-ca/client/<inventory_hostname>.key`

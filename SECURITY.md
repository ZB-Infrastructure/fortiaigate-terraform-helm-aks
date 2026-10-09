# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report security issues directly to Fortinet PSIRT:

- Web: <https://www.fortiguard.com/psirt>
- Email: <psirt@fortinet.com>

Include:

- The affected file(s) and Terraform version
- A description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- Your suggested remediation, if any

## Scope

This policy covers the Terraform infrastructure and local Helm changes in this repository, including Azure RBAC, AKS API access, Application Gateway exposure, storage access, TLS, and deployment secret handling. Report upstream provider/chart vulnerabilities to their maintainers; report FortiAIGate container vulnerabilities through Fortinet support or PSIRT.

## Production hardening

The defaults support evaluation. Before production deployment, review:

- AKS API access and authentication. This stack currently uses AKS client certificates and does not expose API CIDR restrictions, private-cluster settings, or Entra ID integration as deployment inputs. Private application ingress does not make the AKS API private.
- Application Gateway exposure. Choose `internal` before deployment, review subnet/NSG routing, and verify backend trust using [the gateway guide](docs/application-gateway-dns-tls.md).
- Certificates. Web TLS supports generated material, supplied PEM, or cert-manager. Internal services always use a generated deployment CA and a separate leaf. Protect private keys in state and qualify internal renewal and rollout. See [supplied TLS](docs/tls-supplied.md) and [Let's Encrypt](docs/tls-letsencrypt.md).
- Azure Files network access and shared-key authentication, dedicated Azure Disk database storage, encryption controls, and backup/restore. Storage account destruction deletes shared data even with a retained PV.
- Azure role assignments for the deployment principal, AKS identities, AGIC, ACR, storage, and cert-manager. Scope access to the required resources and review grants outside the deployment resource group.
- Application Secrets and Terraform state. Preserve PostgreSQL/Redis credentials, CSRF, and the master encryption key against retained data. Keep state, backups, keys, licenses, and local tfvars out of version control.

See [operations](docs/operations.md), [testing](docs/testing.md), and [the roadmap](ROADMAP.md) for qualification and remaining gaps.

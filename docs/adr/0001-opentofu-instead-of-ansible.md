# ADR 0001: OpenTofu instead of Ansible

Status: accepted, 2026-11-19. Replaces the Ansible layout in `docs/plan-host.md`.

## Context

- `docs/plan-host.md` planned Ansible roles and Quadlets.
- Florian does not want Ansible. The repo should be infrastructure as code with one tool.
- More than one server must be possible.
- sothyr-pages now runs as compose stacks (`compose.platform.yml`, `compose.site.yml`) with register jobs.
  Its own install guide uses podman-compose.
- The VM is small (CPX21 class). Every extra service costs memory.

## Decision

1. **OpenTofu** for everything. Terraform syntax, plus state encryption, which Terraform lacks.
2. **cloud-init** bootstraps a VM once. It never runs again. Later changes would otherwise recreate the server.
3. **host-runtime module** for all later changes. It renders one idempotent bash bundle, copies it over SSH
   and runs it. The bundle runs only when its hash changes (`terraform_data` with `triggers_replace`).
4. **Compose stacks under systemd** instead of Quadlets. sothyr-pages stays the single source of its services.
   One unit template `hhc-stack@.service` runs any compose project.
5. **HAProxy in TCP mode** as entry point, PROXY protocol v2 to one Caddy per host. TLS stays in Caddy.
   HAProxy limits connections per client address. It costs a few MB of memory.
6. **The sothyr platform Caddy is the edge Caddy** on sothyr hosts. Other apps add snippets to its sites folder.
   No second Caddy, no router per club.
7. **SSH only with certificates** of a user CA. Host keys are made by OpenTofu and pinned. No trust on first use.
8. **Secrets** live in the encrypted state (generated passwords) and in a git ignored `secrets.auto.tfvars`.

## Consequences

- One command (`tofu apply`) for servers, DNS, users and apps.
- No drift detection on the server beyond the hash: a manual change on the server stays until the next change of the bundle.
  Rule: never edit managed files on the server.
- A changed stack is recreated (`--force-recreate`). Short downtime of that stack on config changes.
- Provisioners need SSH from the machine that runs OpenTofu. CI needs port 22 or a self-hosted runner.
- podman-compose details (container names, `!override`) are part of the contract. Check them on upgrades.

## Rejected

- **Ansible**: not wanted.
- **Quadlets per service**: duplicates the compose files of sothyr-pages and drifts from them.
- **NixOS**: too steep for one developer, and Rocky Linux 10 is set.
- **Caddy alone without HAProxy**: chosen first for memory reasons, replaced by Florian's choice of HAProxy as entry point.
- **Watchtower**: archived. Image updates run as a systemd timer per stack with `auto_update`.

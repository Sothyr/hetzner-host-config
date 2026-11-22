# hetzner-host-config

Servers in the Hetzner Cloud as code. OpenTofu only, no Ansible.

- Creates VMs, primary IPs, firewall, reverse DNS and DNS zones.
- Bootstraps each VM once with cloud-init (Rocky Linux 10, Podman, HAProxy, SSH certificates).
- Keeps each VM in the declared state over SSH: login users, compose stacks, HAProxy, edge routes, backups.
- Runs sothyr-pages (platform plus clubs) and any other compose app behind one HAProxy and one Caddy per host.
- Several hosts: every stack, app and user names its host.

Decision and reasons: [docs/adr/0001-opentofu-instead-of-ansible.md](docs/adr/0001-opentofu-instead-of-ansible.md).

## Traffic path

```
Internet
  -> Hetzner firewall (22, 80, 443, app ports)
  -> HAProxy on the host, TCP mode, limits per client address
  -> PROXY protocol v2 -> edge Caddy on 127.0.0.1:8080 / 8443 (TLS, certificates)
       sothyr host: the Caddy of the sothyr platform
       other host:  a small Caddy of this repo (modules/edge-caddy)
  -> containers on the network sothyr-shared (or edge)
```

## Layout

```
modules/
  hcloud-host/     VM, IPs, firewall, rDNS, pinned host key, cloud-init bootstrap
  host-runtime/    everything after the bootstrap, applied over SSH, idempotent
  dns-zone/        Hetzner DNS zone and records, or a list for external DNS
  sothyr-platform/ preset: compose.platform.yml of sothyr-pages as one stack
  sothyr-site/     preset: one club (compose.site.yml plus register jobs)
  edge-caddy/      preset: standalone Caddy for hosts without sothyr
  keycloak-realm/  realm, roles, OIDC clients for apps that are not clubs
stacks/
  platform/        root: hosts, sothyr, apps, users, DNS
  identity/        root: Keycloak realms of other apps
scripts/           SSH CA and certificate signing
ci/                GitHub workflow, move to .github/workflows/
```

## Requirements

- OpenTofu 1.10 or newer. State encryption needs OpenTofu, not Terraform.
- A Hetzner Cloud API token (read and write).
- An S3 bucket for the state, e.g. Hetzner Object Storage.
- OpenSSH (`ssh-keygen`). On Windows it ships with the system.

## First run

1. Create the SSH user CA. Keep the private key offline or in your password manager.
   ```
   .\scripts\ssh-sign.ps1 -InitCa
   ```
2. Sign the key OpenTofu uses. The principal must match `ssh.admin_principals`.
   ```
   .\scripts\ssh-sign.ps1 -Key $HOME\.ssh\hhc_deploy -Identity tofu -Principals hhc-deploy -Validity +8h
   ```
3. Settings:
   ```
   cd stacks\platform
   copy backend.hcl.example backend.hcl
   copy terraform.tfvars.example terraform.tfvars
   copy secrets.auto.tfvars.example secrets.auto.tfvars
   ```
   Fill in all three. `backend.hcl` and `secrets.auto.tfvars` are ignored by git.
4. Environment:
   ```
   $env:TF_VAR_hcloud_token = "..."
   $env:TF_VAR_state_passphrase = "..."   # at least 16 characters, keep it in your password manager
   $env:AWS_ACCESS_KEY_ID = "..."         # S3 key of the state bucket
   $env:AWS_SECRET_ACCESS_KEY = "..."
   ```
5. Lock file for Windows and Linux (CI), then plan and apply:
   ```
   tofu init -backend-config=backend.hcl
   tofu providers lock -platform=windows_amd64 -platform=linux_amd64
   tofu plan -out tfplan
   tofu apply tfplan
   ```
   The first apply waits for cloud-init, starts the stacks, then HAProxy. Expect 10 to 20 minutes.
6. Pinned host keys for your own SSH client:
   ```
   tofu output -raw known_hosts >> $HOME\.ssh\known_hosts
   ```
7. Name servers: `tofu output nameservers`. Set them at the registrar (Checkdomain) for zones in mode `hetzner`.
   Records of zones in mode `external`: `tofu output dns_records_external`.

## Daily work

| Task | Change |
|---|---|
| New club | entry in `sothyr.<host>.sites`, then apply |
| New domain for an app | entry in `apps.<name>.routes`, then apply |
| New app | entry in `apps`, compose file inline or from git |
| New login user | entry in `users`, then sign a certificate with their principal |
| Remove a user | delete the entry. The account is locked, the home folder stays |
| Second server | entry in `hosts`, point stacks to it |
| Update sothyr-pages | change `sothyr.<host>.git.ref`, apply |
| Bigger VM | change `server_type`, apply (the VM restarts) |

Login for people:
```
.\scripts\ssh-sign.ps1 -Key $HOME\.ssh\id_ed25519 -Identity florian -Principals florian -Validity +12h
ssh florian@<ip>
```
The host accepts only certificates of the CA. No keys, no passwords, no root.
A CA rotation is a second key in `ssh.user_ca_public_keys`, an apply, then removal of the old key.

## Stacks

A stack is one compose project on a host. host-runtime writes it to `/srv/stacks/<name>/` and runs it as
`hhc-stack@<name>.service`:

- `systemctl start` runs `podman-compose up -d`. It pulls missing images only.
- A config change runs `systemctl reload`: pull, build if set, run jobs, recreate.
- `systemctl stop` runs `down`. Volumes stay.
- A stack removed from the config is stopped. Its folder moves to `/srv/stacks/.removed/`. Volumes stay.
- `auto_update = true`: a nightly timer pulls new images and recreates only on a change.
- `after`: other stacks that must run first (systemd `Requires` and `After`).
- `jobs`: one-shot services of another compose project before the start. The sothyr register jobs use this.
- `post_checkout`: idempotent bash in the git checkout, for small patches.

Env values are written as `KEY='value'`. Single quotes and line breaks are rejected.

## sothyr-pages

The presets follow `tools/stack.py` of sothyr-pages (commit `5bcd453`, 2026-11-19):

- Platform: `compose.platform.yml` with `platform.env` values. `SITE_SLUG` empty, like `rebuild.py --platform`.
- Club: first the register jobs `site-db`, `site-register`, `umami-init` and, with tickets, `pretix-init`
  in the platform project with the platform values. Then `compose.site.yml` with the club values only. No platform secret reaches a club.
- HAProxy mode without changes in sothyr-pages:
  `hhc.override.yml` moves the Caddy ports to `127.0.0.1` (`ports: !override`, podman-compose 1.2 or newer).
  `post_checkout` adds the `proxy_protocol` listener wrapper to `platform/Caddyfile`, in the platform checkout and in each club checkout,
  because the register job loads that file into Caddy.
  Once sothyr-pages has this switch itself, drop the patch.
- When sothyr-pages changes `PLATFORM_SECRETS`, `PLATFORM_OWNED` or `REGISTER_JOBS`, update both presets.

After the first start, by hand:

- pretix creates `admin@localhost` with password `admin`. Change it at once on `https://<tickets host>/control/`.
- Umami starts with `admin` / `umami`. Change it, then put the new one in `secrets.umami_admin`.
- Keycloak admin: `tofu output -json keycloak`.

## Other apps

Example in `terraform.tfvars.example` (TeamSpeak, registry). Rules:

- Join the external network `sothyr-shared` on a sothyr host, `edge` on other hosts.
- Publish no ports for web apps. Add a route instead. The upstream is `<container name or alias>:<port>`.
- Ports for non HTTP protocols go to `ports`, e.g. `"9987/udp"`. Both firewalls are opened.
- Set `mem_limit` in the compose file. The VM is small.

## Keycloak realms of apps

Club realms belong to the register job of sothyr-pages. Realms of other apps:
```
cd stacks\identity
copy backend.hcl.example backend.hcl
copy terraform.tfvars.example terraform.tfvars
$env:TF_VAR_keycloak = (tofu -chdir=..\platform output -json keycloak | ConvertFrom-Json).'sothyr-1' | ConvertTo-Json -Compress
tofu init -backend-config=backend.hcl
tofu apply
```

## Backups

- Hetzner daily backups of the whole VM (`hosts.<name>.backups`, default on).
- Nightly dumps of the shared Postgres and MariaDB to `/srv/backup/`, before the backup window.
  Set `hosts.<name>.backup.on_calendar` to a time before the window shown in the Hetzner console.
- Off-site copy (off by default): restic to Hetzner Object Storage (S3), nightly after the dumps.
  - Steps: create a bucket and an S3 key in the Hetzner Console, set `hosts.<name>.backup.offsite` (see `terraform.tfvars.example`),
    put the keys and a restic password in `secrets.offsite.<host>`, apply. The first run creates the repository.
  - restic runs in a container (`backup.offsite.image`, pin a version). The host needs no restic package.
  - Keeps 7 daily, 4 weekly and 6 monthly snapshots. A weekly `restic check` runs on Sundays.
  - The restic password is not recoverable. Keep it in your password manager.
  - The dumps in `/srv/backup` are the default path. Uploads (WordPress media, pretix files) are in volumes, not in the dumps:
    add their paths to `backup.offsite.paths` once the volume names are known on the real host.
    Do not add the database volumes, they are not consistent while running.
  - Check on the server: `systemctl list-timers hhc-offsite.timer`, `journalctl -u hhc-offsite -e`.
  - Restore: `restic restore latest --target <dir>` with the same environment as in `/etc/hhc/offsite.env` (as root).
  - Switching it off (`enabled = false`) removes the timer and the keys from the host. The bucket stays.

## On the server

```
systemctl list-units 'hhc-*'
journalctl -u hhc-stack@sothyr-platform -e
/usr/local/libexec/hhc/stack apply <stack>
haproxy -c -f /etc/haproxy/haproxy.cfg
echo "show table limits" | socat stdio /run/haproxy/admin.sock
```

Do not edit managed files on the server. The next apply overwrites them.

## Not verified on a real host yet

Checked offline: `tofu validate`, plans with one and two hosts, shellcheck of the generated bundle, `haproxy -c`, `caddy validate` (2.11.9)
of the patched platform Caddyfile with a route, a dry run of the stack runner. To check on the first real host:

- `dnf-automatic` on EL10 (package and `/etc/dnf/automatic.conf`).
- pip install of podman-compose 1.6 on Rocky 10 (`--break-system-packages` fallback is in place).
- Source address of HAProxy connections inside the Caddy container (must be in `proxy_sources`).
- Container names `<project>_<service>_1` of podman-compose 1.6 (edge reload and dumps use them).
- Keycloak realm attribute `frontendUrl` in `modules/keycloak-realm`.

## Open points

- WireGuard for admin interfaces (plan-host.md) is not built yet.
- Off-site copy is built but not run on a real host. Not verified: the image entrypoint (`--entrypoint restic`), volume paths of uploads.
- Mail DNS (SPF, DKIM, DMARC) is a plain record list in `dns_zones` for now.

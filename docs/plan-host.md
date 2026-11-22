# Plan: Hetzner host bootstrap and networking

> **Superseded in parts (2026-11-19).** The tool is OpenTofu, not Ansible: see `docs/adr/0001-opentofu-instead-of-ansible.md` and `README.md`.
> Services run as compose stacks under systemd, not as Quadlets. Goals, traffic path, TLS at Caddy, HAProxy and the open topics below still apply.

Status: plan, not started. Written for the next implementer.
Owner of decisions: Florian. Open points are at the end.
Related: `C:\develop\sothyr-pages\docs\plan-ticketing.md` (sites and the shared pretix).

## Goal

One Hetzner VM hosts many club sites built from the sothyr-pages template.
Shared services run once per VM to save resources.
Ansible sets up the VM from scratch and adds a new club site from a few variables.

## Host platform (decided)

Rocky Linux 10 (kernel 6.12, el10). Consequences:

- Container runtime: Podman, rootful. It is the native runtime on EL10 and the same as Florian's local setup.
  Rootful because sites and shared services must share the networks `edge` and `sothyr-shared`.
  Rootless per site would isolate better but cannot share networks across users.
- Services run as Quadlet units (systemd), see "Automatic image updates". No podman-compose on the server.
- Firewall: firewalld, not nftables by hand and not ufw. Public zone allows only ssh, http, https.
  Podman (netavark) writes its own nftables rules for published ports, around firewalld zones. So the rule stays: never publish on `0.0.0.0`.
- SELinux stays enforcing. Volumes need `:Z` or `:z` labels. HAProxy needs the right SELinux port types or the boolean
  `haproxy_connect_any` to reach `127.0.0.1:8080` and `8443`. Check with `semanage port -l` and `getsebool`, do not turn SELinux off.
- Packages with dnf. HAProxy from AppStream (check the version it ships). EPEL for extras.
- Ansible collections: `ansible.posix` (firewalld, selinux, sysctl), `community.general` (dnf helpers), `containers.podman`
  (networks, containers, maybe quadlets). Verify module names against the installed collection versions.
- Automatic security updates with `dnf-automatic`.

## Two deployment modes (decision)

| Mode | Who hosts | Keycloak | pretix | Umami | Databases | Rest of the site |
|---|---|---|---|---|---|---|
| `hosted` | Florian, on this VM, many clubs | one shared Keycloak, one realm per club | one shared pretix, one organizer per club | one shared Umami, one website per club | one shared Postgres and one shared MariaDB, one database and user per club or service | per club: frontend, api, wordpress, site router |
| `bundled` | the club itself | in the club's stack | in the club's stack | in the club's stack | in the club's stack | everything in one compose stack, as today |

The same sothyr-pages release must run in both modes. Only `.env` and one extra compose file differ.
This repo (Ansible) only builds `hosted`. `bundled` stays the documented path in the sothyr-pages README.

## Traffic path

```
Internet
  -> Hetzner Cloud Firewall (80, 443 open; 22 only from admin IPs)
  -> HAProxy on the host (systemd, ports 80 and 443, IPv4 and IPv6)
  -> edge router container (Caddy, shared, bound to 127.0.0.1 only)
  -> per site: site router (the site's own Caddy, plain HTTP, no ports)
       -> frontend, api, wordpress, keycloak, umami
  -> shared: pretix (tickets.<club domain>)
  -> shared: Keycloak (auth.<club domain> or one login host, see below)
  -> shared: Umami (stats.<club domain> or one stats host, see below)
```

Florian's stages:

- V1: HAProxy -> nginx or Caddy -> container networks in Podman. This plan uses Caddy as that middle router.
- V2: HAProxy -> application networks directly. Only if the middle router turns out to be useless.

## Where TLS ends (decided: option A)

| Option | How | Plus | Minus |
|---|---|---|---|
| A (recommended) | HAProxy in `mode tcp`, passes 80 and 443 through with PROXY protocol v2. The edge Caddy terminates TLS and gets certificates for every domain itself. | Certificates need no extra tool. Adding a club is one Caddy block. Real client IP via PROXY protocol. | HAProxy cannot look at paths or headers. Filtering by path happens in Caddy. |
| B | HAProxy terminates TLS, certificates by acme.sh or HAProxy's own ACME support (verify for the installed version), plain HTTP to Caddy. | All TLS in one place. HAProxy can route and filter by path. | Certificate tooling to build and renew. More HAProxy config per club. |

Florian chose A. With B, the edge Caddy runs with `auto_https off` and HAProxy gets the certificate role.
The sothyr-pages `EDGE=external` switch works with both: the site router is plain HTTP either way.

## Networks

| Network | Members | Purpose |
|---|---|---|
| host | HAProxy | Only process that listens on public 80 and 443 |
| `edge` (Podman, internal) | edge Caddy, each site router | HTTP from the edge router to the sites |
| `<site>_internal` (one per site) | services of that site | Exists today in the template, unchanged |
| `sothyr-db` (Podman, internal, no internet) | shared Postgres and MariaDB, and every service that uses a database: wordpress of each club, Keycloak, pretix, Umami | Databases are never on `edge` or `sothyr-shared` |
| `sothyr-shared` (Podman, internal) | shared pretix, shared Keycloak, shared Umami, Redis, the mail relay, and the `api` and `wordpress` of each site | Sites reach pretix and Keycloak inside the VM, never over the internet |
| `edge` also joins pretix, Keycloak and Umami | edge Caddy, pretix, Keycloak, Umami | public ticket and login pages |

Rules:

- Containers publish no ports, with one exception: the edge Caddy publishes `127.0.0.1:8080` and `127.0.0.1:8443` for HAProxy.
  Podman port publishing goes around firewalld zones, so never publish on `0.0.0.0`. Check with `ss -tlnp` in the acceptance test.
- Networks marked internal have no route to the internet where the service does not need one.
  The api needs outgoing access (SMTP, calendar ICS), wordpress for updates. Verify per service.
- IPv6: HAProxy listens on both. Podman networks can stay IPv4 behind it.
- Admin interfaces (Keycloak admin console, pretix control, WordPress admin, Umami) are reachable only through WireGuard.
  See "Admin access".

## Admin access with WireGuard (decided)

Kept small so it is little work for one developer:

- WireGuard on the host, interface `wg0`, subnet e.g. `10.66.0.0/24`, server `10.66.0.1`, one UDP port open in firewalld and the Hetzner firewall.
- One peer per admin device. The Ansible role generates keys and writes each client config to a local folder
  (and as a QR code for phones). Adding a device: add a name to `wireguard_peers`, run the playbook, import the file.
- HAProxy also listens on `10.66.0.1:443` and `:80`. The edge Caddy sees the client IP through PROXY protocol.
- Admin routes in Caddy allow only `remote_ip 10.66.0.0/24`. Everyone else gets 403.
- Admin host names resolve to the public IP for everyone. Over the tunnel they must resolve to `10.66.0.1`.
  The client config sets `DNS = 10.66.0.1`. A tiny resolver on the host (unbound or dnsmasq, verify the EL10 package)
  answers the club host names with `10.66.0.1` and forwards everything else. No hosts file edits on the laptop.
- SSH: key only, public at first. Once WireGuard works, optionally only over `wg0`. Rescue path is the Hetzner web console.

## Scope and size (decided)

- Start: 3 clubs on one VM. Only one of them uses tickets (pretix). First club to bring live: Bodensee Players.
- Per club in `sites.yml`: `tickets: true|false`. pretix runs on the VM only if at least one club has tickets.
  An organizer, token and `tickets.` DNS record exist only for clubs with tickets.
- Start with a small VM type and memory limits per service. Scale the VM later (Hetzner allows a bigger type on the same server). No multi VM setup now,
  but keep `inventory` groups so a second VM is possible.
- Monitoring and alerting: later, also with Ansible. Not in the first version. Until then: the auto-update failure mail and the daily mail report.
- The Ludite preset is a separate feature of sothyr-pages, not part of this plan.

## Secrets

- No vault server. Secrets live in `group_vars/all/vault.yml`, encrypted with the `ansible-vault` command that ships with Ansible.
- The vault password is a file on Florian's machine outside the repo (e.g. `~/.ansible/vault-pass-hetzner`), set in `ansible.cfg` as `vault_password_file`.
- CI does not run playbooks for now, so CI never needs the vault password.
- Generated secrets (database passwords, DKIM private keys, Keycloak client secrets) are created once by Ansible and written back into the vault file,
  or created with a lookup that stores them in a local, git ignored folder. Pick one way and document it.

## Ansible layout

```
inventory/hosts.yml              one host now, groups ready for more
group_vars/all/main.yml          common settings
group_vars/all/vault.yml         secrets, encrypted with ansible-vault (a file in the repo, no vault server)
host_vars/<host>/sites.yml       list of club sites on that host
roles/
  base/            dnf packages, EPEL, timezone, dnf-automatic, swap, journald limits, SELinux tools
  users_ssh/       admin user, SSH keys only, no root login, no password login
  firewall/        firewalld zones on the host; Hetzner Cloud Firewall via the hcloud collection (verify module names)
  container_runtime/  rootful Podman, Quadlet units, networks `edge` and `sothyr-shared`, podman-auto-update timer, registry login, log limits
  registry/        repo.sothyr.de: distribution registry, htpasswd users, garbage collection timer
  haproxy/         package, haproxy.cfg from template, stats page on localhost only, reload handler
  edge_router/     edge Caddy container, Caddyfile from the sites list, network `edge`
  shared_postgres/ one Postgres for pretix, Keycloak and Umami (separate databases and users)
  shared_mariadb/  one MariaDB; per club one database `wp_<slug>` and one user with rights only on it
  shared_pretix/   pretix and Redis on `sothyr-shared`; organizer, domain and token per site (script from the ticket plan)
  shared_umami/    Umami on `sothyr-shared`; one website per club, its id into the club's site.config.json
  shared_keycloak/ Keycloak on `sothyr-shared`; realm per site from the template realm of sothyr-pages; login theme per realm
  site/            one instance of sothyr-pages per entry in sites.yml
  dns/             zones and records per club through the Hetzner Cloud DNS API
  shared_mail/     Postfix with DKIM per club domain, delivery only through a smart host (shared service or the club's SMTP)
  wireguard/       wg0, peers from a list, client configs and QR codes, small DNS resolver
  backup/          Hetzner daily backups on; nightly local dumps; off-site copy prepared but off
playbooks/
  bootstrap.yml    first run on a fresh VM: base, users_ssh, firewall, runtime, haproxy
  platform.yml     edge_router, shared_pretix, backup
  site.yml         add or update one site: -e site=<slug>
```

One site entry in `sites.yml`:

```yaml
- slug: bodensee-players
  domain: bodensee-players.de
  extra_domains: [www.bodensee-players.de]
  repo_version: v1.0.0          # tag of sothyr-pages
  preset: theatre
  admin_email: ...
```

Derived per site (decided: everything per club domain): `www.`, `cms.`, `auth.`, `stats.`, `tickets.` subdomains, one DNS record each, `SITE_SLUG`, `EDGE=external`,
the `.env` from a template with secrets from the vault, the pretix organizer with domain and token.

The `site` role:

1. Checks out sothyr-pages at `repo_version` into `/srv/sites/<slug>`.
2. Writes `.env` and `site.config.json` from templates. Never overwrites secrets that exist.
3. Writes Quadlet units for the site's containers with `EDGE=external` settings, joined to `edge` and `sothyr-shared`, and starts them.
4. Adds the site block to the edge Caddyfile and reloads Caddy.
5. Runs the site's init jobs (wp-init, keycloak import).
6. Smoke test: `https://<domain>/api/health` through HAProxy.

## Shared databases (decided)

- One Postgres (Keycloak, pretix, Umami) and one MariaDB (WordPress of every club), pinned versions, on network `sothyr-db` only.
- Isolation: one database and one user per club or service. A user has rights only on its own database. Passwords per user in the vault.
  The root or superuser password is never handed to a site.
- The `site` role creates the club's MariaDB database and user before WordPress starts, and drops nothing on its own.
  Removing a club is a separate, explicit playbook with a final dump first.
- Tuning: set memory limits for both servers so many small clubs fit (buffer pool, max connections). Start small, measure.
- Upgrades of a database server affect every club. Dump all, upgrade on purpose with a playbook, never by auto-update.
- Backup: the nightly dump timer dumps each database on its own (`mariadb-dump` per database, `pg_dump` per database),
  so one club can be restored without touching the others.

## Shared Keycloak

- One realm per club, named after the slug. Created from `keycloak/realm-export.json` of sothyr-pages with the slug filled in.
  Clients `site` and `wordpress` per realm with the club's URLs. Client secrets go to the vault and into the club's `.env`.
- Roles per realm as in the template: `cms-admin`, `cms-editor`, `tickets-admin`, `tickets-boxoffice`.
- Login host: per club `auth.<club domain>` (decided). Use the realm attribute for the frontend URL.
  Verify that the installed Keycloak version allows this with its hostname settings. If not, stop and ask Florian before falling back to one shared host.
- Login theme per realm: sothyr-pages generates `tokens.css` per theme. The role copies the club's theme into
  `themes/sothyr-<slug>` and sets it as the realm's login theme. Keycloak needs a restart or cache clear for new themes, verify.
- Upgrades of the shared Keycloak affect every club. Pin the version, test on a staging realm first.

## Shared Umami

- One Umami, one website per club. The role creates the website through the Umami API (verify the endpoints of the installed version)
  and writes its id to `analytics.websiteId` in the club's `site.config.json`.
- One Umami user per club that sees only its own website, if the installed version supports teams or per-user websites. Verify.
- Tracking script: `stats.<club domain>` routed to the shared Umami (decided). First party, less often blocked.

## DNS and mail per club, automated

Goal: every club sends valid mail from its own domain (SPF, DKIM, DMARC pass), with no manual DNS work per club.

Certificates do not help here. Caddy gets a certificate with only an A record. Mail needs TXT records
in the club's zone, and only something with write access to that zone can set them.

### DNS: the club zone lives in Florian's Hetzner project

- One-time step per club: the club points its domain's name servers to Hetzner DNS (or Florian registers the domain).
- From then on Ansible owns the records with `hetzner.hcloud.zone` and `hetzner.hcloud.zone_rrset` (Hetzner Cloud DNS API).
  Verify module options against the installed collection version.
- The `site` role writes per club: `@`, `www`, `cms`, `auth`, `stats`, `tickets` (A and AAAA),
  SPF, DKIM, DMARC, and nothing it does not own. Records the club needs for its own mailbox (MX, provider TXT) come from
  `sites.yml` (`dns_extra`) and stay untouched otherwise.
- Per club in `sites.yml`: `dns_mode: hetzner` (zone in Florian's project, fully automatic) or `dns_mode: external`.
  Decided: Ludite moves to Hetzner. Other clubs are unknown, so both modes are required from the start.
- With `dns_mode: external` the club keeps its DNS elsewhere and sets once a fixed set of records that point to Florian's domain
  (`CNAME` for the web names and for DKIM, `include:` in SPF). Keys and IPs can then change centrally without asking the club again.
  The role prints exactly these records for the club, ready to send, and checks with a DNS lookup whether they are set.
  Until they are, mail for that club stays off and the contact form shows its error text. No mail is lost silently.

### Sending: one shared mail relay

Start from what exists: `C:\develop\solo-rpgs\mail` (Dockerfile, entrypoint.sh, README.md).
It is a send-only Postfix plus OpenDKIM container on Alpine, already multi-domain (`MAIL_DOMAINS`),
one DKIM key per domain in a volume, selector `mail`, optional smart host with `RELAYHOST`, `RELAY_USER`, `RELAY_PASS`.
Its README names Mailjet (`[in-v3.mailjet.com]:587`) as the example smart host.

Plan: lift that container into this repo as the image of `shared_mail` (or build it from solo-rpgs, decide which repo owns it),
and close these gaps before many clubs use it:

- Sender check: today any sender from the internal networks is relayed. Add `smtpd_sender_restrictions` with a map of allowed
  sender domains from `sites.yml` (`reject_sender_login_mismatch` does not fit, there is no login; use a check_sender_access map).
- Signing failure: today `milter_default_action=accept` sends unsigned mail when OpenDKIM fails. Use `tempfail` so mail waits instead of failing DMARC.
- One smart host for all today (`relayhost` plus static SASL). Add sender dependent relay maps for clubs with their own smart host
  (`sender_dependent_relayhost_maps`, `smtp_sender_dependent_authentication`, SASL password map per sender domain). Verify option names.
- `mynetworks` defaults to all private ranges. Restrict to the `sothyr-shared` subnet.
- Keys: keep selector `mail` and keep existing keys. ludite-kisslegg.de may already have a published DKIM record from solo-rpgs.
  Move that key into the new volume instead of creating a new one, so DNS stays valid.
- Ansible reads each public key from `/etc/opendkim/keys/<domain>/mail.txt` and writes it as TXT (dns_mode hetzner)
  or prints it for the club (dns_mode external).
- solo-rpgs can then send through the same shared relay instead of its own container. Optional, later.


- New role `shared_mail`: one Postfix container on `sothyr-shared`. Every site api, Keycloak, pretix and WordPress send to it
  without auth from the internal network only. It is not reachable from outside.
- It signs every mail with the DKIM key of the sender domain (OpenDKIM or Postfix plus rspamd, pick one and verify the EL10 or container image).
  Ansible creates one key per club (selector `sothyr`), keeps the private key in the vault, publishes the public key as TXT.
- It only accepts sender domains from `sites.yml`. Anything else is rejected, so one club cannot send as another.
- Delivery only through a smart host on port 587 (decided). Hetzner blocks outgoing 25 and 465 on cloud servers,
  and port 25 will not be unblocked. No direct delivery, no MX lookups from the VM.
- Smart host: by default the shared Mailjet account. A club can bring its own account or mailbox provider.
  Details in "Smart host per club". There is no `mail_delivery` switch any more, only the optional `smarthost` block.
  Each sending account wants its sender domains verified with DNS records. With `dns_mode: hetzner` Ansible sets them,
  with `external` they go on the list for the club.
- SPF per club: the club's existing part plus the include of the smart host in use. No VM IPs in SPF.
- Reverse DNS of the VM is not needed for mail. Set it anyway to a clean host name.
- DMARC per club: `p=quarantine` at start, reports to an address of Florian. Move to `p=reject` once the reports are clean.

### Smart host: Mailjet free plan (decided)

- Florian has a Mailjet account on the free plan. `relayhost=[in-v3.mailjet.com]:587`, SASL with API key and secret key from the vault.
- Limits of the free plan, reported by several sources in 2026: 6,000 mails per month, 200 per day. Verify on the Mailjet pricing page.
  The limit counts for all clubs together, because they share one account.
  - Watch it: a small daily report from the Postfix log (mails sent per sender domain). Warn at 150 per day.
  - When Mailjet refuses, Postfix keeps the mail in its queue and retries. Check that Mailjet answers with a temporary error (4xx) and not a hard bounce.
  - The upgrade path is a paid plan without the daily cap. Only the account changes, not the setup.
  - Clubs with their own Mailjet account send through that account (see "Smart host per club"). That takes them out of the shared limit.
- Some reviews say mails on the free plan carry Mailjet branding. That may only apply to campaigns, not to SMTP relay. Check with one test mail before going live.
- Every sender domain must be validated in Mailjet (sender domain plus its SPF and DKIM). For `dns_mode: hetzner` Ansible
  writes the records Mailjet asks for. Check whether the Mailjet API can create the sender domain and return the records; otherwise list it as a manual step per club.
- SPF per club: the club's own part plus Mailjet's include (look up the current include name in the Mailjet docs).
- DKIM: our own key (selector `mail`) signs. Mailjet adds its own signature too. Both must align with the From domain for DMARC. Verify with the headers of a test mail.

### Smart host per club (decided)

A club may bring its own sending account. Then its mail goes through that account, the others stay on the shared one.

In `sites.yml`, optional per club:

```yaml
smarthost:                    # missing = shared Mailjet account
  host: "[in-v3.mailjet.com]:587"   # own Mailjet account, or the club's mailbox provider
  user_vault_key: mailjet_ludite_user
  pass_vault_key: mailjet_ludite_pass
  spf_include: spf.mailjet.com      # look up the real include, see Mailjet docs
```

- One mechanism for every case: shared Mailjet, the club's own Mailjet, or the club's mailbox provider (a mailbox provider is just this with another host).
- Postfix picks host and credentials by sender domain: `sender_dependent_relayhost_maps`, `smtp_sender_dependent_authentication = yes`,
  `smtp_sasl_password_maps` keyed by sender domain. The shared account stays as the default `relayhost`. Verify the option names and the map lookup keys.
  Same host with different credentials (two Mailjet accounts) must work. Test that explicitly.
- Credentials only in the vault. The maps are written by Ansible, `postmap` runs in the container, files are mode 600.
- The daily report counts per sender domain and per account, so the shared limit only counts clubs on the shared account.
- Mailjet domain validation then happens in the club's own account. With `dns_mode: hetzner` Ansible still writes the records.

### SPF and the club's own mailbox

Many clubs already have a mailbox at a provider (IONOS, Strato, Google). There is only one SPF record per domain.
So SPF is built from both: our part plus `spf_include` from `sites.yml` for the club's provider.
Never overwrite an existing SPF without merging. On the first run for a club, read the current records, show the diff, stop if SPF exists and `spf_include` is empty.

### Acceptance

- New club in `sites.yml`, name servers at Hetzner, one playbook run: site, certificates, DNS records and DKIM key exist.
- A test mail from the contact form passes SPF, DKIM and DMARC at a large mailbox provider (check the headers).
- A mail with a sender domain not in `sites.yml` is rejected by the relay.

## Container registry repo.sothyr.de

Florian runs `repo.sothyr.de` today elsewhere with the `registry:2` image. It moves onto this VM.

- Service: the same registry software. `registry:2` is a moving major tag. Pin a concrete version on the VM and check whether a newer major (3) is out and compatible with the stored data before choosing as a shared container on `edge`.
  Caddy terminates TLS for `repo.sothyr.de` like for every other host name.
- Auth: htpasswd users from the vault. One push user for CI, one pull user for the VM. Anonymous pull off.
  Verify that the registry's htpasswd needs bcrypt and generate it in Ansible.
- Storage: a volume under `/srv/registry`. Set an upload size limit in Caddy that fits the image sizes.
- Clean up: a weekly timer runs the registry garbage collection in read only mode, verify the exact command and that the registry must be paused or read only during it.
  Keep the last N tags per image with a small cleanup script or a tool, decide when the disk fills.
- Backup: images can be rebuilt from git, so the registry volume is not in the dumps. It is in the Hetzner VM backup anyway.
- Moving from the current host: copy the images with `skopeo sync` (verify the flags), then switch DNS. `repo.sothyr.de` needs `dns_mode` like a club domain.
- Pushes come from CI (sothyr-pages has `azure-pipelines.yml`) and from Florian's machine. Both public with auth, not only over WireGuard.
- Podman on the VM logs in once with the pull user (Ansible writes the root auth file, mode 600).

## Automatic image updates

Watchtower itself is archived since 17 December 2025. A maintained fork exists (`nickfedor/watchtower`), but it targets the Docker API.
Podman has the same feature built in: `podman auto-update` with the label `io.containers.autoupdate=registry` and a systemd timer.
It needs containers managed by systemd units (Quadlets). It can roll back when the new container fails to start.

Decided: `podman auto-update`, not a Watchtower container.

- This changes one earlier decision: services run as Quadlet units from the start, not as podman-compose projects.
  Ansible writes the Quadlet files (`.container`, `.network`, `.volume`) per site from templates. Verify the module support in `containers.podman`.
  The compose files of sothyr-pages stay for `bundled` and local development.
- Only our own images update automatically: frontend and api of sothyr-pages, the mail relay. They follow a moving tag, e.g. `:stable`.
  Third party images (Keycloak, pretix, Postgres, MariaDB, Umami, Caddy, registry) are pinned and updated on purpose with a playbook run,
  because a new major version can need a migration.
- Timer: daily at night, after the backup dumps. Log to the journal. A failed update rolls back and sends a mail to Florian.
- Release flow: CI builds and pushes `:<version>` and moves `:stable`. At night every club gets it. A club can be pinned to a version in `sites.yml` (`image_tag`), then it does not follow `:stable`.

## Backup (decided)

- Hetzner Cloud backups of the whole VM, daily, switched on through the hcloud collection. Hetzner keeps a fixed number of slots, verify how many and the cost.
- A VM snapshot of running databases can be inconsistent. So a timer runs before the backup window and writes dumps
  of every database, one file per database (shared MariaDB and shared Postgres) to `/srv/backup/dumps`, keeping the last 3 days.
  The snapshot then contains clean dumps. Verify the backup window of the Hetzner project.
- Prepared but off: off-site copy of `/srv/backup` and the volumes with restic to a Hetzner Storage Box or any S3 target.
  Switch `backup_offsite_enabled: true` and set the target in the vault. Nothing else to change.
- Restore guide in the README: restore one club from a dump without touching the others.

## Changes needed in sothyr-pages

These belong to the sothyr-pages repo, listed here so both plans match:

- `EDGE=external`: site Caddy without published ports, `auto_https off`, listening on `:80`, member of network `edge` with alias `<slug>-router`.
- On the VM the hosted setup runs as Quadlet units written by Ansible, not from compose.
  `compose.hosted.yml` in sothyr-pages is still useful to test the hosted layout locally with `-f compose.yml -f compose.hosted.yml`.
  Keep both in line: same services, same environment variables, same networks.
- Images: CI builds `frontend` and `api` and pushes them to `repo.sothyr.de/sothyr-pages/<name>:<version>` and `:stable`.
  The server never builds. The hosted setup uses `image:` from the registry, not `build:`.
- `compose.hosted.yml` leaves out keycloak, pretix, pretix-init, umami, postgres, redis and mariadb.
  Today `compose.yml` hard codes `WORDPRESS_DB_HOST: mariadb`, `WORDPRESS_DB_NAME: wordpress` and `WORDPRESS_DB_USER: wordpress`.
  Make them `.env` values with these defaults, so `bundled` stays unchanged and `hosted` points to the shared MariaDB and `wp_<slug>`. and joins `edge` and `sothyr-shared`.
  The base `compose.yml` stays the full `bundled` stack.
- URLs of Keycloak and pretix come from `.env` already. In hosted mode they point to the shared services,
  the server side uses the internal names (`http://keycloak:8080`, `http://pretix`), the browser the public ones.
- Services trust `X-Forwarded-*` only from the edge network.

## Acceptance

- Fresh VM: `bootstrap.yml` then `platform.yml` then `site.yml -e site=bodensee-players` gives a working site with https.
- A second site with another domain works next to it and sees only its own pretix organizer.
- `ss -tlnp` on the host shows only sshd, HAProxy on 80 and 443, and the edge Caddy on 127.0.0.1.
- Admin URLs answer 403 from a non-admin IP.
- Running every playbook twice changes nothing the second time.
- A restore of one site from the backup works on a test VM.

## Conventions for the implementer

- Do not guess module names, package versions or flags. Check docs of the installed Ansible collections.
- Every role idempotent, with `--check` support where possible.
- Secrets only in `vault.yml`. Never print them in task output (`no_log: true`).
- English, short sentences, no em dashes.
- Florian runs the playbooks. Tell him the exact commands.

## Open points for Florian

None.

Decided:
TLS at Caddy (A), admin access through WireGuard, Hetzner daily backups with off-site prepared, all host names per club domain,
DNS at Hetzner for Ludite and external DNS supported, mail only through a smart host, shared Mailjet free account,
clubs may bring their own smart host, Postgres and MariaDB shared, registry repo.sothyr.de (today `registry:2`) moves to the VM,
automatic updates of own images with `podman auto-update` and Quadlets.

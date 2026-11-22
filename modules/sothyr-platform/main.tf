# Preset: the shared services of sothyr-pages (compose.platform.yml) as one stack.
# sothyr-pages stays the owner of the services. This module only fills platform.env and starts the stack.
terraform {
  required_version = ">= 1.10"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

variable "stack_name" {
  description = "Name of the stack on the host."
  type        = string
  default     = "sothyr-platform"
}

variable "git" {
  description = "Checkout of sothyr-pages. ref is a tag, branch or commit."
  type = object({
    url        = string
    ref        = string
    deploy_key = optional(string)
  })
}

variable "auth_host" {
  description = "Public host name of the shared Keycloak, e.g. auth.example.org."
  type        = string
}

variable "stats_host" {
  description = "Public host name of the shared Umami."
  type        = string
}

variable "tickets_host" {
  description = "Public host name of the shared pretix."
  type        = string
}

variable "platform_name" {
  type    = string
  default = "Tickets"
}

variable "keycloak_version" {
  type    = string
  default = "26.0"
}

variable "keycloak_admin_user" {
  type    = string
  default = "admin"
}

variable "mail" {
  description = "Mail of pretix and of the clubs. Default: the platform relay smtprelay:25."
  type = object({
    host     = optional(string, "smtprelay")
    port     = optional(number, 25)
    user     = optional(string, "")
    password = optional(string, "")
    from     = string
  })
  sensitive = true
}

variable "umami_admin_password" {
  description = "Admin password of Umami after you changed it from the default. Null keeps the default of sothyr-pages."
  type        = string
  default     = null
  sensitive   = true
}

variable "backup_containers" {
  description = "Container names for the nightly dumps (podman-compose naming)."
  type = object({
    postgres = optional(string, "sothyr-platform_postgres_1")
    mariadb  = optional(string, "sothyr-platform_mariadb_1")
  })
  default = {}
}

variable "edge_ports" {
  description = "Local ports of the platform Caddy behind HAProxy. Must match the haproxy settings of the host."
  type = object({
    http  = optional(number, 8080)
    https = optional(number, 8443)
  })
  default = {}
}

variable "proxy_sources" {
  description = "Source ranges that may send a PROXY header to Caddy. Podman forwards from its bridge address."
  type        = list(string)
  default     = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "smtprelay_config" {
  description = "Content of platform/smtprelayd/smtprelayd.toml. Null keeps the relay off."
  type        = string
  default     = null
}

variable "smarthost_password" {
  description = "Password of the smarthost, read by the relay config as SMTPRELAYD_SMARTHOST_PASSWORD."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  secret_names = [
    "POSTGRES_PASSWORD", "PRETIX_DB_PASSWORD", "KEYCLOAK_DB_PASSWORD", "UMAMI_DB_PASSWORD",
    "MARIADB_ROOT_PASSWORD", "PRETIX_DJANGO_SECRET", "UMAMI_APP_SECRET", "KEYCLOAK_ADMIN_PASSWORD",
  ]

  # Same list as PLATFORM_SECRETS in tools/stack.py of sothyr-pages. Only the platform and its register jobs see them.
  platform_secrets = [
    "POSTGRES_PASSWORD", "PRETIX_DB_PASSWORD", "KEYCLOAK_DB_PASSWORD", "UMAMI_DB_PASSWORD", "MARIADB_ROOT_PASSWORD",
    "PRETIX_DJANGO_SECRET", "UMAMI_APP_SECRET", "KEYCLOAK_ADMIN_USER", "KEYCLOAK_ADMIN_PASSWORD",
    "UMAMI_ADMIN_USERNAME", "UMAMI_ADMIN_PASSWORD", "SMTPRELAYD_SMARTHOST_PASSWORD",
  ]
  relay = var.smtprelay_config != null

  # HAProxy on the host owns 80 and 443. The platform Caddy only listens on localhost.
  # !override replaces the port list of compose.platform.yml (podman-compose >= 1.2).
  override = <<-EOT
    # Written by hetzner-host-config. HAProxy on the host owns 80 and 443.
    services:
      caddy:
        ports: !override
          - "127.0.0.1:${var.edge_ports.http}:80"
          - "127.0.0.1:${var.edge_ports.https}:443"
  EOT

  # Adds the PROXY protocol listener to the global block of platform/Caddyfile. Idempotent.
  # The register jobs of the clubs load the same file into Caddy, so their checkouts get the same patch.
  caddyfile_patch = <<-EOT
    f=platform/Caddyfile
    marker='# hhc: PROXY protocol from HAProxy'
    grep -qF "$marker" "$f" && exit 0
    grep -q '^[[:space:]]*admin unix//' "$f" || { echo "$f: no 'admin unix//' line in the global block, update the patch" >&2; exit 1; }
    awk -v marker="$marker" -v allow="${join(" ", var.proxy_sources)}" '
      { print }
      !done && /^[[:space:]]*admin unix\/\// {
        print "\t" marker
        print "\tservers {"
        print "\t\tlistener_wrappers {"
        print "\t\t\tproxy_protocol {"
        print "\t\t\t\tallow " allow
        print "\t\t\t\tfallback_policy reject"
        print "\t\t\t}"
        print "\t\t\ttls"
        print "\t\t}"
        print "\t}"
        done = 1
      }' "$f" > "$f.hhc"
    mv "$f.hhc" "$f"
  EOT
}

# Letters and digits only. sothyr-pages forbids quotes and backslashes in passwords.
resource "random_password" "secret" {
  for_each = toset(local.secret_names)
  length   = 40
  special  = false
}

locals {
  env = merge(
    { for k in local.secret_names : k => random_password.secret[k].result },
    {
      PLATFORM_NAME                 = var.platform_name
      AUTH_URL                      = "https://${var.auth_host}"
      STATS_URL                     = "https://${var.stats_host}"
      PRETIX_BASE_URL               = "https://${var.tickets_host}"
      HTTP_PORT                     = "80"
      HTTPS_PORT                    = "443"
      KEYCLOAK_VERSION              = var.keycloak_version
      KEYCLOAK_ADMIN_USER           = var.keycloak_admin_user
      SMTP_HOST                     = var.mail.host
      SMTP_PORT                     = tostring(var.mail.port)
      SMTP_USER                     = var.mail.user
      SMTP_PASSWORD                 = var.mail.password
      MAIL_FROM                     = var.mail.from
      SMTPRELAYD_SMARTHOST_PASSWORD = var.smarthost_password
      # As tools/rebuild.py --platform: the volumes of the register jobs carry the slug, a plain start has none.
      SITE_SLUG = ""
    },
    var.umami_admin_password == null ? {} : { UMAMI_ADMIN_PASSWORD = var.umami_admin_password },
  )

  stack = {
    project       = "sothyr-platform"
    git           = var.git
    compose_files = ["compose.platform.yml", "hhc.override.yml"]
    files = merge(
      { "hhc.override.yml" = { content = local.override, mode = "0644" } },
      local.relay ? { "platform/smtprelayd/smtprelayd.toml" = { content = var.smtprelay_config, mode = "0644" } } : {},
    )
    post_checkout = local.caddyfile_patch
    env           = local.env
    profiles      = local.relay ? ["relay"] : []
    pull          = []
    build         = local.relay
    auto_update   = false
    after         = []
  }
}

output "stack_name" {
  value = var.stack_name
}

output "stack" {
  description = "Stack object for the host-runtime module."
  value       = local.stack
  sensitive   = true
}

output "env" {
  description = "Platform values a club stack needs (platform.env)."
  value       = local.env
  sensitive   = true
}

output "hostnames" {
  value = [var.auth_host, var.stats_host, var.tickets_host]
}

output "edge" {
  description = "The platform Caddy is the edge of the host. Route snippets go into its sites volume."
  value = {
    volume    = "sothyr-platform_caddy-sites"
    container = "sothyr-platform_caddy_1"
    caddyfile = "/etc/caddy/Caddyfile"
    network   = "sothyr-shared"
  }
}

output "platform_secrets" {
  description = "Keys a club stack must not see."
  value       = local.platform_secrets
}

output "backup_jobs" {
  description = "Dump commands for the nightly backup of host-runtime."
  value = {
    "sothyr-postgres" = "podman exec ${var.backup_containers.postgres} pg_dumpall -U postgres"
    "sothyr-mariadb"  = "podman exec ${var.backup_containers.mariadb} sh -c 'exec mariadb-dump -uroot -p\"$MARIADB_ROOT_PASSWORD\" --all-databases --single-transaction'"
  }
}

output "caddyfile_patch" {
  description = "post_checkout script for club stacks. Their register job loads platform/Caddyfile into Caddy."
  value       = local.caddyfile_patch
}

output "keycloak" {
  value = {
    url            = "https://${var.auth_host}"
    admin_user     = var.keycloak_admin_user
    admin_password = random_password.secret["KEYCLOAK_ADMIN_PASSWORD"].result
  }
  sensitive = true
}

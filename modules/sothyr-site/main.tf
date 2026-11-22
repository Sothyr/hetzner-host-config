# Preset: one club of sothyr-pages (compose.site.yml) on a running platform.
# The register jobs of sothyr-pages create database, realm, pretix organizer, Umami team and Caddy routing.
terraform {
  required_version = ">= 1.10"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

variable "slug" {
  description = "Short name of the club. Becomes project name, realm and database name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.slug))
    error_message = "slug: lowercase letters, digits and dashes."
  }
}

variable "name" {
  description = "Display name of the club."
  type        = string
}

variable "domain" {
  description = "Main domain of the club, e.g. ludite-kisslegg.de."
  type        = string
}

variable "www" {
  description = "Also serve www.<domain>."
  type        = bool
  default     = true
}

variable "cms_host" {
  description = "Host name of WordPress. Null uses cms.<domain>."
  type        = string
  default     = null
}

variable "tickets" {
  description = "Club sells tickets with the shared pretix. Then env needs PRETIX_URL."
  type        = bool
  default     = false
}

variable "tickets_host" {
  description = "Own ticket host name. Null uses tickets.<domain>."
  type        = string
  default     = null
}

variable "instance_dir" {
  description = "Folder of the club data in the sothyr-pages checkout. Null uses instances/<slug>."
  type        = string
  default     = null
}

variable "git" {
  description = "Checkout of sothyr-pages for this club. Usually the same as the platform."
  type = object({
    url        = string
    ref        = string
    deploy_key = optional(string)
  })
}

variable "platform" {
  description = "Outputs of the sothyr-platform module."
  type = object({
    stack_name       = string
    env              = map(string)
    platform_secrets = list(string)
    caddyfile_patch  = string
  })
  sensitive = true
}

variable "instance_git" {
  description = "Own git repo of the club data, cloned to instance_dir. Null uses the folder of the sothyr-pages checkout."
  type = object({
    url        = string
    ref        = string
    deploy_key = optional(string)
  })
  default = null
}

variable "admin_email" {
  description = "Mail address of the WordPress break glass admin."
  type        = string
}

variable "images" {
  description = "Prebuilt images of api and frontend. Null builds them on the server, which costs a lot of memory."
  type = object({
    api      = string
    frontend = string
  })
  default = null
}

variable "auto_update" {
  description = "Pull new api and frontend images every night (moving tags like :stable)."
  type        = bool
  default     = false
}

variable "env" {
  description = "Further values of the club .env, e.g. CONTACT_TO, MAIL_FROM, CALENDAR_ICS_URL, PRETIX_URL."
  type        = map(string)
  default     = {}
  sensitive   = true
}

locals {
  cms_host     = coalesce(var.cms_host, "cms.${var.domain}")
  tickets_host = coalesce(var.tickets_host, "tickets.${var.domain}")
  instance_dir = coalesce(var.instance_dir, "instances/${var.slug}")
  db_name      = "wp_${replace(var.slug, "-", "_")}"

  # Same as PLATFORM_OWNED in tools/stack.py of sothyr-pages. These values always come from the platform.
  platform_owned = concat(["AUTH_URL", "STATS_URL", "PRETIX_BASE_URL", "HTTP_PORT", "HTTPS_PORT"], var.platform.platform_secrets)

  # Same as REGISTER_JOBS. pretix-init only for a club with tickets.
  register_jobs = concat(["site-db", "site-register", "umami-init"], var.tickets ? ["pretix-init"] : [])

  secret_names = ["WORDPRESS_DB_PASSWORD", "WORDPRESS_OIDC_SECRET", "WORDPRESS_ADMIN_PASSWORD", "CONTACT_SECRET", "CART_SECRET"]
}

resource "random_password" "secret" {
  for_each = toset(local.secret_names)
  length   = 40
  special  = false
}

locals {
  site_env = merge(
    { for k in local.secret_names : k => random_password.secret[k].result },
    {
      SITE_SLUG             = var.slug
      SITE_NAME             = var.name
      SITE_URL              = "https://${var.domain}"
      SITE_WWW_URL          = var.www ? "https://www.${var.domain}" : ""
      CMS_URL               = "https://${local.cms_host}"
      WORDPRESS_DB_NAME     = local.db_name
      WORDPRESS_DB_USER     = local.db_name
      WORDPRESS_ADMIN_EMAIL = var.admin_email
      SITE_CONFIG           = "./${local.instance_dir}/site.config.json"
      CONTENT_DIR           = "./${local.instance_dir}/content"
      BRANDING_DIR          = "./${local.instance_dir}/branding"
    },
    var.tickets ? {
      TICKETS_URL    = "https://${local.tickets_host}"
      TICKETS_DOMAIN = local.tickets_host
    } : {},
    var.env,
  )

  # As tools/stack.py: platform, then club, then the values the platform owns.
  # The register jobs get everything. The club stack gets no platform secret.
  register_env = merge(var.platform.env, local.site_env, { for k in local.platform_owned : k => var.platform.env[k] if contains(keys(var.platform.env), k) })
  env          = { for k, v in local.register_env : k => v if !contains(var.platform.platform_secrets, k) }

  override = var.images == null ? null : yamlencode({
    services = {
      api      = { image = var.images.api }
      frontend = { image = var.images.frontend }
    }
  })

  stack = {
    project       = var.slug
    git           = var.git
    compose_files = concat(["compose.site.yml"], local.override == null ? [] : ["hhc.override.yml"])
    files         = local.override == null ? {} : { "hhc.override.yml" = { content = local.override, mode = "0644" } }
    env           = local.env
    profiles      = []
    pull          = var.images == null ? [] : [var.images.api, var.images.frontend]
    build         = var.images == null
    auto_update   = var.auto_update
    after         = [var.platform.stack_name]
    # The register job loads platform/Caddyfile of this checkout into the shared Caddy.
    post_checkout = var.platform.caddyfile_patch
    checkouts     = var.instance_git == null ? {} : { (local.instance_dir) = var.instance_git }
    # Register jobs of the platform with the values of this club: database, realm, routing, Umami, pretix.
    jobs = {
      project       = "sothyr-platform"
      compose_files = ["compose.platform.yml"]
      profiles      = ["register"]
      services      = local.register_jobs
      env           = local.register_env
    }
  }
}

check "tickets_need_pretix_url" {
  assert {
    condition     = !var.tickets || contains(keys(var.env), "PRETIX_URL")
    error_message = "Club ${var.slug}: tickets = true needs PRETIX_URL in env."
  }
}

output "stack_name" {
  value = var.slug
}

output "stack" {
  value     = local.stack
  sensitive = true
}

output "hostnames" {
  value = compact(concat(
    [var.domain, local.cms_host],
    var.www ? ["www.${var.domain}"] : [],
    var.tickets ? [local.tickets_host] : [],
  ))
}

output "wordpress_admin_password" {
  value     = random_password.secret["WORDPRESS_ADMIN_PASSWORD"].result
  sensitive = true
}

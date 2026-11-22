variable "connection" {
  description = "SSH access of OpenTofu: bootstrap user with a CA certificate, pinned host key."
  type = object({
    host        = string
    user        = string
    host_key    = string
    private_key = string
    certificate = string
  })
  sensitive = true
}

variable "user_ca_public_keys" {
  description = "Public keys of the SSH user CAs. Kept in sync, so a CA rotation is a change of this list."
  type        = list(string)
}

variable "users" {
  description = "Login users. Login only with a certificate that carries one of the principals."
  type = map(object({
    principals = list(string)
    sudo       = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = alltrue([for name, _ in var.users : can(regex("^[a-z_][a-z0-9_-]{0,31}$", name))])
    error_message = "User names must be valid Linux names (lowercase, digits, - and _)."
  }
}

variable "firewalld_ports" {
  description = "Extra ports of firewalld, e.g. [\"9987/udp\"]. ssh, http, https and 443/udp are always open."
  type        = list(string)
  default     = []
}

variable "networks" {
  description = "Podman networks to create before the stacks start. Stacks join them as external networks."
  type = map(object({
    internal = optional(bool, false)
  }))
  default = {}
}

variable "registries" {
  description = "Registry logins for image pulls, by registry host."
  type = map(object({
    username = string
    password = string
  }))
  default   = {}
  sensitive = true
}

variable "stacks" {
  description = "Compose stacks of this host. See README, section Stacks."
  type = map(object({
    project = string
    git = optional(object({
      url        = string
      ref        = string
      deploy_key = optional(string)
    }))
    compose_files = list(string)
    files = optional(map(object({
      content = string
      mode    = optional(string, "0644")
    })), {})
    env         = optional(map(string), {})
    profiles    = optional(list(string), [])
    pull        = optional(list(string), [])
    build       = optional(bool, false)
    auto_update = optional(bool, false)
    after       = optional(list(string), [])
    # Idempotent bash, run in the git checkout after each fetch. For small config patches.
    post_checkout = optional(string)
    # More git checkouts inside the work folder, by relative path, e.g. club data in instances/<slug>.
    checkouts = optional(map(object({
      url        = string
      ref        = string
      deploy_key = optional(string)
    })), {})
    # One-shot services of another compose project, run before the stack starts (compose run --rm).
    jobs = optional(object({
      project       = string
      compose_files = list(string)
      profiles      = optional(list(string), [])
      services      = list(string)
      env           = optional(map(string), {})
    }))
  }))
  default   = {}
  sensitive = true
}

variable "routes" {
  description = "Hosts routed by the edge Caddy to a container. One snippet file per route."
  type = map(object({
    domains   = list(string)
    upstream  = string
    encode    = optional(bool, true)
    max_body  = optional(string)
    allow_ips = optional(list(string))
    extra     = optional(string, "")
  }))
  default = {}
}

variable "edge" {
  description = "Where the route snippets go and which Caddy loads them. Null disables routes."
  type = object({
    volume    = optional(string)
    dir       = optional(string)
    container = string
    caddyfile = optional(string, "/etc/caddy/Caddyfile")
  })
  default = null
}

variable "auto_update_time" {
  description = "systemd OnCalendar of the image update of stacks with auto_update."
  type        = string
  default     = "*-*-* 04:30:00"
}

variable "haproxy" {
  description = "HAProxy on the host, entry point for 80 and 443 when an edge exists. Limits are per client address. The edge Caddy listens on 127.0.0.1:http_port and https_port with PROXY protocol."
  type = object({
    maxconn    = optional(number, 4000)
    conn_rate  = optional(number, 100)
    conn_cur   = optional(number, 60)
    http_port  = optional(number, 8080)
    https_port = optional(number, 8443)
  })
  default = {}
}

variable "backup" {
  description = "Nightly dumps to /srv/backup before the Hetzner backup window. jobs: name => command that prints a dump."
  type = object({
    on_calendar = optional(string, "*-*-* 01:30:00")
    keep_days   = optional(number, 3)
    jobs        = optional(map(string), {})
    # Off-site copy with restic to S3. Off by default. Keys and password: offsite_secrets.
    offsite = optional(object({
      enabled     = optional(bool, false)
      on_calendar = optional(string, "*-*-* 02:30:00")
      repository  = optional(string, "") # s3:fsn1.your-objectstorage.com/<bucket>
      region      = optional(string, "fsn1")
      # Pin a version. Only the restic binary is used from this image.
      image        = optional(string, "docker.io/instrumentisto/restic:latest")
      paths        = optional(list(string), ["/srv/backup"])
      keep_daily   = optional(number, 7)
      keep_weekly  = optional(number, 4)
      keep_monthly = optional(number, 6)
    }), {})
  })
  default = {}
}

variable "offsite_secrets" {
  description = "S3 access key, secret key and restic password of this host. Needed when backup.offsite.enabled is true."
  type = object({
    access_key = string
    secret_key = string
    password   = string
  })
  default   = null
  sensitive = true
}

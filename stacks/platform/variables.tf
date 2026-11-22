variable "hcloud_token" {
  description = "Hetzner Cloud API token (read and write). Set TF_VAR_hcloud_token."
  type        = string
  sensitive   = true
}

variable "state_passphrase" {
  description = "Passphrase of the state encryption, at least 16 characters. Set TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

# --- SSH --------------------------------------------------------------------------------------------------------

variable "ssh" {
  description = "SSH certificate login. OpenTofu signs in as admin_user with its own certificate."
  type = object({
    user_ca_public_keys = list(string)
    admin_user          = optional(string, "hhc")
    admin_principals    = optional(list(string), ["hhc-deploy"])
    private_key_path    = string
    certificate_path    = string
  })

  validation {
    condition     = length(var.ssh.user_ca_public_keys) > 0 && alltrue([for k in var.ssh.user_ca_public_keys : can(regex("^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa) [A-Za-z0-9+/=]+", k))])
    error_message = "ssh.user_ca_public_keys needs at least one OpenSSH public key."
  }
}

variable "users" {
  description = "Login users with certificate principals. hosts = null means every host."
  type = map(object({
    principals = list(string)
    sudo       = optional(bool, false)
    hosts      = optional(list(string))
  }))
  default = {}
}

# --- Hosts --------------------------------------------------------------------------------------------------------

variable "hosts" {
  description = "Servers by name. Everything else points to one of these names."
  type = map(object({
    server_type      = string
    location         = string
    image            = optional(string, "rocky-10")
    backups          = optional(bool, true)
    protection       = optional(bool, true)
    ssh_source_ips   = optional(list(string), ["0.0.0.0/0", "::/0"])
    swap_size        = optional(string, "2G")
    reverse_dns      = optional(string)
    acme_email       = optional(string)
    auto_update_time = optional(string, "*-*-* 04:30:00")
    labels           = optional(map(string), {})
    # Nightly dumps before the Hetzner backup window (check it in the console).
    backup = optional(object({
      on_calendar = optional(string, "*-*-* 01:30:00")
      keep_days   = optional(number, 3)
      # Off-site copy with restic to Hetzner Object Storage (S3). Off by default. Keys: secrets.offsite.
      offsite = optional(object({
        enabled      = optional(bool, false)
        on_calendar  = optional(string, "*-*-* 02:30:00")
        repository   = optional(string, "") # s3:fsn1.your-objectstorage.com/<bucket>
        region       = optional(string, "fsn1")
        image        = optional(string, "docker.io/instrumentisto/restic:latest")
        paths        = optional(list(string), ["/srv/backup"])
        keep_daily   = optional(number, 7)
        keep_weekly  = optional(number, 4)
        keep_monthly = optional(number, 6)
      }), {})
    }), {})
    # HAProxy is the entry point. Limits per client address, edge Caddy on 127.0.0.1:http_port/https_port.
    haproxy = optional(object({
      maxconn    = optional(number, 4000)
      conn_rate  = optional(number, 100)
      conn_cur   = optional(number, 60)
      http_port  = optional(number, 8080)
      https_port = optional(number, 8443)
    }), {})
  }))
}

variable "registries" {
  description = "Registry logins for all hosts, by registry host, e.g. ghcr.io."
  type = map(object({
    username = string
    password = string
  }))
  default   = {}
  sensitive = true
}

variable "secrets" {
  description = "Secret values, kept apart so terraform.tfvars can live in git. Merged into the objects below."
  type = object({
    deploy_keys         = optional(map(string), {})      # by git url
    smarthost_passwords = optional(map(string), {})      # by sothyr host
    smtp_passwords      = optional(map(string), {})      # by sothyr host, for mail.password
    umami_admin         = optional(map(string), {})      # by sothyr host, after you changed it in Umami
    site_env            = optional(map(map(string)), {}) # by "host/slug"
    app_env             = optional(map(map(string)), {}) # by app name
    app_files           = optional(map(map(string)), {}) # by app name, then file path
    offsite = optional(map(object({                      # by host, S3 keys and restic password of the off-site copy
      access_key = string
      secret_key = string
      password   = string
    })), {})
  })
  default   = {}
  sensitive = true
}

# --- sothyr-pages -------------------------------------------------------------------------------------------------

# Not marked sensitive, because host names and keys drive for_each. Keep secrets of these objects in a
# git ignored *.auto.tfvars file. Everything that reaches the host is sensitive in the host-runtime module.
variable "sothyr" {
  description = "sothyr-pages platform and clubs, by host name. One platform per host."
  type = map(object({
    git = object({
      url        = string
      ref        = string
      deploy_key = optional(string)
    })
    auth_host        = string
    stats_host       = string
    tickets_host     = string
    platform_name    = optional(string, "Tickets")
    keycloak_version = optional(string, "26.0")
    mail = object({
      host     = optional(string, "smtprelay")
      port     = optional(number, 25)
      user     = optional(string, "")
      password = optional(string, "")
      from     = string
    })
    smtprelay_config   = optional(string)
    smarthost_password = optional(string, "")

    sites = optional(map(object({
      name         = string
      domain       = string
      www          = optional(bool, true)
      cms_host     = optional(string)
      tickets      = optional(bool, false)
      tickets_host = optional(string)
      instance_dir = optional(string)
      # Own git repo of the club data, cloned to instance_dir.
      instance_git = optional(object({
        url = string
        ref = string
      }))
      ref         = optional(string)
      admin_email = string
      images = optional(object({
        api      = string
        frontend = string
      }))
      auto_update = optional(bool, false)
      env         = optional(map(string), {})
    })), {})
  }))
  default = {}
}

# --- Other apps ---------------------------------------------------------------------------------------------------

variable "apps" {
  description = "Any other compose stack. Routes publish it through the edge Caddy of its host."
  type = map(object({
    host    = string
    project = optional(string)
    git = optional(object({
      url        = string
      ref        = string
      deploy_key = optional(string)
    }))
    compose_files = optional(list(string), ["compose.yml"])
    files = optional(map(object({
      content = string
      mode    = optional(string, "0644")
    })), {})
    env           = optional(map(string), {})
    profiles      = optional(list(string), [])
    pull          = optional(list(string), [])
    build         = optional(bool, false)
    auto_update   = optional(bool, false)
    after         = optional(list(string), [])
    post_checkout = optional(string)
    # Ports published straight on the host, e.g. ["9987/udp", "30033/tcp"]. Opened in both firewalls.
    ports = optional(list(string), [])
    routes = optional(map(object({
      domains   = list(string)
      upstream  = string
      encode    = optional(bool, true)
      max_body  = optional(string)
      allow_ips = optional(list(string))
      extra     = optional(string, "")
    })), {})
  }))
  default = {}
}

# --- DNS ----------------------------------------------------------------------------------------------------------

variable "dns_zones" {
  description = "Zones by domain. A and AAAA of every used host name are added to the zone it belongs to."
  type = map(object({
    mode = optional(string, "hetzner")
    records = optional(list(object({
      name   = string
      type   = string
      values = list(string)
      ttl    = optional(number)
    })), [])
  }))
  default = {}
}

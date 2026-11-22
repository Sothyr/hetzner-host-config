# Preset: a small standalone Caddy behind HAProxy, for hosts without the sothyr platform.
# It serves only the route snippets of host-runtime (hhc-*.caddy) and gets certificates for them.
terraform {
  required_version = ">= 1.10"
}

variable "stack_name" {
  type    = string
  default = "edge"
}

variable "image" {
  description = "Caddy image. Pin a version you have tested."
  type        = string
  default     = "docker.io/library/caddy:2"
}

variable "network" {
  description = "Podman network shared with the apps behind the edge. Created by host-runtime."
  type        = string
  default     = "edge"
}

variable "acme_email" {
  description = "Mail address for Let's Encrypt."
  type        = string
}

variable "edge_ports" {
  description = "Local ports behind HAProxy."
  type = object({
    http  = optional(number, 8080)
    https = optional(number, 8443)
  })
  default = {}
}

variable "proxy_sources" {
  type    = list(string)
  default = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "memory" {
  type    = string
  default = "128m"
}

locals {
  dir = "/srv/stacks/${var.stack_name}/files"

  caddyfile = <<-EOT
    {
    	email ${var.acme_email}
    	# HAProxy on the host sends the client address by PROXY protocol.
    	servers {
    		listener_wrappers {
    			proxy_protocol {
    				allow ${join(" ", var.proxy_sources)}
    				fallback_policy reject
    			}
    			tls
    		}
    	}
    }

    import /etc/caddy/sites/*.caddy
  EOT

  compose = yamlencode({
    name = var.stack_name
    services = {
      caddy = {
        image     = var.image
        restart   = "unless-stopped"
        mem_limit = var.memory
        ports     = ["127.0.0.1:${var.edge_ports.http}:80", "127.0.0.1:${var.edge_ports.https}:443"]
        volumes = [
          "./Caddyfile:/etc/caddy/Caddyfile:ro",
          "./sites:/etc/caddy/sites:ro",
          "caddy-data:/data",
          "caddy-config:/config",
        ]
        networks = [var.network]
      }
    }
    networks = { (var.network) = { external = true } }
    volumes  = { caddy-data = {}, caddy-config = {} }
  })
}

output "stack_name" {
  value = var.stack_name
}

output "stack" {
  value = {
    project       = var.stack_name
    git           = null
    compose_files = ["compose.yml"]
    files = {
      "compose.yml" = { content = local.compose, mode = "0644" }
      "Caddyfile"   = { content = local.caddyfile, mode = "0644" }
      "sites/.keep" = { content = "", mode = "0644" }
    }
    env         = {}
    profiles    = []
    pull        = [var.image]
    build       = false
    auto_update = false
    after       = []
  }
}

output "edge" {
  value = {
    dir       = "${local.dir}/sites"
    container = "${var.stack_name}_caddy_1"
    caddyfile = "/etc/caddy/Caddyfile"
    network   = var.network
  }
}

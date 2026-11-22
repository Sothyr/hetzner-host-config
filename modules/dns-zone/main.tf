terraform {
  required_version = ">= 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}

variable "zone" {
  description = "Domain of the zone, e.g. example.org."
  type        = string
}

variable "mode" {
  description = "hetzner: zone and records live in Hetzner DNS. external: DNS stays elsewhere, records are only listed."
  type        = string
  default     = "hetzner"

  validation {
    condition     = contains(["hetzner", "external"], var.mode)
    error_message = "mode must be hetzner or external."
  }
}

variable "ttl" {
  type    = number
  default = 3600
}

variable "records" {
  description = "Record sets. name is relative to the zone, @ for the apex. TXT values are quoted automatically."
  type = list(object({
    name   = string
    type   = string
    values = list(string)
    ttl    = optional(number)
  }))
  default = []
}

variable "protection" {
  description = "Delete protection of the zone."
  type        = bool
  default     = true
}

locals {
  # One record set per name and type. Values of duplicates are merged.
  sets = {
    for key, group in {
      for r in var.records : "${r.name}/${upper(r.type)}" => r...
    } :
    key => {
      name   = group[0].name
      type   = upper(group[0].type)
      ttl    = try(coalesce([for r in group : r.ttl if r.ttl != null]...), var.ttl)
      values = distinct(flatten([for r in group : r.values]))
    }
  }

  listing = [
    for key in sort(keys(local.sets)) : {
      fqdn   = local.sets[key].name == "@" ? var.zone : "${local.sets[key].name}.${var.zone}"
      type   = local.sets[key].type
      ttl    = local.sets[key].ttl
      values = local.sets[key].values
    }
  ]
}

resource "hcloud_zone" "this" {
  count             = var.mode == "hetzner" ? 1 : 0
  name              = var.zone
  mode              = "primary"
  ttl               = var.ttl
  delete_protection = var.protection
  labels            = { "managed-by" = "hetzner-host-config" }
}

resource "hcloud_zone_rrset" "this" {
  for_each = var.mode == "hetzner" ? local.sets : {}

  zone = hcloud_zone.this[0].name
  name = each.value.name
  type = each.value.type
  ttl  = each.value.ttl
  records = [
    for v in each.value.values : {
      value = each.value.type == "TXT" && !startswith(v, "\"") ? provider::hcloud::txt_record(v) : v
    }
  ]
}

output "nameservers" {
  description = "Hetzner name servers to set at the registrar. Empty for external zones."
  value       = var.mode == "hetzner" ? hcloud_zone.this[0].authoritative_nameservers.assigned : []
}

output "records" {
  description = "All record sets of the zone. For external zones this is the list to set by hand."
  value       = local.listing
}

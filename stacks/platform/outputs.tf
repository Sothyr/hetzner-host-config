output "hosts" {
  description = "Addresses of the servers."
  value = {
    for name, h in module.host : name => {
      ipv4       = h.ipv4
      ipv6       = h.ipv6
      admin_user = h.admin_user
    }
  }
}

output "known_hosts" {
  description = "Paste into ~/.ssh/known_hosts. The host keys are pinned, no trust on first use."
  value       = join("\n", [for h in module.host : h.known_hosts])
}

output "host_names" {
  description = "Public host names per server."
  value       = local.host_names
}

output "nameservers" {
  description = "Set these name servers at the registrar (e.g. Checkdomain) for zones in mode hetzner."
  value       = { for zone, d in module.dns : zone => d.nameservers }
}

output "dns_records_external" {
  description = "Records to set by hand for zones in mode external."
  value       = { for zone, d in module.dns : zone => d.records if var.dns_zones[zone].mode == "external" }
}

output "keycloak" {
  description = "Admin access of the shared Keycloak per host. tofu output -json keycloak"
  value       = { for host, p in module.sothyr_platform : host => p.keycloak }
  sensitive   = true
}

output "wordpress_admin_passwords" {
  description = "Break glass passwords of WordPress per club."
  value       = { for key, s in module.sothyr_site : key => s.wordpress_admin_password }
  sensitive   = true
}

output "applied" {
  description = "Hash of the applied host bundle per server."
  value       = { for name, r in module.runtime : name => r.script_sha256 }
}

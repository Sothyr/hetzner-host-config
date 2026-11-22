output "id" {
  value = hcloud_server.this.id
}

output "name" {
  value = hcloud_server.this.name
}

output "ipv4" {
  value = hcloud_primary_ip.ipv4.ip_address
}

output "ipv6" {
  description = "First address of the IPv6 network, used for DNS."
  value       = hcloud_server.this.ipv6_address
}

output "host_public_key" {
  description = "Pinned SSH host key."
  value       = trimspace(tls_private_key.host.public_key_openssh)
}

output "known_hosts" {
  description = "Lines for ~/.ssh/known_hosts."
  value = join("\n", [
    "${hcloud_primary_ip.ipv4.ip_address} ${trimspace(tls_private_key.host.public_key_openssh)}",
    "${hcloud_server.this.ipv6_address} ${trimspace(tls_private_key.host.public_key_openssh)}",
  ])
}

output "admin_user" {
  value = var.admin_user
}

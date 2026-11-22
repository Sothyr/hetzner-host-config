locals {
  labels = merge(var.labels, { "managed-by" = "hetzner-host-config", "host" = var.name })
  ptr    = coalesce(var.reverse_dns, var.name)

  base_rules = [
    { description = "HTTP", protocol = "tcp", port = "80", source_ips = ["0.0.0.0/0", "::/0"] },
    { description = "HTTPS", protocol = "tcp", port = "443", source_ips = ["0.0.0.0/0", "::/0"] },
    { description = "SSH, certificate only", protocol = "tcp", port = "22", source_ips = var.ssh_source_ips },
    { description = "ICMP", protocol = "icmp", port = null, source_ips = ["0.0.0.0/0", "::/0"] },
  ]
  rules = concat(local.base_rules, var.firewall_rules)
}

# Host key made here, so OpenTofu can pin it in every SSH connection. No trust on first use.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

resource "hcloud_primary_ip" "ipv4" {
  name              = "${var.name}-ipv4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protection
  labels            = local.labels
}

resource "hcloud_primary_ip" "ipv6" {
  name              = "${var.name}-ipv6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protection
  labels            = local.labels
}

resource "hcloud_firewall" "this" {
  name   = var.name
  labels = local.labels

  dynamic "rule" {
    for_each = local.rules
    content {
      description = rule.value.description
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = rule.value.source_ips
    }
  }
}

resource "hcloud_server" "this" {
  name               = var.name
  server_type        = var.server_type
  location           = var.location
  image              = var.image
  backups            = var.backups
  delete_protection  = var.protection
  rebuild_protection = var.protection
  firewall_ids       = [hcloud_firewall.this.id]
  labels             = local.labels

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname         = var.name
    timezone         = var.timezone
    admin_user       = var.admin_user
    admin_principals = var.admin_principals
    user_ca_keys     = var.user_ca_public_keys
    host_private_key = tls_private_key.host.private_key_openssh
    host_public_key  = trimspace(tls_private_key.host.public_key_openssh)
    swap_size        = var.swap_size
    packages         = var.extra_packages
    podman_compose   = var.podman_compose
  })

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6.id
  }

  lifecycle {
    # cloud-init runs only once. Later changes go through the host-runtime module.
    ignore_changes = [user_data, image, ssh_keys]
  }
}

resource "hcloud_rdns" "ipv4" {
  primary_ip_id = hcloud_primary_ip.ipv4.id
  ip_address    = hcloud_primary_ip.ipv4.ip_address
  dns_ptr       = local.ptr
}

resource "hcloud_rdns" "ipv6" {
  primary_ip_id = hcloud_primary_ip.ipv6.id
  ip_address    = hcloud_server.this.ipv6_address
  dns_ptr       = local.ptr
}

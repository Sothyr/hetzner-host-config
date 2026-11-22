# Root of the platform: servers, their stacks, routes, users and DNS.
# Read top to bottom: inputs are mapped to presets, presets to stacks per host, stacks to the host-runtime module.

# --- Servers --------------------------------------------------------------------------------------------------------

locals {
  # Ports published by apps, as firewall rules per host. "9987/udp" -> udp 9987.
  app_ports = {
    for host in keys(var.hosts) : host => distinct(flatten([
      for app in values(var.apps) : app.ports if app.host == host
    ]))
  }
}

module "host" {
  source   = "../../modules/hcloud-host"
  for_each = var.hosts

  name                = each.key
  server_type         = each.value.server_type
  location            = each.value.location
  image               = each.value.image
  backups             = each.value.backups
  protection          = each.value.protection
  labels              = each.value.labels
  ssh_source_ips      = each.value.ssh_source_ips
  swap_size           = each.value.swap_size
  reverse_dns         = each.value.reverse_dns
  admin_user          = var.ssh.admin_user
  admin_principals    = var.ssh.admin_principals
  user_ca_public_keys = var.ssh.user_ca_public_keys

  firewall_rules = [
    for p in local.app_ports[each.key] : {
      description = "app port ${p}"
      protocol    = split("/", p)[1]
      port        = split("/", p)[0]
    }
  ]
}

# --- sothyr-pages ---------------------------------------------------------------------------------------------------

locals {
  # Secrets merged into the public objects. Missing entries keep the values of terraform.tfvars.
  git_of = { for host, p in var.sothyr : host => merge(p.git, contains(keys(var.secrets.deploy_keys), p.git.url) ? { deploy_key = var.secrets.deploy_keys[p.git.url] } : {}) }
}

module "sothyr_platform" {
  source   = "../../modules/sothyr-platform"
  for_each = var.sothyr

  edge_ports           = { http = var.hosts[each.key].haproxy.http_port, https = var.hosts[each.key].haproxy.https_port }
  git                  = local.git_of[each.key]
  auth_host            = each.value.auth_host
  stats_host           = each.value.stats_host
  tickets_host         = each.value.tickets_host
  platform_name        = each.value.platform_name
  keycloak_version     = each.value.keycloak_version
  mail                 = merge(each.value.mail, contains(keys(var.secrets.smtp_passwords), each.key) ? { password = var.secrets.smtp_passwords[each.key] } : {})
  umami_admin_password = lookup(var.secrets.umami_admin, each.key, null)
}

locals {
  sothyr_sites = merge([
    for host, p in var.sothyr : {
      for slug, site in p.sites : "${host}/${slug}" => merge(site, { host = host, slug = slug })
    }
  ]...)
}

module "sothyr_site" {
  source   = "../../modules/sothyr-site"
  for_each = local.sothyr_sites

  slug         = each.value.slug
  name         = each.value.name
  domain       = each.value.domain
  www          = each.value.www
  cms_host     = each.value.cms_host
  tickets      = each.value.tickets
  tickets_host = each.value.tickets_host
  instance_dir = each.value.instance_dir
  admin_email  = each.value.admin_email
  instance_git = each.value.instance_git == null ? null : merge(each.value.instance_git, contains(keys(var.secrets.deploy_keys), each.value.instance_git.url) ? { deploy_key = var.secrets.deploy_keys[each.value.instance_git.url] } : {})
  images       = each.value.images
  auto_update  = each.value.auto_update
  env          = merge(each.value.env, lookup(var.secrets.site_env, each.key, {}))
  git          = each.value.ref == null ? local.git_of[each.value.host] : merge(local.git_of[each.value.host], { ref = each.value.ref })

  platform = {
    stack_name       = module.sothyr_platform[each.value.host].stack_name
    env              = module.sothyr_platform[each.value.host].env
    caddyfile_patch  = module.sothyr_platform[each.value.host].caddyfile_patch
    platform_secrets = module.sothyr_platform[each.value.host].platform_secrets
  }
}

# --- Edge per host --------------------------------------------------------------------------------------------------

locals {
  app_routes = {
    for host in keys(var.hosts) : host => merge([
      for name, app in var.apps : { for r, route in app.routes : "${name}-${r}" => route } if app.host == host
    ]...)
  }

  # A host without sothyr platform but with routes gets its own small Caddy.
  standalone_edge_hosts = toset([for host in keys(var.hosts) : host if !contains(keys(var.sothyr), host) && length(local.app_routes[host]) > 0])
}

module "edge_caddy" {
  source   = "../../modules/edge-caddy"
  for_each = local.standalone_edge_hosts

  acme_email = coalesce(var.hosts[each.key].acme_email, "admin@${each.key}")
  edge_ports = { http = var.hosts[each.key].haproxy.http_port, https = var.hosts[each.key].haproxy.https_port }
}

locals {
  edge = {
    for host in keys(var.hosts) : host => (
      contains(keys(var.sothyr), host) ? module.sothyr_platform[host].edge :
      contains(local.standalone_edge_hosts, host) ? module.edge_caddy[host].edge : null
    )
  }

  edge_stack_name = {
    for host in keys(var.hosts) : host => (
      contains(keys(var.sothyr), host) ? module.sothyr_platform[host].stack_name :
      contains(local.standalone_edge_hosts, host) ? module.edge_caddy[host].stack_name : null
    )
  }
}

# --- Stacks per host ------------------------------------------------------------------------------------------------

locals {
  app_stacks = {
    for host in keys(var.hosts) : host => {
      for name, app in var.apps : name => {
        project       = coalesce(app.project, name)
        git           = app.git == null ? null : merge(app.git, contains(keys(var.secrets.deploy_keys), app.git.url) ? { deploy_key = var.secrets.deploy_keys[app.git.url] } : {})
        compose_files = app.compose_files
        files         = merge(app.files, { for path, content in lookup(var.secrets.app_files, name, {}) : path => { content = content, mode = "0644" } })
        env           = merge(app.env, lookup(var.secrets.app_env, name, {}))
        profiles      = app.profiles
        pull          = app.pull
        build         = app.build
        auto_update   = app.auto_update
        # Apps behind the edge start after it, so its network exists.
        after         = distinct(concat(app.after, length(app.routes) > 0 && local.edge_stack_name[host] != null ? [local.edge_stack_name[host]] : []))
        post_checkout = app.post_checkout
      } if app.host == host
    }
  }

  host_stacks = {
    for host in keys(var.hosts) : host => merge(
      contains(keys(var.sothyr), host) ? { (module.sothyr_platform[host].stack_name) = module.sothyr_platform[host].stack } : {},
      { for key, site in module.sothyr_site : site.stack_name => site.stack if local.sothyr_sites[key].host == host },
      contains(local.standalone_edge_hosts, host) ? { (module.edge_caddy[host].stack_name) = module.edge_caddy[host].stack } : {},
      local.app_stacks[host],
    )
  }

  host_users = {
    for host in keys(var.hosts) : host => {
      for name, u in var.users : name => { principals = u.principals, sudo = u.sudo } if u.hosts == null || contains(coalesce(u.hosts, []), host)
    }
  }
}

module "runtime" {
  source   = "../../modules/host-runtime"
  for_each = var.hosts

  connection = {
    host        = module.host[each.key].ipv4
    user        = module.host[each.key].admin_user
    host_key    = module.host[each.key].host_public_key
    private_key = file(pathexpand(var.ssh.private_key_path))
    certificate = file(pathexpand(var.ssh.certificate_path))
  }

  user_ca_public_keys = var.ssh.user_ca_public_keys
  users               = local.host_users[each.key]
  firewalld_ports     = local.app_ports[each.key]
  registries          = var.registries
  networks            = contains(local.standalone_edge_hosts, each.key) ? { (module.edge_caddy[each.key].edge.network) = {} } : {}
  stacks              = local.host_stacks[each.key]
  routes              = local.app_routes[each.key]
  haproxy             = each.value.haproxy
  edge                = local.edge[each.key] == null ? null : { volume = try(local.edge[each.key].volume, null), dir = try(local.edge[each.key].dir, null), container = local.edge[each.key].container, caddyfile = local.edge[each.key].caddyfile }
  auto_update_time    = each.value.auto_update_time
  offsite_secrets     = lookup(var.secrets.offsite, each.key, null)
  backup = merge(each.value.backup, {
    jobs = contains(keys(var.sothyr), each.key) ? module.sothyr_platform[each.key].backup_jobs : {}
  })
}

# --- DNS ----------------------------------------------------------------------------------------------------------

locals {
  host_names = {
    for host in keys(var.hosts) : host => distinct(concat(
      contains(keys(var.sothyr), host) ? module.sothyr_platform[host].hostnames : [],
      flatten([for key, site in module.sothyr_site : site.hostnames if local.sothyr_sites[key].host == host]),
      flatten([for r in values(local.app_routes[host]) : r.domains]),
    ))
  }

  # Every host name to the longest zone that contains it.
  name_zone = merge([
    for host, names in local.host_names : {
      for n in names : n => {
        host = host
        zone = try(reverse(sort([for z in keys(var.dns_zones) : format("%04d%s", length(z), z) if n == z || endswith(n, ".${z}")]))[0], null)
      }
    }
  ]...)

  auto_records = {
    for zone in keys(var.dns_zones) : zone => flatten([
      for n, m in local.name_zone : [
        { name = n == zone ? "@" : trimsuffix(n, ".${zone}"), type = "A", values = [module.host[m.host].ipv4], ttl = null },
        { name = n == zone ? "@" : trimsuffix(n, ".${zone}"), type = "AAAA", values = [module.host[m.host].ipv6], ttl = null },
      ] if m.zone != null && substr(m.zone, 4, -1) == zone
    ])
  }
}

module "dns" {
  source   = "../../modules/dns-zone"
  for_each = var.dns_zones

  zone    = each.key
  mode    = each.value.mode
  records = concat(local.auto_records[each.key], each.value.records)
}

check "host_names_without_zone" {
  assert {
    condition     = length([for n, m in local.name_zone : n if m.zone == null]) == 0
    error_message = "These host names have no zone in dns_zones, set their records by hand: ${join(", ", [for n, m in local.name_zone : n if m.zone == null])}"
  }
}

check "references" {
  assert {
    condition = alltrue(concat(
      [for host in keys(var.sothyr) : contains(keys(var.hosts), host)],
      [for app in values(var.apps) : contains(keys(var.hosts), app.host)],
      [for u in values(var.users) : alltrue([for h in coalesce(u.hosts, []) : contains(keys(var.hosts), h)])],
    ))
    error_message = "sothyr, apps and users may only name hosts that exist in hosts."
  }
}

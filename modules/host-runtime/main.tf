locals {
  stack_workdirs = { for name, s in var.stacks : name => s.git != null ? "/srv/stacks/${name}/src" : "/srv/stacks/${name}/files" }

  stack_conf = {
    for name, s in var.stacks : name => join("\n", [
      "PROJECT='${s.project}'",
      "WORKDIR='${local.stack_workdirs[name]}'",
      "COMPOSE_FILES=(${join(" ", [for f in s.compose_files : "'${f}'"])})",
      "PROFILES=(${join(" ", [for p in s.profiles : "'${p}'"])})",
      "PULL=(${join(" ", [for i in s.pull : "'${i}'"])})",
      "BUILD=${s.build ? 1 : 0}",
      "AUTO_UPDATE=${s.auto_update ? 1 : 0}",
      "JOB_PROJECT='${try(s.jobs.project, "")}'",
      "JOB_FILES=(${join(" ", [for f in try(s.jobs.compose_files, []) : "'${f}'"])})",
      "JOB_PROFILES=(${join(" ", [for p in try(s.jobs.profiles, []) : "'${p}'"])})",
      "JOB_SERVICES=(${join(" ", [for j in try(s.jobs.services, []) : "'${j}'"])})",
      "",
    ])
  }

  stack_env = {
    for name, s in var.stacks : name => join("", [for k in sort(keys(s.env)) : "${k}='${s.env[k]}'\n"])
  }

  stack_jobs_env = {
    for name, s in var.stacks : name => s.jobs == null ? "" : join("", [for k in sort(keys(s.jobs.env)) : "${k}='${s.jobs.env[k]}'\n"])
  }

  stack_dropin = {
    for name, s in var.stacks : name => join("\n", concat(
      ["[Unit]"],
      [for a in s.after : "Requires=hhc-stack@${a}.service"],
      [for a in s.after : "After=hhc-stack@${a}.service"],
      [""],
    ))
  }

  stacks_rendered = {
    for name, s in var.stacks : name => {
      conf       = base64encode(local.stack_conf[name])
      env        = base64encode(local.stack_env[name])
      dropin     = base64encode(local.stack_dropin[name])
      deploy_key = s.git != null && try(s.git.deploy_key, null) != null ? base64encode("${trimspace(s.git.deploy_key)}\n") : ""
      git        = s.git
      workdir    = local.stack_workdirs[name]
      files      = { for path, f in s.files : path => { mode = f.mode, content = base64encode(f.content) } }
      post       = s.git != null && try(s.post_checkout, null) != null ? base64encode(s.post_checkout) : ""
      jobs_env   = base64encode(local.stack_jobs_env[name])
      checkouts = {
        for path, c in s.checkouts : path => {
          url = c.url
          ref = c.ref
          key = try(c.deploy_key, null) == null ? "" : base64encode("${trimspace(c.deploy_key)}\n")
          id  = substr(sha256(path), 0, 12)
        }
      }
    }
  }

  routes_rendered = {
    for name, r in var.routes : name => base64encode(templatefile("${path.module}/templates/route.caddy.tftpl", {
      name      = name
      domains   = r.domains
      upstream  = r.upstream
      encode    = r.encode
      max_body  = r.max_body
      allow_ips = r.allow_ips
      extra     = r.extra
    }))
  }

  user_lines = join("\n", [for name in sort(keys(var.users)) : "${name} ${var.users[name].sudo} ${join(",", var.users[name].principals)}"])

  registry_auth = jsonencode({
    auths = { for host, r in var.registries : host => { auth = base64encode("${r.username}:${r.password}") } }
  })

  offsite_on = var.backup.offsite.enabled && var.offsite_secrets != null
  offsite = local.offsite_on ? {
    on_calendar = var.backup.offsite.on_calendar
    script      = filebase64("${path.module}/files/offsite.sh")
    env = base64encode(join("\n", [
      "RESTIC_REPOSITORY=${var.backup.offsite.repository}",
      "RESTIC_PASSWORD=${var.offsite_secrets.password}",
      "AWS_ACCESS_KEY_ID=${var.offsite_secrets.access_key}",
      "AWS_SECRET_ACCESS_KEY=${var.offsite_secrets.secret_key}",
      "AWS_DEFAULT_REGION=${var.backup.offsite.region}",
      "OFFSITE_IMAGE=${var.backup.offsite.image}",
      "KEEP_DAILY=${var.backup.offsite.keep_daily}",
      "KEEP_WEEKLY=${var.backup.offsite.keep_weekly}",
      "KEEP_MONTHLY=${var.backup.offsite.keep_monthly}",
      "",
    ]))
    paths = base64encode("${join("\n", var.backup.offsite.paths)}\n")
  } : null

  script = templatefile("${path.module}/templates/apply.sh.tftpl", {
    lib             = file("${path.module}/files/lib.sh")
    admin_user      = var.connection.user
    ca_keys         = base64encode("${join("\n", [for k in var.user_ca_public_keys : trimspace(k)])}\n")
    users           = base64encode(local.user_lines)
    stack_sh        = filebase64("${path.module}/files/stack.sh")
    stack_unit      = filebase64("${path.module}/files/hhc-stack@.service")
    update_unit     = filebase64("${path.module}/files/hhc-stack-update.service")
    update_timer    = base64encode(templatefile("${path.module}/templates/hhc-stack-update.timer.tftpl", { on_calendar = var.auto_update_time }))
    registry_auth   = base64encode(local.registry_auth)
    firewalld_ports = join(" ", var.firewalld_ports)
    networks        = { for name, n in var.networks : name => n.internal }
    stacks          = local.stacks_rendered
    stack_names     = base64encode(join("\n", sort(keys(var.stacks))))
    edge            = var.edge == null ? null : { volume = var.edge.volume == null ? "" : var.edge.volume, dir = var.edge.dir == null ? "" : var.edge.dir, container = var.edge.container, caddyfile = var.edge.caddyfile }
    routes          = local.routes_rendered
    haproxy         = var.edge != null ? base64encode(templatefile("${path.module}/templates/haproxy.cfg.tftpl", var.haproxy)) : ""
    backup_sh       = filebase64("${path.module}/files/backup.sh")
    backup          = var.backup
    backup_jobs     = { for name, cmd in var.backup.jobs : name => base64encode("${cmd}\n") }
    offsite         = local.offsite
    backup_paths    = base64encode(join("\n", [for name in sort(keys(var.backup.jobs)) : "/etc/hhc/backup-jobs/${name}.sh"]))
    route_paths     = base64encode(join("\n", [for name in sort(keys(var.routes)) : "hhc-${name}.caddy"]))
  })

  remote_script = "/home/${var.connection.user}/.hhc-apply.sh"
}

resource "terraform_data" "apply" {
  triggers_replace = [sha256(local.script)]

  lifecycle {
    precondition {
      condition = alltrue(flatten([
        for s in var.stacks : [for v in concat(values(s.env), values(try(s.jobs.env, {}))) : !strcontains(v, "'") && !strcontains(v, "\n")]
      ]))
      error_message = "Stack env values must not contain single quotes or line breaks."
    }
    precondition {
      condition     = alltrue(flatten([for s in var.stacks : [for p in concat(keys(s.files), keys(s.checkouts)) : !startswith(p, "/") && !strcontains(p, "..")]]))
      error_message = "Stack file paths must be relative and must not contain '..'."
    }
    precondition {
      condition     = !var.backup.offsite.enabled || (var.offsite_secrets != null && startswith(var.backup.offsite.repository, "s3:"))
      error_message = "backup.offsite.enabled needs offsite_secrets and a repository that starts with s3:."
    }
    precondition {
      condition = var.offsite_secrets == null || alltrue([
        for v in [var.offsite_secrets.access_key, var.offsite_secrets.secret_key, var.offsite_secrets.password] : can(regex("^[A-Za-z0-9._/+=-]+$", v))
      ])
      error_message = "offsite_secrets may only contain letters, digits and . _ / + = - (the values go into an env file)."
    }
    precondition {
      condition     = var.edge == null || (try(var.edge.volume, null) != null) != (try(var.edge.dir, null) != null)
      error_message = "edge needs exactly one of volume or dir."
    }
  }

  connection {
    type        = "ssh"
    host        = var.connection.host
    user        = var.connection.user
    host_key    = var.connection.host_key
    private_key = var.connection.private_key
    certificate = var.connection.certificate
    agent       = false
    timeout     = "10m"
  }

  provisioner "file" {
    content     = local.script
    destination = local.remote_script
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 700 ${local.remote_script}",
      "sudo bash ${local.remote_script}; rc=$?; rm -f ${local.remote_script}; exit $rc",
    ]
  }
}

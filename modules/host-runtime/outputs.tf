output "script_sha256" {
  description = "Hash of the applied bundle. Changes whenever the host config changes."
  value       = nonsensitive(sha256(local.script))
}

output "stack_names" {
  value = nonsensitive(sort(keys(var.stacks)))
}

output "route_domains" {
  value = flatten([for r in var.routes : r.domains])
}

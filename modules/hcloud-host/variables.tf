variable "name" {
  description = "Server name. Also the host name of the VM."
  type        = string
}

variable "server_type" {
  description = "Hetzner server type, e.g. cpx22. Changing it resizes the server in place."
  type        = string
}

variable "location" {
  description = "Hetzner location, e.g. nbg1, fsn1, hel1."
  type        = string
}

variable "image" {
  description = "OS image. The bootstrap is written for EL10 (Rocky Linux 10)."
  type        = string
  default     = "rocky-10"
}

variable "backups" {
  description = "Hetzner daily backups of the whole VM."
  type        = bool
  default     = true
}

variable "protection" {
  description = "Delete and rebuild protection for server and primary IPs."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels for all resources of this host."
  type        = map(string)
  default     = {}
}

variable "admin_user" {
  description = "Bootstrap user. Created by cloud-init, used by OpenTofu for all later changes."
  type        = string
  default     = "hhc"
}

variable "admin_principals" {
  description = "Certificate principals that may log in as admin_user."
  type        = list(string)
}

variable "user_ca_public_keys" {
  description = "Public keys of the SSH user CAs. Several keys allow a CA rotation."
  type        = list(string)

  validation {
    condition     = length(var.user_ca_public_keys) > 0
    error_message = "At least one SSH user CA key is required."
  }
}

variable "ssh_source_ips" {
  description = "CIDRs that may reach port 22. Login needs a certificate anyway."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "firewall_rules" {
  description = "Extra inbound rules, e.g. TeamSpeak. Ports 80, 443 and 22 are always set."
  type = list(object({
    description = string
    protocol    = string
    port        = optional(string)
    source_ips  = optional(list(string), ["0.0.0.0/0", "::/0"])
  }))
  default = []
}

variable "reverse_dns" {
  description = "PTR name for the public IPs. Null uses the server name."
  type        = string
  default     = null
}

variable "swap_size" {
  description = "Size of the swap file, e.g. 2G. Empty disables swap."
  type        = string
  default     = "2G"
}

variable "timezone" {
  type    = string
  default = "Europe/Berlin"
}

variable "extra_packages" {
  description = "Additional dnf packages."
  type        = list(string)
  default     = []
}

variable "podman_compose" {
  description = "pip requirement of podman-compose."
  type        = string
  default     = "podman-compose>=1.6"
}

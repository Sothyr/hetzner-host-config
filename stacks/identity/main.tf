# Keycloak realms of apps that are not sothyr-pages clubs. Club realms belong to the register job of sothyr-pages.
# Needs a running Keycloak. Admin password from the platform stack:
#   tofu -chdir=stacks/platform output -json keycloak
terraform {
  required_version = ">= 1.10"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.10"
    }
  }

  backend "s3" {}

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

variable "state_passphrase" {
  type      = string
  sensitive = true
}

variable "keycloak" {
  description = "Admin login of the shared Keycloak (master realm, admin-cli)."
  type = object({
    url            = string
    admin_user     = string
    admin_password = string
  })
  sensitive = true
}

variable "realms" {
  description = "Realms by name. See modules/keycloak-realm for the client fields."
  type = map(object({
    display_name = optional(string)
    login_theme  = optional(string)
    frontend_url = optional(string)
    locales      = optional(list(string), ["de", "en"])
    roles        = optional(map(string), {})
    clients = optional(map(object({
      name                 = optional(string)
      access_type          = optional(string, "CONFIDENTIAL")
      root_url             = optional(string)
      redirect_uris        = list(string)
      post_logout_uris     = optional(list(string), ["+"])
      web_origins          = optional(list(string), ["+"])
      service_accounts     = optional(bool, false)
      direct_access_grants = optional(bool, false)
      pkce                 = optional(bool, true)
    })), {})
  }))
  default = {}
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak.admin_user
  password  = var.keycloak.admin_password
  url       = var.keycloak.url
}

module "realm" {
  source   = "../../modules/keycloak-realm"
  for_each = var.realms

  realm        = each.key
  display_name = each.value.display_name
  login_theme  = each.value.login_theme
  frontend_url = each.value.frontend_url
  locales      = each.value.locales
  roles        = each.value.roles
  clients      = each.value.clients
}

output "client_secrets" {
  description = "Client secrets per realm and client. Hand them to the apps, e.g. through secrets.app_env."
  value       = { for realm, m in module.realm : realm => m.client_secrets }
  sensitive   = true
}

# One Keycloak realm with roles and OIDC clients, for apps that are not sothyr-pages clubs.
# Club realms are created by the register job of sothyr-pages. Do not manage them here.
terraform {
  required_version = ">= 1.10"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.10"
    }
  }
}

variable "realm" {
  type = string
}

variable "display_name" {
  type    = string
  default = null
}

variable "login_theme" {
  type    = string
  default = null
}

variable "frontend_url" {
  description = "Public URL of this realm, e.g. https://auth.example.org. Sets the realm attribute frontendUrl."
  type        = string
  default     = null
}

variable "locales" {
  type    = list(string)
  default = ["de", "en"]
}

variable "roles" {
  description = "Realm roles."
  type        = map(string)
  default     = {}
}

variable "clients" {
  description = "OIDC clients by client id."
  type = map(object({
    name                 = optional(string)
    access_type          = optional(string, "CONFIDENTIAL")
    root_url             = optional(string)
    redirect_uris        = list(string)
    post_logout_uris     = optional(list(string), ["+"])
    web_origins          = optional(list(string), ["+"])
    service_accounts     = optional(bool, false)
    direct_access_grants = optional(bool, false)
    pkce                 = optional(bool, true)
  }))
  default = {}
}

resource "keycloak_realm" "this" {
  realm                    = var.realm
  display_name             = var.display_name
  login_theme              = var.login_theme
  ssl_required             = "external"
  login_with_email_allowed = true
  duplicate_emails_allowed = false
  reset_password_allowed   = true
  remember_me              = true
  attributes               = var.frontend_url == null ? {} : { frontendUrl = var.frontend_url }

  internationalization {
    supported_locales = var.locales
    default_locale    = var.locales[0]
  }

  security_defenses {
    brute_force_detection {}
  }
}

resource "keycloak_role" "this" {
  for_each    = var.roles
  realm_id    = keycloak_realm.this.id
  name        = each.key
  description = each.value
}

resource "keycloak_openid_client" "this" {
  for_each = var.clients

  realm_id                        = keycloak_realm.this.id
  client_id                       = each.key
  name                            = coalesce(each.value.name, each.key)
  access_type                     = each.value.access_type
  root_url                        = each.value.root_url
  base_url                        = each.value.root_url
  standard_flow_enabled           = true
  direct_access_grants_enabled    = each.value.direct_access_grants
  service_accounts_enabled        = each.value.service_accounts
  valid_redirect_uris             = each.value.redirect_uris
  valid_post_logout_redirect_uris = each.value.post_logout_uris
  web_origins                     = each.value.web_origins
  pkce_code_challenge_method      = each.value.pkce ? "S256" : ""
}

output "realm_id" {
  value = keycloak_realm.this.id
}

output "client_secrets" {
  value     = { for id, c in keycloak_openid_client.this : id => c.client_secret }
  sensitive = true
}

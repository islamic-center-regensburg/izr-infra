terraform {
  required_version = ">= 1.11.0"
  backend "local" {}
  required_providers {
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20.18"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
variable "infisical_url" {
  type = string
}
variable "infisical_token" {
  type      = string
  sensitive = true
}
variable "infisical_project_id" {
  type = string
}
variable "environment" {
  type = string
}
variable "project" {
  type = string
}
variable "cms_admin_email" {
  type = string
}
variable "cms_oidc_client_id" {
  type = string
  validation {
    condition     = trimspace(var.cms_oidc_client_id) != "" && !startswith(var.cms_oidc_client_id, "REPLACE_")
    error_message = "Create the CMS client in Pocket ID, then supply its actual client ID."
  }
}
variable "cms_oidc_client_secret" {
  type      = string
  sensitive = true
  validation {
    condition     = trimspace(var.cms_oidc_client_secret) != "" && !startswith(var.cms_oidc_client_secret, "REPLACE_")
    error_message = "Supply the actual CMS OIDC client secret from Pocket ID."
  }
}
variable "credential_version" {
  description = "Increase to regenerate every generated credential in this layer. Edits made in Infisical are otherwise kept."
  type        = number
  default     = 1
}
provider "infisical" {
  host = var.infisical_url
  auth = { token = var.infisical_token }
}

locals {
  generated = {
    "cms/DB_PASSWORD"    = "cms"
    "cms/KEY"            = "cms"
    "cms/SECRET"         = "cms"
    "cms/ADMIN_PASSWORD" = "cms"
    # Static tokens of the CMS service users (izr-cms access/*.yaml). The CMS applies
    # them at startup; the website, screen and MCP clients receive the same values.
    "cms/SCREEN_TOKEN"  = "cms"
    "cms/WEBSITE_TOKEN" = "cms"
    "cms/MCP_TOKEN"     = "cms"
  }
  configured = {
    "cms/ADMIN_EMAIL"                 = var.cms_admin_email
    "cms/AUTH_POCKETID_CLIENT_ID"     = var.cms_oidc_client_id
    "cms/AUTH_POCKETID_CLIENT_SECRET" = var.cms_oidc_client_secret
  }
}

resource "infisical_secret_folder" "project" {
  project_id       = var.infisical_project_id
  environment_slug = var.environment
  folder_path      = "/"
  name             = var.project
}
# Only the runner token is added manually in Infisical; the CMS service-user tokens
# are generated in the cms folder. The website and screen folders stay for app-specific values.
resource "infisical_secret_folder" "component" {
  for_each         = toset(["cms", "runner", "website", "screen"])
  project_id       = var.infisical_project_id
  environment_slug = var.environment
  folder_path      = infisical_secret_folder.project.path
  name             = each.key
}

ephemeral "random_password" "generated" {
  for_each = local.generated
  length   = 48
  special  = false
}
resource "infisical_secret" "generated" {
  for_each         = local.generated
  workspace_id     = var.infisical_project_id
  env_slug         = var.environment
  folder_path      = infisical_secret_folder.component[each.value].path
  name             = basename(each.key)
  value_wo         = ephemeral.random_password.generated[each.key].result
  value_wo_version = var.credential_version
}
resource "infisical_secret" "configured" {
  for_each     = toset(["cms/ADMIN_EMAIL", "cms/AUTH_POCKETID_CLIENT_ID", "cms/AUTH_POCKETID_CLIENT_SECRET"])
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = infisical_secret_folder.component[dirname(each.key)].path
  name         = basename(each.key)
  value        = local.configured[each.key]
}

output "folders" {
  value = { for name, folder in infisical_secret_folder.component : name => folder.path }
}

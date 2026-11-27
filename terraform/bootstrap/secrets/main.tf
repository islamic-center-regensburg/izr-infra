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
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Use dev or prod; environments have separate states."
  }
}
variable "oidc_admin_email" {
  type = string
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
    "postgres/POSTGRES_PASSWORD" = "postgres"
    "oidc/DB_PASSWORD"           = "oidc"
    "oidc/ENCRYPTION_KEY"        = "oidc"
  }
}

resource "infisical_secret_folder" "platform" {
  project_id       = var.infisical_project_id
  environment_slug = var.environment
  folder_path      = "/"
  name             = "platform"
}
resource "infisical_secret_folder" "component" {
  for_each         = toset(["postgres", "oidc"])
  project_id       = var.infisical_project_id
  environment_slug = var.environment
  folder_path      = infisical_secret_folder.platform.path
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
resource "infisical_secret" "oidc_admin_email" {
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = infisical_secret_folder.component["oidc"].path
  name         = "INITIAL_ADMIN_EMAIL"
  value        = var.oidc_admin_email
}

output "folders" {
  value = { for name, folder in infisical_secret_folder.component : name => folder.path }
}

terraform {
  required_version = ">= 1.11.0"
  backend "local" {}
  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.11.2"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20.18"
    }
  }
}
variable "dokploy_endpoint" {
  type = string
}
variable "dokploy_api_key" {
  type      = string
  sensitive = true
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
variable "environment_id" {
  type = string
}
variable "postgres_host" {
  type = string
}
provider "infisical" {
  host = var.infisical_url
  auth = { token = var.infisical_token }
}
provider "dokploy" {
  endpoint = var.dokploy_endpoint
  api_key  = var.dokploy_api_key
}
data "infisical_secrets" "postgres" {
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = "/platform/postgres"
}
data "infisical_secrets" "cms" {
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = "/${var.project}/cms"
}
module "cms" {
  source         = "../../../modules/database"
  name           = "izr-${var.project}-${var.environment}-cms-database"
  environment_id = var.environment_id
  postgres_host  = var.postgres_host
  database       = "${replace(var.project, "-", "_")}_cms"
  user           = "${replace(var.project, "-", "_")}_cms"
  admin_password = data.infisical_secrets.postgres.secrets["POSTGRES_PASSWORD"].value
  password       = data.infisical_secrets.cms.secrets["DB_PASSWORD"].value
}
output "deployments" {
  value = [module.cms.deployment]
}
output "containers" {
  value = [module.cms.container]
}

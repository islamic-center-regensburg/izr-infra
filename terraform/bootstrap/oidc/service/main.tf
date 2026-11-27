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
variable "environment_id" {
  type = string
}
variable "postgres_host" {
  type = string
}
variable "oidc_domain" {
  type = string
}
variable "oidc_image" {
  type    = string
  default = "ghcr.io/pocket-id/pocket-id:latest"
}
provider "infisical" {
  host = var.infisical_url
  auth = { token = var.infisical_token }
}
provider "dokploy" {
  endpoint = var.dokploy_endpoint
  api_key  = var.dokploy_api_key
}
data "infisical_secrets" "oidc" {
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = "/platform/oidc"
}
locals {
  oidc = data.infisical_secrets.oidc.secrets
}
resource "dokploy_application" "oidc" {
  name             = "izr-oidc-${var.environment}"
  app_name_prefix  = "izr-oidc-${var.environment}"
  environment_id   = var.environment_id
  docker           = { image = var.oidc_image }
  deploy_on_change = false
  env              = <<-EOT
    TRUST_PROXY=true
    DB_PROVIDER=postgres
    DB_CONNECTION_STRING=postgres://pocket_id:${urlencode(local.oidc["DB_PASSWORD"].value)}@${var.postgres_host}:5432/pocket_id
    ENCRYPTION_KEY=${local.oidc["ENCRYPTION_KEY"].value}
    INITIAL_ADMIN_EMAIL=${local.oidc["INITIAL_ADMIN_EMAIL"].value}
    APP_URL=https://${var.oidc_domain}
    LOG_LEVEL=info
  EOT
}
resource "dokploy_mount" "oidc_data" {
  service_id   = dokploy_application.oidc.id
  service_type = "application"
  type         = "volume"
  volume_name  = "izr-oidc-${var.environment}-data"
  mount_path   = "/app/data"
}
resource "dokploy_domain" "oidc" {
  application_id   = dokploy_application.oidc.id
  host             = var.oidc_domain
  port             = 1411
  https            = true
  certificate_type = "letsencrypt"
}
output "url" {
  value = "https://${var.oidc_domain}"
}
output "deployments" {
  value = [{ kind = "application", id = dokploy_application.oidc.id }]
}
output "checks" {
  value = [{ url = "https://${var.oidc_domain}/.well-known/openid-configuration", discovery = true, issuer = "https://${var.oidc_domain}" }]
}

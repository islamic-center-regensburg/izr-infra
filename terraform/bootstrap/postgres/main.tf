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
resource "dokploy_compose" "postgres" {
  name             = "izr-postgres-${var.environment}"
  environment_id   = var.environment_id
  deploy_on_change = false
  delete_volumes   = false
  create_env_file  = true
  env              = "POSTGRES_PASSWORD=${data.infisical_secrets.postgres.secrets["POSTGRES_PASSWORD"].value}"
  raw = {
    compose_file = <<-YAML
      services:
        izr-postgres-${var.environment}:
          image: postgres:16-alpine
          environment:
            POSTGRES_USER: postgres
            POSTGRES_DB: postgres
            POSTGRES_PASSWORD: $${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
          volumes:
            - data:/var/lib/postgresql/data
          networks: [dokploy-network]
          healthcheck:
            test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "postgres"]
            interval: 5s
            timeout: 5s
            retries: 24
          restart: always
      volumes:
        data:
          name: izr-postgres-${var.environment}-data
      networks:
        dokploy-network:
          external: true
    YAML
  }
}
output "host" {
  value = "izr-postgres-${var.environment}"
}
output "deployments" {
  value = [{ kind = "compose", id = dokploy_compose.postgres.id }]
}
output "containers" {
  value = [{ project = dokploy_compose.postgres.app_name, service = "izr-postgres-${var.environment}", mode = "healthy" }]
}

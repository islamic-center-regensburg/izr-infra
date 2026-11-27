terraform {
  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.11.2"
    }
  }
}
variable "name" {
  type = string
}
variable "environment_id" {
  type = string
}
variable "postgres_host" {
  type = string
}
variable "database" {
  type = string
}
variable "user" {
  type = string
}
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "password" {
  type      = string
  sensitive = true
}

resource "dokploy_compose" "provision" {
  name             = var.name
  environment_id   = var.environment_id
  deploy_on_change = false
  create_env_file  = true
  env              = <<-EOT
    PGPASSWORD=${var.admin_password}
    DB_PASSWORD=${var.password}
  EOT
  raw = {
    compose_file = yamlencode({
      services = {
        provision = {
          image   = "postgres:16-alpine"
          command = ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-f", "/provision.sql"]
          environment = {
            PGHOST      = var.postgres_host
            PGPORT      = "5432"
            PGUSER      = "postgres"
            PGDATABASE  = "postgres"
            PGPASSWORD  = "$${PGPASSWORD:?PGPASSWORD is required}"
            DB_PASSWORD = "$${DB_PASSWORD:?DB_PASSWORD is required}"
            DB_NAME     = var.database
            DB_USER     = var.user
          }
          configs  = [{ source = "provision", target = "/provision.sql" }]
          networks = ["dokploy-network"]
          restart  = "no"
        }
      }
      configs  = { provision = { content = file("${path.module}/provision.sql") } }
      networks = { dokploy-network = { external = true } }
    })
  }
}
output "deployment" {
  value = { kind = "compose", id = dokploy_compose.provision.id }
}
output "container" {
  value = { project = dokploy_compose.provision.app_name, service = "provision", mode = "completed" }
}

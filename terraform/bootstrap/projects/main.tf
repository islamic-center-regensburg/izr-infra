terraform {
  required_version = ">= 1.11.0"
  backend "local" {}
  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.11.2"
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

variable "consumer_projects" {
  type    = set(string)
  default = ["mosque"]
  validation {
    condition = alltrue([
      for name in var.consumer_projects :
      can(regex("^[a-z][a-z0-9-]*$", name)) && length(name) <= 32 && !contains(["secrets", "oidc", "postgres"], name)
    ])
    error_message = "Consumer names must be lowercase slugs, excluding secrets, oidc and postgres."
  }
}

provider "dokploy" {
  endpoint = var.dokploy_endpoint
  api_key  = var.dokploy_api_key
}

resource "dokploy_project" "project" {
  for_each    = setunion(toset(["secrets", "oidc", "postgres"]), var.consumer_projects)
  name        = "izr-${each.key}"
  description = "IZR ${each.key}, managed by the platform topology"
}

resource "dokploy_environment" "dev" {
  for_each    = dokploy_project.project
  project_id  = each.value.id
  name        = "dev"
  description = "Development"
}

output "projects" {
  value = {
    for name, project in dokploy_project.project : name => {
      id = project.id
      environments = {
        dev  = dokploy_environment.dev[name].id
        prod = project.production_environment_id
      }
    }
  }
}

terraform {
  required_version = ">= 1.11.0"
  backend "local" {}
  required_providers {
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20.18"
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

provider "infisical" {
  host = var.infisical_url
  auth = { token = var.infisical_token }
}

resource "infisical_project" "izr" {
  name                       = "IZR"
  slug                       = "izr-platform"
  description                = "Platform and consumer secrets; one folder per component"
  should_create_default_envs = false
  has_delete_protection      = true
}

resource "infisical_project_environment" "environment" {
  for_each   = { dev = "Development", prod = "Production" }
  project_id = infisical_project.izr.id
  slug       = each.key
  name       = each.value
}

output "project_id" {
  value = infisical_project.izr.id
}

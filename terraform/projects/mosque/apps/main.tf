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
provider "infisical" {
  host = var.infisical_url
  auth = { token = var.infisical_token }
}
provider "dokploy" {
  endpoint = var.dokploy_endpoint
  api_key  = var.dokploy_api_key
}
locals {
  prefix = "izr-${var.project}-${var.environment}"
  cms    = data.infisical_secrets.component["cms"].secrets
  # Which CMS service-user token each app uses (generated in the secrets layer).
  web_token_name = {
    website = "WEBSITE_TOKEN"
    screen  = "SCREEN_TOKEN"
  }
  database_name = "${replace(var.project, "-", "_")}_cms"
  git_branch    = var.environment == "dev" ? "dev" : "main"
  webapps = {
    website = var.website_repository_url
    screen  = var.screen_repository_url
  }
}
data "dokploy_github_provider" "apps" {
  name = var.github_app_name
}
data "infisical_secrets" "component" {
  for_each     = toset(["cms", "runner", "website", "screen"])
  workspace_id = var.infisical_project_id
  env_slug     = var.environment
  folder_path  = "/${var.project}/${each.key}"
}
resource "dokploy_application" "web" {
  for_each        = local.webapps
  name            = "${local.prefix}-${each.key}"
  app_name_prefix = "${local.prefix}-${each.key}"
  environment_id  = var.environment_id
  github = {
    owner        = split("/", trimsuffix(trimsuffix(each.value, "/"), ".git"))[3]
    repository   = split("/", trimsuffix(trimsuffix(each.value, "/"), ".git"))[4]
    branch       = local.git_branch
    github_id    = data.dokploy_github_provider.apps.id
    trigger_type = "push"
  }
  build            = { type = "dockerfile", dockerfile = "Dockerfile", context_path = "." }
  env              = <<-EOT
    NODE_ENV=production
    PORT=3000
    DIRECTUS_API_URL=http://${dokploy_application.cms.app_name}:8055
    DIRECTUS_READ_TOKEN=${local.cms[local.web_token_name[each.key]].value}
  EOT
  auto_deploy      = var.auto_deploy
  deploy_on_change = false
  lifecycle {
    precondition {
      condition     = try(trimspace(local.cms[local.web_token_name[each.key]].value) != "", false)
      error_message = "The ${local.web_token_name[each.key]} secret is missing in /${var.project}/cms; apply the secrets layer first (make project-secrets)."
    }
  }
}
resource "dokploy_domain" "web" {
  for_each         = local.webapps
  application_id   = dokploy_application.web[each.key].id
  host             = var.domains[each.key]
  port             = 3000
  https            = true
  certificate_type = "letsencrypt"
}

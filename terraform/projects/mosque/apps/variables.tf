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
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Use dev or prod; ENV=all is expanded by Make."
  }
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
variable "oidc_url" {
  type = string
}
variable "domains" {
  type = object({
    website = string
    screen  = string
    cms     = string
  })
}
variable "website_repository_url" {
  type = string
  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+/?$", var.website_repository_url))
    error_message = "Use an HTTPS github.com owner/repository URL."
  }
}
variable "screen_repository_url" {
  type = string
  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+/?$", var.screen_repository_url))
    error_message = "Use an HTTPS github.com owner/repository URL."
  }
}
variable "cms_repository_url" {
  type = string
  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+/?$", var.cms_repository_url))
    error_message = "Use an HTTPS github.com owner/repository URL."
  }
}
variable "github_app_name" {
  description = "Name of the installed Dokploy GitHub App connection."
  type        = string
}
variable "cms_disable_default_auth" {
  description = "Disable email/password only after verifying a Pocket ID administrator can log in."
  type        = bool
  default     = false
}
variable "cms_pocketid_default_role_id" {
  description = "Optional least-privilege Directus role for newly registered Pocket ID users."
  type        = string
  default     = null
}
variable "enable_github_runner" {
  type    = bool
  default = false
}
variable "github_runner_org" {
  type    = string
  default = ""
}

variable "auto_deploy" {
  description = "Let the Dokploy GitHub App deploy on every push. Keep false when GitHub Actions calls the deploy webhook after a merge, otherwise every push deploys twice."
  type        = bool
  default     = false
}

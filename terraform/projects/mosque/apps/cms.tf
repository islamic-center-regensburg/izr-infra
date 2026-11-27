resource "dokploy_application" "cms" {
  name            = "${local.prefix}-cms"
  app_name_prefix = "${local.prefix}-cms"
  environment_id  = var.environment_id
  github = {
    owner        = split("/", trimsuffix(trimsuffix(var.cms_repository_url, "/"), ".git"))[3]
    repository   = split("/", trimsuffix(trimsuffix(var.cms_repository_url, "/"), ".git"))[4]
    branch       = local.git_branch
    github_id    = data.dokploy_github_provider.apps.id
    trigger_type = "push"
  }
  build = { type = "dockerfile", dockerfile = "Dockerfile", context_path = "." }

  env              = <<-EOT
    CMS_ENV=${var.environment}
    DIRECTUS_PORT=8055
    KEY=${local.cms["KEY"].value}
    SECRET=${local.cms["SECRET"].value}
    PUBLIC_URL=https://${var.domains.cms}
    LOG_LEVEL=info
    ADMIN_EMAIL=${local.cms["ADMIN_EMAIL"].value}
    ADMIN_PASSWORD=${local.cms["ADMIN_PASSWORD"].value}
    DB_CLIENT=pg
    DB_HOST=${var.postgres_host}
    DB_PORT=5432
    DB_DATABASE=${local.database_name}
    DB_USER=${local.database_name}
    DB_PASSWORD=${local.cms["DB_PASSWORD"].value}
    SCREEN_TOKEN=${local.cms["SCREEN_TOKEN"].value}
    WEBSITE_TOKEN=${local.cms["WEBSITE_TOKEN"].value}
    MCP_TOKEN=${local.cms["MCP_TOKEN"].value}
    CACHE_SCHEMA=false
    TELEMETRY=false
    WEBSOCKETS_ENABLED=false
    CORS_ENABLED=true
    CORS_ORIGIN=https://${var.domains.cms},https://${var.domains.website},https://${var.domains.screen}
    CORS_CREDENTIALS=true
    SESSION_COOKIE_SAME_SITE=lax
    SESSION_COOKIE_SECURE=true
    REFRESH_TOKEN_COOKIE_SAME_SITE=lax
    REFRESH_TOKEN_COOKIE_SECURE=true
    AUTH_DISABLE_DEFAULT=${var.cms_disable_default_auth}
    AUTH_PROVIDERS=pocketid
    AUTH_POCKETID_DRIVER=openid
    AUTH_POCKETID_CLIENT_ID=${local.cms["AUTH_POCKETID_CLIENT_ID"].value}
    AUTH_POCKETID_CLIENT_SECRET=${local.cms["AUTH_POCKETID_CLIENT_SECRET"].value}
    AUTH_POCKETID_ISSUER_URL=${var.oidc_url}/.well-known/openid-configuration
    AUTH_POCKETID_IDENTIFIER_KEY=email
    AUTH_POCKETID_SCOPE=openid profile email groups
    AUTH_POCKETID_ALLOW_PUBLIC_REGISTRATION=true
    AUTH_POCKETID_COOKIE_SECURE=true
    AUTH_POCKETID_ICON=key
    AUTH_POCKETID_LABEL=IZR ID
    AUTH_POCKETID_MODE=session
    AUTH_POCKETID_REDIRECT_ALLOW_LIST=https://${var.domains.cms}/admin/login,https://${var.domains.cms}/admin/content
    %{if var.cms_pocketid_default_role_id != null}
    AUTH_POCKETID_DEFAULT_ROLE_ID=${var.cms_pocketid_default_role_id}
    %{endif}
  EOT
  auto_deploy      = var.auto_deploy
  deploy_on_change = false
}
resource "dokploy_mount" "cms_uploads" {
  service_id   = dokploy_application.cms.id
  service_type = "application"
  type         = "volume"
  volume_name  = "${local.prefix}-uploads"
  mount_path   = "/directus/uploads"
}
resource "dokploy_domain" "cms" {
  application_id   = dokploy_application.cms.id
  host             = var.domains.cms
  port             = 8055
  https            = true
  certificate_type = "letsencrypt"
}

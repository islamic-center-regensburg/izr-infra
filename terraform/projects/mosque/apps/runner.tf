resource "dokploy_application" "runner" {
  count            = var.enable_github_runner ? 1 : 0
  name             = "${local.prefix}-runner"
  app_name_prefix  = "${local.prefix}-runner"
  environment_id   = var.environment_id
  docker           = { image = "myoung34/github-runner:latest" }
  deploy_on_change = false
  env              = <<-EOT
    RUNNER_SCOPE=org
    ORG_NAME=${var.github_runner_org}
    RUNNER_NAME=${local.prefix}
    RUNNER_WORKDIR=/tmp/runner/work
    LABELS=vps,docker,self-hosted
    RUNNER_TOKEN=${try(data.infisical_secrets.component["runner"].secrets["RUNNER_TOKEN"].value, "")}
  EOT
  lifecycle {
    precondition {
      condition     = var.github_runner_org != null && var.github_runner_org != "" && contains(keys(data.infisical_secrets.component["runner"].secrets), "RUNNER_TOKEN")
      error_message = "Set github_runner_org and add RUNNER_TOKEN to /${var.project}/runner in Infisical before enabling the runner."
    }
  }
}
resource "dokploy_mount" "runner_socket" {
  count        = var.enable_github_runner ? 1 : 0
  service_id   = dokploy_application.runner[0].id
  service_type = "application"
  type         = "bind"
  host_path    = "/var/run/docker.sock"
  mount_path   = "/var/run/docker.sock"
}

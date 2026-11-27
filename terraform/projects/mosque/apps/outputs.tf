output "deployments" {
  value = concat(
    [for app in dokploy_application.web : { kind = "application", id = app.id }],
    [{ kind = "application", id = dokploy_application.cms.id }],
    [for runner in dokploy_application.runner : { kind = "application", id = runner.id }]
  )
}
output "containers" {
  value = []
}
output "checks" {
  value = [
    { url = "https://${var.domains.cms}/server/health", discovery = false },
    { url = "https://${var.domains.website}", discovery = false },
    { url = "https://${var.domains.screen}", discovery = false }
  ]
}

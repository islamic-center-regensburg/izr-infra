terraform {
  required_version = ">= 1.11.0"
  backend "local" {}
  required_providers {
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.11.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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
variable "environment_id" {
  type = string
}
variable "infisical_domain" {
  description = "Public hostname, for example secrets.85.90.244.98.sslip.io."
  type        = string
}
variable "infisical_image" {
  type    = string
  default = "infisical/infisical:v0.167.14"
}

provider "dokploy" {
  endpoint = var.dokploy_endpoint
  api_key  = var.dokploy_api_key
}

# Losing ENCRYPTION_KEY makes every stored secret unrecoverable; back it up with make infisical-recovery.
resource "random_bytes" "encryption_key" {
  length = 16
}
resource "random_bytes" "auth_secret" {
  length = 32
}
resource "random_password" "service" {
  for_each = toset(["database", "redis"])
  length   = 48
  special  = false
}

resource "dokploy_compose" "infisical" {
  name             = "izr-infisical"
  environment_id   = var.environment_id
  deploy_on_change = false
  delete_volumes   = false
  create_env_file  = true
  env              = <<-EOT
    ENCRYPTION_KEY=${random_bytes.encryption_key.hex}
    AUTH_SECRET=${random_bytes.auth_secret.base64}
    POSTGRES_PASSWORD=${random_password.service["database"].result}
    REDIS_PASSWORD=${random_password.service["redis"].result}
  EOT
  raw = {
    compose_file = <<-YAML
      services:
        infisical:
          image: ${var.infisical_image}
          depends_on:
            infisical-db:
              condition: service_healthy
            infisical-redis:
              condition: service_healthy
          environment:
            NODE_ENV: production
            SITE_URL: https://${var.infisical_domain}
            ENCRYPTION_KEY: $${ENCRYPTION_KEY:?ENCRYPTION_KEY is required}
            AUTH_SECRET: $${AUTH_SECRET:?AUTH_SECRET is required}
            DB_CONNECTION_URI: postgres://infisical:$${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}@infisical-db:5432/infisical
            REDIS_URL: redis://:$${REDIS_PASSWORD:?REDIS_PASSWORD is required}@infisical-redis:6379
            TELEMETRY_ENABLED: "false"
          networks: [default, dokploy-network]
          restart: always
        infisical-db:
          image: postgres:16-alpine
          environment:
            POSTGRES_USER: infisical
            POSTGRES_DB: infisical
            POSTGRES_PASSWORD: $${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
          volumes:
            - database:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "infisical", "-d", "infisical"]
            interval: 5s
            timeout: 5s
            retries: 24
          restart: always
        infisical-redis:
          image: redis:7-alpine
          command: ["redis-server", "--appendonly", "yes", "--requirepass", "$${REDIS_PASSWORD:?REDIS_PASSWORD is required}"]
          environment:
            REDISCLI_AUTH: $${REDIS_PASSWORD:?REDIS_PASSWORD is required}
          volumes:
            - redis:/data
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 5s
            timeout: 5s
            retries: 24
          restart: always
      volumes:
        database:
          name: izr-infisical-database
        redis:
          name: izr-infisical-redis
      networks:
        dokploy-network:
          external: true
    YAML
  }
}

resource "dokploy_domain" "infisical" {
  compose_id       = dokploy_compose.infisical.id
  service_name     = "infisical"
  host             = var.infisical_domain
  port             = 8080
  https            = true
  certificate_type = "letsencrypt"
}

output "url" {
  value = "https://${var.infisical_domain}"
}
output "deployments" {
  value = [{ kind = "compose", id = dokploy_compose.infisical.id }]
}
output "containers" {
  value = [{ project = dokploy_compose.infisical.app_name, service = "infisical-db", mode = "healthy" }]
}
output "checks" {
  value = [{ url = "https://${var.infisical_domain}/api/status" }]
}
output "recovery" {
  description = "Back up privately; required to decrypt Infisical's database."
  sensitive   = true
  value = {
    ENCRYPTION_KEY = random_bytes.encryption_key.hex
    AUTH_SECRET    = random_bytes.auth_secret.base64
  }
}

# Layered IZR infrastructure

The platform and its consumers have independent Terraform roots and states.
Use the root Makefile rather than running Terraform in `terraform/`.

## Layout and ownership

```text
terraform/
  bootstrap/
    projects/             Dokploy projects and their dev/prod environments
    infisical/
      service/            One shared Infisical (+ its own PostgreSQL/Redis) in izr-secrets/prod
      project/            Infisical project "IZR" with dev and prod environments
    secrets/              Per-environment platform credentials in Infisical
    postgres/             One PostgreSQL server per environment
    oidc/
      database/           Pocket ID database/user on shared PostgreSQL
      service/            Pocket ID application, domain and persistent mount
  modules/
    database/             Repeatable database/user provisioning job
  projects/
    mosque/
      secrets/            Application credentials in Infisical
      databases/          Mosque database/users on shared PostgreSQL
      apps/               Website, screen, CMS and optional runner
```

`bootstrap/projects` exclusively owns `izr-secrets`, `izr-postgres`, `izr-oidc`
and registered consumer projects such as `izr-mosque`. Every project has
exactly two environments. Terraform creates `dev`; `prod` is Dokploy's
generated default environment, which keeps its name `production` because
Dokploy does not allow renaming it. Layers address environments by ID.
The shared Infisical uses only `prod`; its `dev` environment is intentionally empty.

PostgreSQL and Pocket ID have one instance per environment. CMS and Pocket ID
use different databases and non-superuser database owners on the same
PostgreSQL server. Infisical keeps its own PostgreSQL and Redis so that it
does not depend on the platform database it supplies credentials for.

## Prerequisites

- Python 3.8+, Terraform 1.11+, Make and SSH on the deployment machine.
- Dokploy v0.31.0+ and Docker Compose 2.23.1+ on the target host.
- One Docker host shared by these Dokploy projects, with `dokploy-network`.
  This implementation does not distribute workloads across different servers.
- SSH access to that host with permission to inspect Docker containers.
- DNS for every configured hostname, with ports 80/443 reaching Traefik.
  sslip.io names such as `secrets.85.90.244.98.sslip.io` work without DNS setup.
  Valid HTTPS is required; certificate verification is never disabled.
- Install and authorize the GitHub App in Dokploy's Git > GitHub UI with
  access to the website, screen and CMS repositories. Terraform looks up
  the existing connection by the `github_app_name` in apps tfvars; it cannot
  create or install the App.
  Its GitHub webhook must reach Dokploy and deliver push events.

Shared credentials live in a git-ignored `.env` at the repository root:

```sh
cp .env.example .env
chmod 600 .env
# edit DOKPLOY_ENDPOINT, DOKPLOY_API_KEY and DOKPLOY_SSH
```

The runner loads `.env`; variables already exported in your shell win.
`make infisical-bootstrap` adds `INFISICAL_TOKEN` to it automatically.
Never put these credentials in layer tfvars or `.example` files: the runner
rejects Dokploy credentials in tfvars, and examples are meant to be committed.

## Configuration files

Copy and edit the examples; private tfvars are ignored by Git.
Run `make help` to see the required tfvars for each listed command.

| Root | Required local configuration |
| --- | --- |
| `bootstrap/projects` | `terraform.tfvars` |
| `bootstrap/infisical/service` | `terraform.tfvars` |
| `bootstrap/secrets` | `dev.tfvars`, `prod.tfvars` |
| `bootstrap/oidc/service` | `dev.tfvars`, `prod.tfvars` |
| `projects/mosque/secrets` | `dev.tfvars`, `prod.tfvars` |
| `projects/mosque/apps` | `dev.tfvars`, `prod.tfvars` |

For example:

```sh
cp terraform/bootstrap/projects/terraform.tfvars.example terraform/bootstrap/projects/terraform.tfvars
cp terraform/bootstrap/infisical/service/terraform.tfvars.example terraform/bootstrap/infisical/service/terraform.tfvars
cp terraform/bootstrap/secrets/dev.tfvars.example terraform/bootstrap/secrets/dev.tfvars
cp terraform/bootstrap/oidc/service/dev.tfvars.example terraform/bootstrap/oidc/service/dev.tfvars
cp terraform/projects/mosque/secrets/dev.tfvars.example terraform/projects/mosque/secrets/dev.tfvars
cp terraform/projects/mosque/apps/dev.tfvars.example terraform/projects/mosque/apps/dev.tfvars
```

Repeat the environment-specific copies for production when needed.
IDs, database hostnames, the Infisical URL/project and the OIDC URL are passed
between roots automatically. Do not copy IDs manually or put `environment`
overrides in tfvars. Make selects the state and injects its canonical environment.

Website, screen and CMS repositories must have a root Dockerfile.
Development uses branch `dev`; production uses `main`. CMS builds the
Directus bootstrap repository, not the stock Directus image.
The website and screen Dockerfiles run their TanStack Start SSR Node servers
on port 3000. Dokploy routes each app's domain to that port. Both apps receive
`NODE_ENV=production`, `PORT=3000`, `DIRECTUS_API_URL` (the configured CMS
HTTPS domain), and a server-only `DIRECTUS_READ_TOKEN` at runtime. Tokens must
never be supplied as `VITE_` variables or build arguments.

## Deployment sequence

The Make layers execute prerequisites sequentially, including with `make -j`:

```text
preflight
  -> projects + environments
  -> Infisical deployment + /api/status gate
  -> first admin bootstrap (once; saves INFISICAL_TOKEN to .env)
  -> Infisical project "IZR" with dev/prod environments
  -> environment platform secrets in Infisical
  -> PostgreSQL deployment + healthy-container gate
  -> Pocket ID database provisioning + successful-job gate
  -> Pocket ID deployment + OIDC discovery gate
  -> project secrets (requires configured OIDC client credentials)
  -> project database provisioning + successful-job gate
  -> application deployment + HTTP/job checks
```

On the first run:

```sh
make bootstrap-global
make infisical-recovery     # store the output in a password manager
make bootstrap-env ENV=dev
```

`bootstrap-global` deploys Infisical and then asks once for the first admin
email, organization and password. That creates the admin you sign in with at
the Infisical URL and a non-expiring instance admin token, which is saved to
`.env` and used by Terraform. Rerunning it skips the bootstrap when the token
is set. If the instance is already bootstrapped but the token was lost, sign
in and create a new token for "Instance Admin Identity" in Server Console >
Machine Identities.

`make infisical-recovery` prints Infisical's `ENCRYPTION_KEY` and
`AUTH_SECRET`. Losing `ENCRYPTION_KEY` makes every stored secret unreadable,
even with a database backup. Infisical has no unseal step: it starts on its
own after a restart.

Once Pocket ID is available, complete its initial administrator setup and
create a dedicated CMS OIDC client in that environment. Set its redirect URI
to `https://<cms-domain>/auth/login/pocketid/callback`. Put its client ID and
secret in `projects/mosque/secrets/dev.tfvars`, using the provided example.
Use a separate client in the production Pocket ID instance.

Then run the complete workflow, or only its project portion:

```sh
make full ENV=dev PROJECTS=mosque
make project-deploy ENV=dev PROJECT=mosque
```

`make full ENV=all PROJECTS=mosque` processes dev and prod independently,
with global roots applied only once. The workflow is resumable: successful
prerequisites remain deployed, errors stop subsequent layers, and deployment
success markers are written only after that layer's checks pass.
Deploy requests carry a unique description; the runner waits for that exact
Dokploy deployment to finish successfully before readiness checks. Applications
also wait for the Swarm rollout to complete with replacement running tasks, so
an old healthy endpoint cannot prematurely satisfy deployment readiness.
Queued jobs, builds and rollouts have a five-minute timeout per request; failures
and rollbacks stop the workflow without a success marker. Inspect protected
Dokploy logs before retrying a timeout: the queued job is not automatically cancelled.
Unchanged Infisical/PostgreSQL configurations are not needlessly redeployed.
Database jobs and consumers are deliberately redeployed to reconcile database
users/passwords and pick up changed secrets.

This is not an unattended first installation: the admin bootstrap, Pocket ID
client creation and Terraform confirmations remain explicit.
`TF_APPLY_ARGS=-auto-approve` is available only when you intentionally want
to skip apply confirmations. Targeted applies are not supported.

## Secrets and state

Infisical project "IZR" (slug `izr-platform`) has `dev` and `prod`
environments with one folder per component:

```text
/platform/postgres       POSTGRES_PASSWORD
/platform/oidc           DB_PASSWORD, ENCRYPTION_KEY, INITIAL_ADMIN_EMAIL
/mosque/cms              DB_PASSWORD, KEY, SECRET, ADMIN_EMAIL, ADMIN_PASSWORD,
                         AUTH_POCKETID_CLIENT_ID, AUTH_POCKETID_CLIENT_SECRET
/mosque/website          DIRECTUS_READ_TOKEN (add manually before deploying)
/mosque/screen           DIRECTUS_READ_TOKEN (add manually before deploying)
/mosque/runner           RUNNER_TOKEN (add manually before enabling the runner)
```

Create separate least-privilege Directus read-only service users/tokens for
website and screen in each environment, then add each token to its matching
Infisical folder before applying the apps layer. Tokens are intentionally not
generated or included in Terraform examples.

Secrets layers generate passwords once and write them to Infisical as
write-only values, so they are not kept in those layers' state. Infisical is
the source of truth: a value you edit there is kept on re-apply. Values that
come from tfvars (admin emails, OIDC client ID/secret) are re-applied from
tfvars, so change those in tfvars. To regenerate every generated credential
of a layer, increase its `credential_version` variable.

Consumer layers read their folder from Infisical and inject the values into
Dokploy environment variables (Terraform injection). Dokploy has no Infisical
integration, so the injected values are stored in Dokploy and in those
consumer layers' state; plans show them only as `(sensitive value)`. After
changing a secret in Infisical, redeploy the consuming layer, for example
`make project-deploy ENV=dev PROJECT=mosque`. Use letters and digits when
editing values by hand; `$` and newlines are not safe in Compose env files.

Changing a database password in Infisical is applied by the database layer,
which updates the role. The PostgreSQL superuser password is different: the
server only reads it when its data volume is first created, so changing
`/platform/postgres` alone does not change the existing role password.

Local states are under `.state/states/`, for example:

```text
bootstrap/projects/global.tfstate
bootstrap/infisical/service/global.tfstate
bootstrap/secrets/dev.tfstate
projects/mosque/apps/prod.tfstate
```

Each root and environment has its own `TF_DATA_DIR`; provider-cache
installation is locked. `ENV=all` means two separate runs. Only non-sensitive
outputs are passed between roots. Plans are created in private temporary
directories and removed after use. Keep `.state/` and `.env` on an encrypted,
access-controlled disk, include them in secure backups, and never commit them.
Changing `STATE_DIR` selects a different state location; it does not migrate
existing resources.

## Databases and persistence

The PostgreSQL service starts only the server. Separate provisioning roots
run SQL jobs after readiness, rather than relying on empty-volume init scripts.
Jobs use quoted SQL identifiers and values, create missing databases/users,
update their passwords, and revoke public access. They are rerun on each
database-layer apply. Adding a project does not recreate PostgreSQL.

Jobs run inside `dokploy-network`; port 5432 is not published to the host.
Completion requires a newly started container to exit with code zero, not
merely a successful Terraform create. Job logs may contain sensitive
operational details; inspect them privately.

Infisical and PostgreSQL Compose volumes are retained on destruction.
Database-job destruction removes the job definition, not the logical database
or its contents. Deleting users/databases/retained volumes requires a separate,
explicit data-retirement procedure. Back up data and preserve its credentials.

## CMS and Pocket ID

CMS receives stage-specific discovery, client credentials, secure session/
refresh/state cookies and an explicit CORS origin list for CMS, website and
screen. Database names/users are project-prefixed, such as `mosque_cms`.
The bootstrap repository's local `.env`, Compose PostgreSQL variables and
`DB_HOST=db` are not used in Dokploy.

Website, screen and CMS use the Dokploy GitHub App source with auto-deploy
enabled for push events: `dev` deploys the `dev` branch and `prod` deploys
`main`. Repository URLs in the apps tfvars must be HTTPS github.com
owner/repository URLs. After applying a change to the source, verify the App's
installation permissions and webhook delivery in GitHub and push to the
configured branch to confirm automatic redeployment. Terraform source changes
alone do not initiate a deployment (`deploy_on_change = false`).

Local email/password login stays enabled initially. Before setting
`cms_disable_default_auth = true` in the apps tfvars, link and test a Directus
administrator account with authentication provider `pocketid` and the matching
email as External Identifier. The bootstrap admin email alone does not link
that account to OIDC.

OIDC auto-registration is enabled, but it does not make users administrators.
Optionally configure `cms_pocketid_default_role_id` to a least-privilege
Directus role. Requesting the `groups` scope does not automatically map
Pocket ID groups to Directus roles. CMS schema/seed startup scripts must be
safe to rerun against an existing database.

## Plans, validation and destruction

```sh
make validate
make plan STACK=apps ENV=dev PROJECT=mosque
make plan STACK=platform-secrets ENV=prod
make plan STACK=infisical-project
make destroy STACK=apps ENV=dev PROJECT=mosque
```

Validation initializes and validates all active roots without connecting to
live services. It does not execute unit tests.
Plans require the prerequisite layers' outputs and successful deployment
markers. Applies show a saved plan and require confirmation before changing
resources; rerunning an application layer also triggers deployment.

Destruction is explicit by layer and refuses to remove upstream services
while downstream states still track resources. Follow the deployment order
in reverse. There is deliberately no command that automatically purges all
shared platform data. GitHub runners remain opt-in and mount the host Docker
socket, which grants effectively root access to the host.

## Adding another project

1. Add its slug, for example `school`, to the persistent `consumer_projects`
   set in `bootstrap/projects/terraform.tfvars`. Do not replace that set with
   the projects selected for one deployment.
2. Implement `terraform/projects/school/{secrets,databases,apps}` with the same
   injected input/output contract as mosque and its own `/school/...` Infisical folders.
3. Configure its dev/prod tfvars and create its OIDC clients.
4. Run `make full ENV=dev PROJECTS="mosque school"`.

## Fresh platform

This workflow bootstraps a fresh platform using the isolated state paths
described above. Files from previous layouts are not read, migrated or
deleted automatically.

# Infrastructure guide

Layered Terraform for one Dokploy host: platform layers (topology, Infisical
vault, platform secrets, PostgreSQL, Pocket ID) and project layers
(`terraform/projects/<project>/{secrets,databases,apps}`), applied in dependency
order by `scripts/stack.py` through the Makefile. Follows the
`dokploy-terraform-platform` skill; read it before structural changes. Code and Git
state win over this file.

## Rules

- **Never run `terraform apply` or `destroy`, rotate credentials, or install
  anything without explicit approval.** Infrastructure is applied by hand on the
  owner's Mac (no terraform binary in the dev container); produce config and a plan.
- `make steps ENV=dev` prints the order of a trial run. `make help` lists targets.
- Layers apply in order; no `-target`. Add a project by extending
  `consumer_projects`, then copy `templates/new-project/` from the skill.
- Secrets: generated ones use `ephemeral` + `value_wo`; real values only in
  git-ignored `.env` and `*.tfvars`; `.example` files hold placeholders only. A real
  key in an example file counts as leaked: rotate it.
- CMS service-user tokens (`SCREEN_TOKEN`, `WEBSITE_TOKEN`, `MCP_TOKEN`) are
  generated in `projects/mosque/secrets` and given to the CMS and to its consumer.
  The website and screen reach the CMS by its private Swarm name, not the public URL.
- `auto_deploy` is false: deploys come from the orchestrator or from the shared
  GitHub workflow calling each app's Dokploy webhook (organization secrets
  `DEPLOY_WEBHOOK_<APP>_<DEV|PROD>`).
- Long-running Compose services set `restart: always`.

## Git workflow

`dev` is the default branch and PR target; `main` only takes PRs from `dev`
(CI job `main-from-dev-only`). Work on feature branches, conventional commits
without scopes, commit with the `commit-changes` skill, never push without approval.

## Validation

- `python3 -m unittest discover -s scripts` for the orchestrator.
- `make validate PROJECT=mosque` and `make plan STACK=<stack> ENV=dev` need terraform
  on the owner's machine. State, `.env` and tfvars stay out of Git.

## Status and open items

- Trial run on a server pending (`make steps`).
- `izr-cms` revisions flow must be merged before the new CMS env (tokens, `CACHE_SCHEMA`) is deployed.

.PHONY: bootstrap-global bootstrap-env projects infisical infisical-bootstrap infisical-project infisical-recovery
.PHONY: platform-secrets postgres oidc-database oidc

bootstrap-global: preflight
	$(MAKE) --no-print-directory projects
	$(MAKE) --no-print-directory infisical
	$(MAKE) --no-print-directory infisical-bootstrap
	$(MAKE) --no-print-directory infisical-project

projects:
	$(STACK_RUNNER) apply projects
infisical:
	$(STACK_RUNNER) apply infisical
infisical-bootstrap:
	$(STACK_RUNNER) infisical-bootstrap
infisical-project:
	$(STACK_RUNNER) apply infisical-project
infisical-recovery:
	$(STACK_RUNNER) infisical-recovery

bootstrap-env:
	@for environment in $(STAGE_ENVS); do \
		$(MAKE) --no-print-directory platform-secrets ENV=$$environment && \
		$(MAKE) --no-print-directory postgres ENV=$$environment && \
		$(MAKE) --no-print-directory oidc-database ENV=$$environment && \
		$(MAKE) --no-print-directory oidc ENV=$$environment || exit $$?; \
	done

platform-secrets postgres oidc-database oidc:
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) apply $@ --env "$$environment" || exit $$?; \
	done

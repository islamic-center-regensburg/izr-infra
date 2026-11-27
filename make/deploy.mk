.PHONY: full bootstrap deployment deploy secrets

full: bootstrap-global
	@for environment in $(STAGE_ENVS); do \
		$(MAKE) --no-print-directory bootstrap-env ENV=$$environment && \
		$(MAKE) --no-print-directory project-deploy ENV=$$environment PROJECTS="$(PROJECTS)" || exit $$?; \
	done

bootstrap: bootstrap-global
	$(MAKE) --no-print-directory bootstrap-env
deployment deploy: project-deploy
secrets: project-secrets

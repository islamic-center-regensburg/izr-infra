.PHONY: project-deploy project-secrets project-databases project-apps

project-deploy:
	@for environment in $(STAGE_ENVS); do \
		for project in $(PROJECTS); do \
			$(MAKE) --no-print-directory project-secrets ENV=$$environment PROJECT=$$project && \
			$(MAKE) --no-print-directory project-databases ENV=$$environment PROJECT=$$project && \
			$(MAKE) --no-print-directory project-apps ENV=$$environment PROJECT=$$project || exit $$?; \
		done; \
	done

project-secrets:
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) apply secrets --env "$$environment" --project "$(PROJECT)" || exit $$?; \
	done
project-databases:
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) apply databases --env "$$environment" --project "$(PROJECT)" || exit $$?; \
	done
project-apps:
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) apply apps --env "$$environment" --project "$(PROJECT)" || exit $$?; \
	done

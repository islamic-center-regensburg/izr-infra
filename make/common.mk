TERRAFORM ?= terraform
ENV ?= dev
PROJECT ?= mosque
PROJECTS ?= $(PROJECT)
STATE_DIR ?= $(ROOT_DIR)/.state
DOKPLOY_SSH ?=
TF_APPLY_ARGS ?=

export TERRAFORM STATE_DIR DOKPLOY_SSH TF_APPLY_ARGS

ifneq ($(filter $(ENV),dev prod all),$(ENV))
$(error ENV must be dev, prod or all)
endif
ifeq ($(strip $(ENV)),)
$(error ENV must be dev, prod or all)
endif
ifneq ($(words $(ENV)),1)
$(error ENV must be exactly one of dev, prod or all)
endif
ifneq ($(strip $(SERVICES)),)
$(error SERVICES targeting is retired; use a project/layer deployment so dependencies and removals are not skipped)
endif
ifneq ($(strip $(DEPLOYMENT_STAGE)),)
$(error DEPLOYMENT_STAGE is retired; use ENV=dev, ENV=prod or ENV=all with separate states)
endif

STAGE_ENVS := $(if $(filter all,$(ENV)),dev prod,$(ENV))
STACK_RUNNER := python3 "$(ROOT_DIR)/scripts/stack.py"

.PHONY: init validate preflight plan destroy
init:
	$(STACK_RUNNER) init --project "$(PROJECT)"
validate:
	$(STACK_RUNNER) validate --project "$(PROJECT)"
preflight:
	$(STACK_RUNNER) preflight
plan:
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) plan $(or $(STACK),apps) --env "$$environment" --project "$(PROJECT)" || exit $$?; \
	done
destroy:
	@test -n "$(STACK)" || { echo "Specify STACK explicitly; shared data is not destroyed automatically."; exit 1; }
	@for environment in $(STAGE_ENVS); do \
		$(STACK_RUNNER) destroy "$(STACK)" --env "$$environment" --project "$(PROJECT)" || exit $$?; \
	done

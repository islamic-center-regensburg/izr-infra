# --------------------------------------
# Main Makefile
# --------------------------------------
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))


include make/common.mk
include make/bootstrap.mk
include make/projects.mk
include make/deploy.mk
include make/steps.mk

.DEFAULT_GOAL := help

.PHONY: help

help:
	@echo ""
	@echo "Available commands:"
	@echo ""
	@echo "  Configuration:"
	@echo "    Credentials (Dokploy, SSH, Infisical token) live in .env; copy .env.example."
	@echo "    tfvars paths below are relative to terraform/."
	@echo "    Copy each file from its matching .example and edit it before deployment."
	@echo "    <env> is dev or prod; ENV=all requires both files."
	@echo "    <project> is PROJECT, or each entry in PROJECTS for full/project-deploy."
	@echo ""
	@echo "  Steps:"
	@echo "    make steps ENV=dev PROJECT=mosque   Print the order of a trial run on a server"
	@echo ""
	@echo "  Terraform:"
	@echo "    make full ENV=dev PROJECTS=mosque    Deploy all layers in dependency order"
	@echo "      tfvars: bootstrap/projects/terraform.tfvars"
	@echo "              bootstrap/infisical/service/terraform.tfvars"
	@echo "              bootstrap/secrets/<env>.tfvars"
	@echo "              bootstrap/oidc/service/<env>.tfvars"
	@echo "              projects/<project>/secrets/<env>.tfvars"
	@echo "              projects/<project>/apps/<env>.tfvars"
	@echo ""
	@echo "    make bootstrap-global              Projects, Infisical, first admin and secrets project"
	@echo "      tfvars: bootstrap/projects/terraform.tfvars"
	@echo "              bootstrap/infisical/service/terraform.tfvars"
	@echo ""
	@echo "    make infisical-bootstrap           Create the first admin once; saves INFISICAL_TOKEN to .env"
	@echo "      tfvars: none"
	@echo ""
	@echo "    make infisical-recovery            Print Infisical ENCRYPTION_KEY/AUTH_SECRET for backup"
	@echo "      tfvars: none"
	@echo ""
	@echo "    make bootstrap-env ENV=dev          Platform secrets, PostgreSQL and Pocket ID"
	@echo "      tfvars: bootstrap/secrets/<env>.tfvars"
	@echo "              bootstrap/oidc/service/<env>.tfvars"
	@echo ""
	@echo "    make project-deploy ENV=dev PROJECT=mosque"
	@echo "      tfvars: projects/<project>/secrets/<env>.tfvars"
	@echo "              projects/<project>/apps/<env>.tfvars"
	@echo ""
	@echo "    make plan STACK=apps ENV=dev PROJECT=mosque"
	@echo "      tfvars: projects/<project>/apps/<env>.tfvars"
	@echo ""
	@echo "    make validate                      Initialize and validate all active roots"
	@echo "      tfvars: none"
	@echo ""
	@echo "    make destroy STACK=apps ENV=dev PROJECT=mosque"
	@echo "      tfvars: projects/<project>/apps/<env>.tfvars"
	@echo ""
	@echo "    For another STACK, plan/destroy use that layer's tfvars instead."
	@echo "    ENV=all runs dev/prod separately; global tfvars are shared."
	@echo "    See terraform/README.md for setup, credentials and prerequisite layers."
	@echo ""

# Makefile — the single entry point for every check in this repository.
#
# Every check is invoked through these targets, locally and in CI alike: CI
# calls these exact targets rather than open-coding the commands, so the two
# invocation paths cannot drift apart.
#
# Only the targets that work today ship here. `lint`, `scan`, `test` and the
# per-environment plan/apply/destroy targets arrive with the commits that add
# the thing each one drives — a target that does not work yet is
# indistinguishable from one that is broken.

# Bash rather than /bin/sh, with `-e -u -o pipefail`, so a command that fails
# inside a loop or a pipeline fails the target instead of being swallowed.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.DEFAULT_GOAL := help

# The toolchain version has exactly one source of truth. Reading it here means
# the Makefile and .terraform-version cannot disagree about which binary the
# repository declares.
TERRAFORM_VERSION := $(shell cat .terraform-version)

.PHONY: help check-terraform fmt fmt-check validate

help: ## Show the available targets.
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*## " } { printf "  %-10s %s\n", $$1, $$2 }'
	@echo
	@echo "terraform pinned by .terraform-version: $(TERRAFORM_VERSION)"

# Internal guard, deliberately absent from `help`: not a check in its own right,
# but a prerequisite of every target that shells out to terraform. Running a
# check against a version the repository does not declare produces a result
# that does not describe the repository, so refuse rather than proceed.
check-terraform:
	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "make: terraform was not found on PATH." >&2; \
		echo "      this repository pins terraform $(TERRAFORM_VERSION) in .terraform-version." >&2; \
		echo "      install it with:  tfenv install && tfenv use" >&2; \
		echo "                   or:  tenv tf install && tenv tf use" >&2; \
		exit 1; \
	fi; \
	out="$$(terraform version)"; \
	actual="$${out%%$$'\n'*}"; \
	actual="$${actual#Terraform v}"; \
	if [ "$$actual" != "$(TERRAFORM_VERSION)" ]; then \
		echo "make: terraform version mismatch." >&2; \
		echo "      expected $(TERRAFORM_VERSION)  (pinned in .terraform-version)" >&2; \
		echo "      found    $$actual  ($$(command -v terraform))" >&2; \
		echo "      fix with:  tfenv install $(TERRAFORM_VERSION) && tfenv use $(TERRAFORM_VERSION)" >&2; \
		echo "            or:  tenv tf install $(TERRAFORM_VERSION) && tenv tf use $(TERRAFORM_VERSION)" >&2; \
		exit 1; \
	fi

# Formatting is purely textual, so it is correct from the repository root and
# recursive: no per-directory initialisation is involved. `terraform fmt` skips
# dot-directories, so .terraform/ is not visited.
fmt: check-terraform ## Rewrite Terraform files into canonical format, in place.
	terraform fmt -recursive .

fmt-check: check-terraform ## Fail if any Terraform file is not canonically formatted.
	terraform fmt -check -diff -recursive .

# Validation targets are discovered, never listed: every directory holding at
# least one .tf file is initialised and validated in turn. A hardcoded list
# silently stops covering directories added after it was written, and the root
# of this repository never holds a .tf file at all. `init -backend=false`
# configures no remote state, so this needs no bucket, no role and no AWS
# credentials — which is what makes it safe as a required check.
validate: check-terraform ## Init (-backend=false) and validate every directory holding .tf files.
	@dirs="$$(find . -type d -name .terraform -prune -o -type f -name '*.tf' -print \
		| sed 's|/[^/]*$$||' \
		| sort -u)"; \
	if [ -z "$$dirs" ]; then \
		echo "no directories with .tf files found; nothing to validate"; \
		exit 0; \
	fi; \
	while IFS= read -r dir; do \
		echo "==> $$dir"; \
		terraform -chdir="$$dir" init -backend=false -input=false; \
		terraform -chdir="$$dir" validate; \
	done <<< "$$dirs"

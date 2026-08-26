# Makefile — the single entry point for every check in this repository.
#
# Every check is invoked through these targets, locally and in CI alike: CI
# calls these exact targets rather than open-coding the commands, so the two
# invocation paths cannot drift apart.
#
# Only the targets that work today ship here. `test` and the per-environment
# plan/apply/destroy targets arrive with the commits that add the thing each
# one drives — a target that does not work yet is indistinguishable from one
# that is broken.

# Bash rather than /bin/sh, with `-e -u -o pipefail`, so a command that fails
# inside a loop or a pipeline fails the target instead of being swallowed.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.DEFAULT_GOAL := help

# The toolchain version has exactly one source of truth. Reading it here means
# the Makefile and .terraform-version cannot disagree about which binary the
# repository declares.
TERRAFORM_VERSION := $(shell cat .terraform-version)

# TFLint has no equivalent of .terraform-version that its own installers read,
# so this is the pin, and validate.yml reads it back out of here through
# `print-tflint-version` rather than repeating the number.
TFLINT_VERSION := 0.64.0

# TFLint resolves a relative --config against each directory it descends into,
# so in recursive mode a relative path silently finds nothing and every
# subdirectory falls back to the built-in defaults — no AWS ruleset, no pinned
# version, no naming rule. The path has to be absolute.
TFLINT_CONFIG := $(CURDIR)/.tflint.hcl

# Trivy likewise has no version file of its own, so this is the pin and
# validate.yml reads it back through `print-trivy-version`. Pinning it is what
# makes `scan` reproducible in a second sense as well: `--skip-check-update`
# below runs the checks compiled into this exact binary, so the release number
# fixes the rules as well as the scanner.
TRIVY_VERSION := 0.74.0

# Absolute for the same reason as TFLINT_CONFIG: Trivy resolves --ignorefile
# against the working directory, so a relative path would quietly resolve to
# nothing the moment `scan` is invoked from anywhere but the repository root.
TRIVY_IGNOREFILE := $(CURDIR)/.trivyignore

.PHONY: help fmt fmt-check validate lint scan \
	check-terraform check-tflint check-trivy \
	print-tflint-version print-trivy-version

help: ## Show the available targets.
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*## " } { printf "  %-10s %s\n", $$1, $$2 }'
	@echo
	@echo "terraform pinned by .terraform-version: $(TERRAFORM_VERSION)"
	@echo "tflint pinned by this Makefile:         $(TFLINT_VERSION)"
	@echo "trivy pinned by this Makefile:          $(TRIVY_VERSION)"

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

# The same guard for tflint. A linter is a moving target in a way a formatter
# is not: rules are added, renamed and re-scoped between releases, so a run
# against an unpinned binary answers a question this repository did not ask.
check-tflint:
	@if ! command -v tflint >/dev/null 2>&1; then \
		echo "make: tflint was not found on PATH." >&2; \
		echo "      this repository pins tflint $(TFLINT_VERSION)." >&2; \
		echo "      install it with:  brew install tflint" >&2; \
		echo "                   or:  from https://github.com/terraform-linters/tflint/releases/tag/v$(TFLINT_VERSION)" >&2; \
		exit 1; \
	fi; \
	out="$$(tflint --version)"; \
	actual="$${out%%$$'\n'*}"; \
	actual="$${actual#TFLint version }"; \
	if [ "$$actual" != "$(TFLINT_VERSION)" ]; then \
		echo "make: tflint version mismatch." >&2; \
		echo "      expected $(TFLINT_VERSION)  (pinned in the Makefile)" >&2; \
		echo "      found    $$actual  ($$(command -v tflint))" >&2; \
		echo "      tflint has no version manager, so pick the matching build:" >&2; \
		echo "        brew upgrade tflint   (when the formula is at $(TFLINT_VERSION))" >&2; \
		echo "        https://github.com/terraform-linters/tflint/releases/tag/v$(TFLINT_VERSION)" >&2; \
		exit 1; \
	fi

# And the same guard again for trivy, where the stakes are higher still: the
# check IDs are compiled into the binary, so an unpinned trivy silently changes
# which misconfigurations this repository considers unacceptable. A scan that
# passes because the binary is older than the rule is worse than no scan.
check-trivy:
	@if ! command -v trivy >/dev/null 2>&1; then \
		echo "make: trivy was not found on PATH." >&2; \
		echo "      this repository pins trivy $(TRIVY_VERSION)." >&2; \
		echo "      install it with:  brew install trivy" >&2; \
		echo "                   or:  from https://github.com/aquasecurity/trivy/releases/tag/v$(TRIVY_VERSION)" >&2; \
		exit 1; \
	fi; \
	out="$$(trivy --version)"; \
	actual="$${out%%$$'\n'*}"; \
	actual="$${actual#Version: }"; \
	if [ "$$actual" != "$(TRIVY_VERSION)" ]; then \
		echo "make: trivy version mismatch." >&2; \
		echo "      expected $(TRIVY_VERSION)  (pinned in the Makefile)" >&2; \
		echo "      found    $$actual  ($$(command -v trivy))" >&2; \
		echo "      trivy has no version manager, so pick the matching build:" >&2; \
		echo "        brew upgrade trivy   (when the formula is at $(TRIVY_VERSION))" >&2; \
		echo "        https://github.com/aquasecurity/trivy/releases/tag/v$(TRIVY_VERSION)" >&2; \
		exit 1; \
	fi

# Also internal: the one place validate.yml can ask which tflint this
# repository pins, so the workflow and the guard cannot disagree.
print-tflint-version:
	@echo "$(TFLINT_VERSION)"

# The same for trivy: validate.yml installs whatever this prints, so the
# installed binary and the version check-trivy demands are the same number.
print-trivy-version:
	@echo "$(TRIVY_VERSION)"

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

# TFLint needs no init per directory and no backend, so unlike `validate` it
# discovers its own targets: `--recursive` descends from the root and simply
# finds nothing to say while there is no Terraform here yet. The AWS ruleset's
# deep-check rules stay off, so this reaches no AWS API and needs no
# credentials. `--init` installs the ruleset pinned in .tflint.hcl and is a
# no-op once it is present.
lint: check-tflint ## Lint every directory holding .tf files with TFLint and the AWS ruleset.
	tflint --init --config "$(TFLINT_CONFIG)"
	tflint --recursive --config "$(TFLINT_CONFIG)"

# The security gate, and the one check here that can be a no-op without ever
# looking like one: `trivy config` exits 0 on findings unless told otherwise,
# so --exit-code 1 is not a preference, it is the whole point of the target.
# Config mode reads HCL statically — no plan, no state, no provider, no AWS
# call — which is what lets it run on a pull request from a fork.
#
# --severity is spelled out in full rather than left to the default so that an
# upstream change to that default cannot quietly raise the bar for what counts
# as a failure. Everything fails the build, UNKNOWN included: there are no
# findings to grandfather in today, and accepting one later should cost a
# reviewed entry in .trivyignore rather than nothing at all.
#
# --skip-check-update pins the rules to the binary. Trivy ships its checks
# compiled in and otherwise pulls a newer bundle from ghcr.io on every run,
# which would mean an unchanged commit could start failing on a Tuesday, and
# would make the scan depend on a registry being reachable. With it, the pin
# above fixes the scanner and the rules together. On a machine with no Trivy
# cache — every CI runner — this prints "Falling back to embedded checks" at
# ERROR level. That line is the intended path, not a failure: the embedded
# checks are the ones this version was built with, and they produce the same
# findings the downloadable bundle does. Re-check that when TRIVY_VERSION is
# bumped.
scan: check-trivy ## Scan every Terraform file for misconfigurations with Trivy.
	trivy config . \
		--exit-code 1 \
		--severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL \
		--ignorefile "$(TRIVY_IGNOREFILE)" \
		--skip-check-update

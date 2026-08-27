# Makefile — the single entry point for every check in this repository.
#
# Every check is invoked through these targets, locally and in CI alike: CI
# calls these exact targets rather than open-coding the commands, so the two
# invocation paths cannot drift apart.
#
# Only the targets that work today ship here — a target that does not work yet
# is indistinguishable from one that is broken. The stage and prod targets each
# arrived with the commit that created the directory they point at; `test`
# arrives with the module tests.
#
# The file is in two halves. Everything down to `scan` is a check: it reaches no
# AWS account, needs no credentials, and is safe to require on a pull request.
# Everything after it talks to AWS.

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
	plan-stage apply-stage destroy-stage \
	plan-prod apply-prod destroy-prod \
	check-terraform check-tflint check-trivy \
	print-tflint-version print-trivy-version

help: ## Show the available targets.
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*## " } { printf "  %-14s %s\n", $$1, $$2 }'
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
#
# One class of directory is skipped, and it is skipped because Terraform cannot
# do what this target asks of it rather than because checking would be
# inconvenient. A module declaring `configuration_aliases` is stating that it
# takes provider configurations from whoever calls it. Initialised as a root
# there is no caller, so those providers are declared and never configured, and
# `validate` fails on every resource using one with "Provider configuration not
# present" — an error about the invocation, not about the code.
#
# Such a directory is validated through the roots that call it: the environments
# under envs/ pass the providers in, and the module is loaded, type-checked and
# validated as part of validating them. The example root beside each module is
# what provides that caller before the environments exist. TFLint and Trivy read
# these directories directly and are unaffected — neither needs a provider to be
# configured.
#
# The test below matches the HCL argument rather than the word: anchored to the
# start of a line and requiring the `=`, so it cannot be tripped by a comment
# discussing `configuration_aliases`, which is how the first version of this
# skipped the example root that exists to defeat it.
#
# A skip on its own would be a hole in a required check, and that is the whole
# reason for the second pass below. "Validated through its callers" is a claim,
# and nothing so far makes it true: a module added with `configuration_aliases`
# and no caller would drop silently out of this target, print a reassuring line,
# and exit 0 having been type-checked by nothing. That is exactly the failure
# discovery was designed to prevent, reintroduced one directory at a time. So
# every skipped directory has to produce a caller — an `examples/<name>/` root
# beside it, which the first pass validated like any other root — and this target
# fails if one does not. The claim and its evidence land together or not at all.
validate: check-terraform ## Init (-backend=false) and validate every directory holding .tf files.
	@dirs="$$(find . -type d -name .terraform -prune -o -type f -name '*.tf' -print \
		| sed 's|/[^/]*$$||' \
		| sort -u)"; \
	if [ -z "$$dirs" ]; then \
		echo "no directories with .tf files found; nothing to validate"; \
		exit 0; \
	fi; \
	skipped=(); \
	while IFS= read -r dir; do \
		if grep -Eq '^[[:space:]]*configuration_aliases[[:space:]]*=' "$$dir"/*.tf 2>/dev/null; then \
			echo "==> $$dir (child module — validated through its callers)"; \
			skipped+=("$$dir"); \
			continue; \
		fi; \
		echo "==> $$dir"; \
		terraform -chdir="$$dir" init -backend=false -input=false; \
		terraform -chdir="$$dir" validate; \
	done <<< "$$dirs"; \
	uncovered=(); \
	for dir in $${skipped[@]+"$${skipped[@]}"}; do \
		if ! compgen -G "$$dir/examples/*/*.tf" >/dev/null; then \
			uncovered+=("$$dir"); \
		fi; \
	done; \
	if [ $${#uncovered[@]} -gt 0 ]; then \
		echo "" >&2; \
		echo "make: validate skipped these child modules but found no caller to validate them through:" >&2; \
		printf '        %s\n' "$${uncovered[@]}" >&2; \
		echo "" >&2; \
		echo "      A module declaring configuration_aliases cannot be validated as a root," >&2; \
		echo "      so it is only ever type-checked through a root that calls it. Without one" >&2; \
		echo "      it is covered by nothing and this check would pass on unvalidated HCL." >&2; \
		echo "      Add an examples/<name>/ root beside the module that calls it and passes" >&2; \
		echo "      its providers in." >&2; \
		exit 1; \
	fi

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

# ---------------------------------------------------------------------------
# The environment targets
# ---------------------------------------------------------------------------

# Everything above this line is a check: it reaches no AWS account, needs no
# credentials, and is safe to make a required status check. Everything below it
# talks to AWS. They are separated rather than interleaved so that the boundary
# is visible in the file rather than remembered.
#
# One canned recipe, called once per environment per verb, instead of six
# near-identical bodies. The duplication these replace is not cosmetic: `envs/
# prod` is `envs/stage` with different values, so a prod target written by
# copying a stage target is exactly where an `-chdir` gets left pointing at
# stage — an apply that reports success against the wrong environment, which is
# the single worst failure available here. With one body the environment is an
# argument and cannot be half-edited.
#
# The targets are still spelled out one per environment rather than written as
# a `%` pattern rule. A pattern would silently accept `make plan-nonsense`, and
# it would have made `plan-prod` exist before `envs/prod` did — a target that
# does not work yet is indistinguishable from one that is broken, which is the
# rule that kept each trio out of the repository until the commit that created
# the directory it points at.
#
# $(1) is the terraform subcommand, $(2) the environment name.
define terraform_env
	@if [ ! -f "envs/$(2)/backend.hcl" ]; then \
		echo "make: envs/$(2)/backend.hcl is missing." >&2; \
		echo "      Backend values are per-account — the state bucket carries a random" >&2; \
		echo "      suffix — so the file is gitignored and created from the example:" >&2; \
		echo "" >&2; \
		echo "        cp envs/$(2)/backend.hcl.example envs/$(2)/backend.hcl" >&2; \
		echo "" >&2; \
		echo "      Then fill in the bucket and region. The bootstrap prints them:" >&2; \
		echo "" >&2; \
		echo "        terraform -chdir=bootstrap output backend_init_command" >&2; \
		exit 1; \
	fi
	terraform -chdir="envs/$(2)" init -input=false -backend-config=backend.hcl
	terraform -chdir="envs/$(2)" $(1)
endef

# `init` runs on every invocation rather than only the first, and it is cheap
# once the providers are cached. It is what makes these targets correct after a
# `git pull` that changed a provider constraint or the module's source, instead
# of failing with a stale lock or a module that is not there.
#
# The one thing it cannot do for you is decide what a *changed* `backend.hcl`
# means. Edit that file after a successful init — correcting a typo in the
# bucket name is the usual reason — and the next run stops with "Backend
# configuration changed", asking for `-reconfigure` or `-migrate-state`. Neither
# flag is added here, because which one is correct depends on a fact this
# Makefile does not have:
#
#   -reconfigure    discards the recorded association and initialises against
#                   the new values. Right when nothing was ever written under
#                   the old ones — a typo caught on the first init, which is
#                   the common case.
#   -migrate-state  copies the existing state to the new location. Right when
#                   the old values did point at real state that should move.
#
# Guessing wrong in the first direction abandons a state file; guessing wrong in
# the second copies state somewhere it does not belong. Baking `-reconfigure`
# into the recipe would make that choice silently, on every run, for everyone —
# which is why the error is left to surface and be read.
#
# None of the three passes `-auto-approve` or `-input=false` to the verb itself.
# The interactive confirmation on apply and destroy is the only thing standing
# between a mistyped target and a real environment, and CI does not use these
# targets — `apply.yml` applies a reviewed plan artefact, which is a different
# and stronger control than a prompt.

plan-stage: check-terraform ## Plan the stage environment against AWS.
	$(call terraform_env,plan,stage)

apply-stage: check-terraform ## Apply the stage environment. Prompts before changing anything.
	$(call terraform_env,apply,stage)

destroy-stage: check-terraform ## Destroy the stage environment. Prompts before removing anything.
	$(call terraform_env,destroy,stage)

plan-prod: check-terraform ## Plan the prod environment against AWS.
	$(call terraform_env,plan,prod)

apply-prod: check-terraform ## Apply the prod environment. Prompts before changing anything.
	$(call terraform_env,apply,prod)

destroy-prod: check-terraform ## Destroy the prod environment. Prompts before removing anything.
	$(call terraform_env,destroy,prod)

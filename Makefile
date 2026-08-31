# Makefile — the single entry point for every check in this repository.
#
# Every check is invoked through these targets, locally and in CI alike: CI
# calls these exact targets rather than open-coding the commands, so the two
# invocation paths cannot drift apart.
#
# Only the targets that work today ship here — a target that does not work yet
# is indistinguishable from one that is broken. The stage and prod targets each
# arrived with the commit that created the directory they point at, and `test`
# arrived with the module tests.
#
# The file is in two halves. Everything down to `audit-online` is a check and
# reaches no AWS account; everything after it talks to AWS. All but one of the
# checks are also credential-free and safe to require on a pull request —
# `audit-online` is the exception, and it argues for itself where it sits.

# Bash rather than /bin/sh, with `-e -u -o pipefail`, so a command that fails
# inside a loop or a pipeline fails the target instead of being swallowed.
#
# The flags are stated twice, and the repetition is deliberate. `.SHELLFLAGS`
# is their documented home and it arrived in GNU Make 3.82; macOS ships 3.81 —
# the last GPLv2 release and the newest Apple will distribute — which parses
# the variable and then ignores it. So every recipe below ran under a plain
# `bash -c` on a macOS clone while running under `bash -euo pipefail -c` in CI,
# and the two invocation paths this file exists to keep identical disagreed
# about whether a check had failed. Not hypothetically: `validate` looped over
# seven directories, printed `terraform validate` errors from three of them,
# and exited 0.
#
# A `SHELL` carrying its own arguments is honoured by both, because make builds
# the shell's argv by splitting this variable on whitespace. 3.81 takes the
# flags from here; 3.82 and later take them from both places, where a repeated
# `-euo pipefail` means what it meant the first time. Neither line is redundant
# on its own: drop this one and the checks stop failing on macOS, drop the
# other and they depend on an undocumented reading of `SHELL`.
#
# Stating them twice also makes them unremovable, which is worth knowing
# before it is discovered the hard way: a per-target `.SHELLFLAGS := -c`
# opt-out silently does nothing here, because `SHELL` still carries the flags.
# A recipe that genuinely needs a plain shell has to override `SHELL` too.
#
# Verified against GNU Make 3.81 (macOS 15) and GNU Make 4.3 (Ubuntu 24.04,
# which is the image every job in .github/workflows/ now pins), including the
# opt-out above failing on both.
SHELL := /usr/bin/env bash -euo pipefail
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

# And terraform-docs, for the third time and the same reason: no version file of
# its own, so this is the pin and validate.yml reads it back through
# `print-terraform-docs-version`. It matters more here than it looks. The output
# of a documentation generator is compared byte for byte by `docs-check`, so a
# release that changes a table's spacing turns every pull request red until
# somebody regenerates — and the diff that fixes it says nothing about why.
TERRAFORM_DOCS_VERSION := 0.24.0

# Absolute for the same reason as the two paths above, and for one more:
# terraform-docs resolves a relative --config against the directory it is
# pointed at, not the working directory, so a relative path would look for the
# config inside each module and fall back to built-in defaults on not finding
# it — a different table, generated in silence.
TERRAFORM_DOCS_CONFIG := $(CURDIR)/.terraform-docs.yml

# And zizmor, on the same terms as the three above and for the fourth time: no
# version file of its own, so this is the pin and validate.yml reads it back
# through `print-zizmor-version`.
#
# It is the only tool here that reads no Terraform. What it audits is
# .github/workflows/ itself — an unpinned `uses:`, a `permissions:` block wider
# than the job needs, a checkout that leaves a credential on disk for every
# later step — and its rules are compiled into the binary exactly as Trivy's
# are, so this number fixes what counts as a hardening failure and not only who
# reports it.
ZIZMOR_VERSION := 1.29.0

# The runner image, and the fifth pin in this file rather than a sixth rule
# nobody checks. It is the odd one out in two ways: the value it pins lives in
# .github/workflows/ rather than in a binary on PATH, and there is no upstream
# tool that reads it — so `audit-policy` below is what makes it a pin instead of
# a convention. The argument for pinning it at all is rule 4 of the policy at
# the top of validate.yml: `ubuntu-latest` has already moved once, from 22.04 to
# 24.04, on a schedule GitHub picks rather than this repository.
RUNNER_IMAGE := ubuntu-24.04

.PHONY: help fmt fmt-check validate lint scan docs docs-check test \
	audit audit-online audit-policy \
	plan-stage apply-stage destroy-stage \
	plan-prod apply-prod destroy-prod \
	check-terraform check-tflint check-trivy check-terraform-docs check-zizmor \
	print-tflint-version print-trivy-version print-terraform-docs-version \
	print-zizmor-version

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
	@echo "terraform-docs pinned by this Makefile: $(TERRAFORM_DOCS_VERSION)"
	@echo "zizmor pinned by this Makefile:         $(ZIZMOR_VERSION)"
	@echo "runner image pinned by this Makefile:   $(RUNNER_IMAGE)"

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

# And once more for terraform-docs, where the guard is doing more work than the
# other two. tflint and trivy disagree with an unpinned binary by reporting a
# finding nobody asked for; terraform-docs disagrees by rewriting a README, so
# an unguarded `make docs` on the wrong version produces a diff that passes
# review as noise and then fails `docs-check` in CI against the pinned one.
check-terraform-docs:
	@if ! command -v terraform-docs >/dev/null 2>&1; then \
		echo "make: terraform-docs was not found on PATH." >&2; \
		echo "      this repository pins terraform-docs $(TERRAFORM_DOCS_VERSION)." >&2; \
		echo "      install it with:  brew install terraform-docs" >&2; \
		echo "                   or:  from https://github.com/terraform-docs/terraform-docs/releases/tag/v$(TERRAFORM_DOCS_VERSION)" >&2; \
		exit 1; \
	fi; \
	out="$$(terraform-docs --version)"; \
	actual="$${out#terraform-docs version v}"; \
	actual="$${actual%% *}"; \
	if [ "$$actual" != "$(TERRAFORM_DOCS_VERSION)" ]; then \
		echo "make: terraform-docs version mismatch." >&2; \
		echo "      expected $(TERRAFORM_DOCS_VERSION)  (pinned in the Makefile)" >&2; \
		echo "      found    $$actual  ($$(command -v terraform-docs))" >&2; \
		echo "      terraform-docs has no version manager, so pick the matching build:" >&2; \
		echo "        brew upgrade terraform-docs   (when the formula is at $(TERRAFORM_DOCS_VERSION))" >&2; \
		echo "        https://github.com/terraform-docs/terraform-docs/releases/tag/v$(TERRAFORM_DOCS_VERSION)" >&2; \
		exit 1; \
	fi

# And a fourth guard, for zizmor, with trivy's stakes reached from the other
# side of the repository: the audit rules are compiled into the binary, so an
# older zizmor passes a workflow a newer one rejects — and what it would have
# rejected is the hardening `audit` exists to hold in place.
check-zizmor:
	@if ! command -v zizmor >/dev/null 2>&1; then \
		echo "make: zizmor was not found on PATH." >&2; \
		echo "      this repository pins zizmor $(ZIZMOR_VERSION)." >&2; \
		echo "      install it with:  brew install zizmor" >&2; \
		echo "                   or:  from https://github.com/zizmorcore/zizmor/releases/tag/v$(ZIZMOR_VERSION)" >&2; \
		exit 1; \
	fi; \
	out="$$(zizmor --version)"; \
	actual="$${out#zizmor }"; \
	if [ "$$actual" != "$(ZIZMOR_VERSION)" ]; then \
		echo "make: zizmor version mismatch." >&2; \
		echo "      expected $(ZIZMOR_VERSION)  (pinned in the Makefile)" >&2; \
		echo "      found    $$actual  ($$(command -v zizmor))" >&2; \
		echo "      zizmor has no version manager, so pick the matching build:" >&2; \
		echo "        brew upgrade zizmor   (when the formula is at $(ZIZMOR_VERSION))" >&2; \
		echo "        https://github.com/zizmorcore/zizmor/releases/tag/v$(ZIZMOR_VERSION)" >&2; \
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

# And for terraform-docs.
print-terraform-docs-version:
	@echo "$(TERRAFORM_DOCS_VERSION)"

# And for zizmor.
print-zizmor-version:
	@echo "$(ZIZMOR_VERSION)"

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
# That claim is about a fresh checkout, and the `rm -f` in the loop below is
# what keeps it true on a working copy too. `-backend=false` does not mean "no
# backend"; it means "do not configure one, use what was previously
# initialised". An environment directory where `make plan-stage` or
# `make plan-prod` has run carries its S3 backend in
# .terraform/terraform.tfstate, so `init` re-uses it — and initialising an S3
# backend validates credentials against STS. That made the AWS-free half of
# this file fail with an InvalidClientTokenId whenever a session had expired,
# and made the pre-commit hook built on this target reject every commit
# touching a .tf file, which is how it was found. CI never saw it, because a
# fresh checkout has nothing previously initialised.
#
# So the record is removed before each init, and three facts make that a
# deletion rather than a gamble. It is derived: `.terraform/` is gitignored and
# rebuilt by `init`, and the environment targets below re-initialise on every
# invocation by design, so nothing here depends on it surviving. It holds
# backend *configuration* and not state — `{backend, terraform_version,
# version}`, no resources — on a path that did hold cached remote state in
# Terraform 0.11 and earlier, which `required_version >= 1.11` and
# .terraform-version both refuse to run. And only envs/stage and envs/prod have
# one at all: a local backend writes no record, so bootstrap and the example
# root have none to remove.
#
# The alternative was a TF_DATA_DIR of this target's own, which is structurally
# the cleaner answer and was measured before being rejected. It buys a second
# copy of the providers in every directory something else also initialises —
# 798M apiece, against 3.0G free on the machine this was written on, where
# `make validate` duly stopped with "no space left on device". A
# TF_PLUGIN_CACHE_DIR turns those copies into links and the cost does vanish
# (4.0K per data directory, measured), but requiring one puts a second
# provider-installation path behind the one target that most needs to fail only
# for reasons about the code, and how that path interacts with the `h1:` hashes
# recorded in each .terraform.lock.hcl is not a question this target should be
# the first to ask.
#
# What the deletion costs instead: after `make validate`, a terraform command
# run directly in envs/stage or envs/prod stops with "Backend initialization
# required" until something initialises the workspace again. The plan, apply
# and destroy targets here init on every run and are unaffected. The direct
# invocations are not, and the first version of this comment claimed they were
# — four snippets across docs/TEARDOWN.md and docs/BOOTSTRAP.md drove terraform
# straight at an environment root with no init line, and every one of them
# broke. They now carry the init line themselves, which is the fix and also the
# standing rule: a runbook snippet aimed at an environment root inits first, or
# it is a snippet that works only on the day it was written. bootstrap/ takes a
# local backend and records nothing, so nothing there is affected either way.
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
		rm -f "$$dir/.terraform/terraform.tfstate"; \
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

# The inputs and outputs tables in each module's README, generated from the .tf
# files and injected between the BEGIN_TF_DOCS/END_TF_DOCS markers. `docs`
# rewrites them; `docs-check` fails instead of rewriting, which is the form CI
# runs — a job that regenerated and pushed would be a gate that reports green on
# work it did itself.
#
# Targets are discovered rather than listed, for the reason `validate` above
# gives: a list authored against the modules that exist today stops covering the
# ones added tomorrow, and a documentation check that silently covers nothing is
# indistinguishable from one that passes.
#
# Two kinds of directory under modules/ are deliberately not the same thing. A
# module publishes an interface — variables in, outputs out — and that interface
# is what these tables document. An `examples/<name>/` root beside it publishes
# none: it is a caller, written to be read as HCL, and it exists so that
# `validate` has a root through which to type-check a module declaring
# `configuration_aliases`. Generating a table of "no inputs" and one output for
# it would add a second README to keep current and document nothing, so the
# examples are excluded here — while remaining fully covered by fmt, validate,
# lint and scan, which is where an example root can actually be wrong.
#
# The exclusion is a `sed` delete rather than a `grep -v` because `pipefail` is
# on: `grep` exits 1 when it filters everything away, which would abort the
# recipe with no message on the one case the empty check below exists to
# report. `sed` returns 0 whether it deleted a line or not.
#
# $(1) is the extra flag, empty for generation and --output-check for the gate.
define terraform_docs
	@dirs="$$(find modules -type d -name .terraform -prune -o -type f -name '*.tf' -print \
		| sed -e 's|/[^/]*$$||' -e '\|/examples/|d' \
		| sort -u)"; \
	if [ -z "$$dirs" ]; then \
		echo "no modules found under modules/; nothing to document"; \
		exit 0; \
	fi; \
	while IFS= read -r dir; do \
		echo "==> $$dir"; \
		if ! terraform-docs --config "$(TERRAFORM_DOCS_CONFIG)" $(1) "$$dir"; then \
			echo "" >&2; \
			echo "make: terraform-docs failed on $$dir." >&2; \
			echo "      From docs-check that means README.md no longer matches the .tf" >&2; \
			echo "      files beside it. The block between the BEGIN_TF_DOCS and" >&2; \
			echo "      END_TF_DOCS markers is generated, so it is regenerated rather" >&2; \
			echo "      than edited:" >&2; \
			echo "" >&2; \
			echo "        make docs" >&2; \
			echo "" >&2; \
			echo "      To change what it says, edit the description on the variable" >&2; \
			echo "      or output in question and regenerate." >&2; \
			exit 1; \
		fi; \
	done <<< "$$dirs"
endef

docs: check-terraform-docs ## Regenerate the terraform-docs block in every module README.
	$(call terraform_docs,)

docs-check: check-terraform-docs ## Fail if any module README's generated block is out of date.
	$(call terraform_docs,--output-check)

# The module's own tests.
#
# Targets are discovered rather than listed, for the third time and the same
# reason `validate` and the documentation targets give: a list written against
# the modules that have tests today stops covering the ones added tomorrow. Each
# `.tftest.hcl` is mapped back to the root it tests — the directory holding it,
# or its parent when that directory is the conventional `tests/` — because
# `terraform test` runs from the module, not from the test file.
#
# `init -backend=false` for the same reason it appears in `validate`: it
# configures no remote state, so this needs no bucket and no role. Unlike
# `validate` there is no recorded backend to remove first — a module is never a
# plan target, so nothing here has ever been initialised against S3.
#
# The claim that matters, because it is what makes this a required check rather
# than an environment target: this reaches no AWS account either. That is not a
# property of `terraform test`, which configures the provider like any other
# command and fails with an STS InvalidClientTokenId before the first assertion
# on a machine with an expired session. It is a property of how the test files
# configure their providers, and the argument is at the top of
# modules/static-site/tests/plan.tftest.hcl rather than restated here. Verified
# with no HOME, no AWS environment variables and every outbound HTTP request
# black-holed.
#
# The second pass below exists for the reason `validate`'s does, and the two are
# deliberately the same shape. Discovery by file is what keeps a target covering
# directories added after it was written; it is also what lets a directory fall
# out of the target in silence, because a module shipped with no `.tftest.hcl`
# beside it is not skipped with a message — it is simply never mentioned, and
# this required check goes green having tested nothing about it. So every module
# under modules/ has to produce a test root, and this target fails if one does
# not.
#
# `docs` sets the other precedent and it is the weaker fit here, which is worth
# saying rather than leaving as an unexplained asymmetry: `docs-check` exits 0
# only when there are no modules at all, and fails the moment a module's README
# has drifted from the .tf files beside it — so a module it covers cannot be
# silently uncovered. A module with no tests is exactly that. There is also
# nothing else to fall back on: `validate` can honestly say a skipped module is
# type-checked through its callers, and no other target in this file asserts
# anything a test would.
#
# `examples/` roots are excluded, as they are from `docs`, and for the same
# reason: an example is a caller written to be read, not an interface with
# behaviour to pin down. It is covered by fmt, validate, lint and scan, which is
# where an example root can actually be wrong.
test: check-terraform ## Run the module tests with `terraform test`.
	@dirs="$$(find . -type d -name .terraform -prune -o -type f -name '*.tftest.hcl' -print \
		| sed -e 's|/[^/]*$$||' -e 's|/tests$$||' -e 's|^\./||' \
		| sort -u)"; \
	if [ -z "$$dirs" ]; then \
		echo "no .tftest.hcl files found; nothing to run"; \
	else \
		while IFS= read -r dir; do \
			echo "==> $$dir"; \
			terraform -chdir="$$dir" init -backend=false -input=false; \
			terraform -chdir="$$dir" test; \
		done <<< "$$dirs"; \
	fi; \
	modules="$$(find modules -type d -name .terraform -prune -o -type f -name '*.tf' -print \
		| sed -e 's|/[^/]*$$||' -e '\|/examples/|d' \
		| sort -u)"; \
	untested=(); \
	while IFS= read -r module; do \
		[ -n "$$module" ] || continue; \
		if ! grep -qxF -- "$$module" <<< "$$dirs"; then \
			untested+=("$$module"); \
		fi; \
	done <<< "$$modules"; \
	if [ $${#untested[@]} -gt 0 ]; then \
		echo "" >&2; \
		echo "make: these modules have no terraform tests:" >&2; \
		printf '        %s\n' "$${untested[@]}" >&2; \
		echo "" >&2; \
		echo "      This target discovers its work from the .tftest.hcl files it finds, so" >&2; \
		echo "      a module without any is not skipped with a warning — it is never" >&2; \
		echo "      mentioned, and this required check reports green having asserted" >&2; \
		echo "      nothing about it. Add tests/<name>.tftest.hcl beside the module." >&2; \
		echo "" >&2; \
		echo "      modules/static-site/tests/plan.tftest.hcl is the worked example," >&2; \
		echo "      including how a module taking configuration_aliases is given its" >&2; \
		echo "      provider configurations and how the suite stays credential-free." >&2; \
		exit 1; \
	fi

# The workflows themselves, audited the way the Terraform is scanned: static
# analysis against rules compiled into a pinned binary, with everything it
# finds failing the build. It is the only check here that reads no Terraform at
# all, and the last one that is credential-free.
#
# It does not overlap `actionlint`, which runs in validate.yml and in
# .pre-commit-config.yaml and deliberately not from here, there being no
# invocation for a target to own. actionlint asks whether a workflow is
# *valid* — its syntax, its expressions, and through shellcheck its `run:`
# blocks. zizmor asks whether it is *safe* — an unpinned `uses:`, a
# `permissions:` block wider than the job needs, a checkout leaving a
# credential on disk for every later step. Neither has anything to say about
# the other's findings, which is why both run.
#
# `.` rather than a list of workflow files. zizmor collects workflows,
# composite action definitions, the Dependabot configuration and
# .pre-commit-config.yaml from wherever they are, honouring .gitignore, so
# pointing it at the repository root is what keeps this target covering the
# files added after it was written — the discovery argument `validate`, `docs`
# and `test` each make for their own targets, and the one that paid for itself
# the moment .github/dependabot.yml arrived: that file is collected and audited
# by this target with nothing here changed to admit it, which is also how the
# `dependabot-cooldown` finding below reached a required check before anybody
# went looking for it.
#
# `--offline` is the flag that needs defending, and the reason is not economy.
# zizmor selects its mode from whether a GitHub token is in the environment, so
# without the flag this target audits one thing in a shell that has run
# `gh auth login` and a smaller thing in a shell that has not — five audits'
# worth — and a CI runner is always the shell that has not. That divergence runs
# in the direction the top of .pre-commit-config.yaml names as the worst one:
# the local gate failing on findings the CI gate cannot see, which teaches a
# contributor to distrust the green answer that comes back from GitHub. The
# flag equalises the two, downward and on purpose.
#
# What it surrenders is those five. Four are documented as online-only and cost
# little:
#
#   impostor-commit           a SHA that exists only in a fork of the repository
#                             it is written against. Answered by hand instead —
#                             every pin in .github/workflows/ was produced by
#                             dereferencing the tag beside it through the API,
#                             which asks the same question at the moment the pin
#                             is written rather than on every run.
#   ref-confusion             separates a tag from a branch, a question every
#                             `uses:` here settles by being a SHA.
#   stale-action-refs         `--pedantic`-only, so it does not run at this
#                             persona in either mode.
#   known-vulnerable-actions  queries GitHub's advisory database — a rule set
#                             that moves without a commit, so an unchanged
#                             repository could start failing on a Tuesday. The
#                             argument `scan` makes for `--skip-check-update`,
#                             landing in the same place.
#
# The fifth is `ref-version-mismatch`, and it is the one that costs something.
# It compares a hash pin against the `# vX.Y.Z` comment written beside it, which
# is rule 1 of the policy at the top of validate.yml — the comment the next bump
# is read against. zizmor's own audit table marks it as working offline, so this
# is measured rather than read, at v1.29.0: a checkout SHA labelled `# v4.1.1`
# when the tag is v7.0.1 produces nothing at all offline, in either persona, and
# `warning[ref-version-mismatch]` at medium with a token in the environment.
#
# So the version comment beside every pin is checked by nothing this target
# runs, and .github/dependabot.yml is what stopped that being hypothetical. It
# looks weekly and opens a pull request whenever an action has moved, so
# SHA/comment pairs are now rewritten without anybody choosing the moment —
# and a bump that takes the new SHA while keeping the old comment is green
# here, green under actionlint and green in every required check. `audit-online` below is what catches it — and it is no
# longer a target somebody has to remember to type, because the `audit-online`
# job in validate.yml runs it on every pull request, which is where a moved pin
# arrives whether Dependabot moved it or a person did.
#
# .github/workflows/provider-lock-refresh.yml is the other automation added
# alongside it, and it is deliberately *not* named above. Naming it would be
# wrong in a way worth writing down rather than quietly fixing: that workflow
# rewrites `.terraform.lock.hcl` and never touches a `uses:` line, so
# `ref-version-mismatch` — the audit this whole section exists for — has
# nothing to read in its diff. Dependabot moves action pins, the lock refresh
# moves provider versions, and only the first is what this obligation is about.
#
# `audit-policy` runs first, as a prerequisite rather than as a second command
# here, because a red target should name what broke. It carries the two rules of
# the policy that zizmor has no audit for; the division of labour is enumerated
# at the top of validate.yml and again on that target below.
#
# The default `regular` persona, not `--pedantic` or `--persona=auditor`. Every
# run prints a suppressed count, and that count is the whole of what the
# stricter personas add here. Re-measured at v1.29.0 rather than carried
# forward, because it had already gone stale once — `(9 suppressed)` as this is
# written:
#
#   1  concurrency-limits         validate.yml, which needs no concurrency
#                                 group because no job in it takes a lock.
#   5  undocumented-permissions   the `id-token: write` lines in plan.yml (one),
#                                 apply.yml (two) and e2e.yml (two).
#   2  secrets-outside-env        the two `secrets.PROVIDER_LOCK_TOKEN`
#                                 references in provider-lock-refresh.yml.
#   1  superfluous-actions        peter-evans/create-pull-request in the same
#                                 file, which zizmor reads as functionality the
#                                 runner already provides. Here it is not:
#                                 opening this pull request with the runner's
#                                 own token is exactly what docs/BOOTSTRAP.md
#                                 section 8 rules out, and why.
#
# The list is what is load-bearing, not the number. This paragraph said "(4
# suppressed)" and "three `undocumented-permissions` ... in plan.yml and
# apply.yml" until e2e.yml added two more and nothing here noticed — a bare
# count goes stale silently, an enumeration goes stale visibly.
#
# `undocumented-permissions` is not fixable in the direction it looks, which is
# measured at v1.29.0 rather than assumed: the audit is satisfied by a comment
# *trailing* the permission and not by one on the line above it. All five of
# those lines already carry an explanation — on the line above. Clearing them
# means either repeating each one as a trailing comment or flattening it into
# one, in the five places where the rationale is longest, and this repository
# trades the other way.
#
# `secrets-outside-env` is the one item here worth revisiting on its own
# merits, and it is not only an audit. It asks for the token to live on a
# GitHub Environment rather than on the repository, and an Environment with a
# deployment branch policy of `main` would make that token unreadable from a
# topic branch — structurally stronger than the ref check
# provider-lock-refresh.yml performs in a `run:` block, which a modified copy
# of that workflow on a branch could simply delete. It is not taken here
# because it changes how the platform is bootstrapped rather than how it is
# audited, and docs/BOOTSTRAP.md section 8 specifies a repository secret.
#
# A gate whose green depends on a list of suppressions is a gate nobody reads,
# and one bought by shortening the reasoning is worse than that.
#
# `--strict-collection` is the one flag here that changes this target's
# contract rather than its findings, so it is argued rather than added.
#
# Without it, an input zizmor cannot validate against its schema is dropped
# with a WARN line and the run carries on — which is exit 0 on a file nobody
# read. Measured at v1.29.0 against a deliberately broken Dependabot config: a
# mistyped top-level key (`updaets:`) and a mistyped `package-ecosystem` value
# (`gihub-actions`) each print `failed to validate ... as dependabot config` at
# WARN and exit 0, and the flag turns both into exit 1. The second is the one
# that matters. A typo in that value is a Dependabot configuration that does
# nothing at all, and without the flag this target reports green having read it
# and green having *not* read it, identically — including the
# `dependabot-cooldown` finding, which stops firing along with everything else.
#
# It is not complete coverage, and the gap is measured the same way: a mistyped
# key *inside* an update entry passes the schema and is caught in neither mode
# (`includ:` under `commit-message`, and `scheduel:` for `schedule:`, both
# measured clean). So the flag closes the case where the file is silently not
# read. The case where it is read and means something other than intended is
# still held by nothing here, and shows up as a Dependabot pull request that
# never arrives — which is a slow signal, and is named as one rather than
# covered.
audit: check-zizmor audit-policy ## Audit the GitHub Actions workflows: zizmor, and the rules zizmor has no rule for.
	zizmor --offline --strict-collection .

# Rules 4 and 5 of the policy at the top of validate.yml, which nothing else in
# this repository has a rule for.
#
# That gap is measured rather than assumed, and it is the whole reason this
# target exists: at zizmor 1.29.0 and actionlint 1.7.12, a workflow carrying both
# a floating `runs-on` and a job with no `timeout-minutes` produces zero findings
# from zizmor at all three personas in both modes, and zero from actionlint. The
# commit that wrote the policy named zizmor as its enforcement and then found
# zizmor covers three of the six rules. Two of the other three are checked here.
# The last, rule 2's `using: node24`, cannot be checked offline and says so where
# it is written.
#
# Two greps rather than a YAML parse, and the objection to answer is that these
# files are full of prose *about* `runs-on:`. They are, and one character
# separates the two: a comment begins with `#`, so anchoring to the start of the
# line tells them apart completely. Measured on this repository — `ubuntu-24.04`
# appears in sixteen comments across the three files, and the anchored expression
# matches none of them and exactly the thirteen real keys. A parser is available
# rather than out of reach (`/usr/bin/python3` here carries PyYAML 6.0.3) and is
# still not the cheaper answer: it would make this target depend on a module that
# is present by accident rather than by declaration, in order to distinguish
# something a `^` already distinguishes.
#
# What makes a grep acceptable is not that it is right today, it is that it
# refuses when its assumption stops holding. Both checks anchor at exactly four
# spaces — where a job's own keys sit, one level shallower than a step's — and
# the first thing the loop does is compare that anchored count against an
# unanchored one and stop if they differ. A structural check that quietly stops
# applying is the failure this target exists to prevent, arriving from inside it.
#
# Rule 5 is counted rather than attributed, and that is the one place this is
# weaker than a parser would be: it proves a file declares as many job timeouts
# as runners, not which job is short. The count is exact — every job that names
# a runner can carry a timeout, and a job that names no runner can carry
# neither — so what is lost is the job's name in the message, and a file plus two
# numbers is close enough to find it.
audit-policy: ## Check the two hardening rules no linter here covers.
	@files="$$(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)"; \
	if [ -z "$$files" ]; then \
		echo "make: no workflow files found under .github/workflows/." >&2; \
		echo "      This target discovers its own work, so an empty result is a pass" >&2; \
		echo "      that asserted nothing rather than a repository with nothing to say." >&2; \
		exit 1; \
	fi; \
	status=0; \
	while IFS= read -r file; do \
		loose="$$(grep -cE '^[[:space:]]*runs-on:' "$$file" || true)"; \
		strict="$$(grep -cE '^    runs-on:' "$$file" || true)"; \
		if [ "$$loose" != "$$strict" ]; then \
			echo "make: $$file indents a runs-on key somewhere other than four spaces." >&2; \
			echo "      Four is where a job's own keys sit, and it is the assumption both" >&2; \
			echo "      checks here are built on. Refusing rather than reporting a pass" >&2; \
			echo "      this target cannot stand behind." >&2; \
			status=1; \
			continue; \
		fi; \
		bad="$$(awk -v want="runs-on: $(RUNNER_IMAGE)" '/^    runs-on:/ { value = $$0; sub(/^ +/, "", value); if (value != want) printf "        %s:%d: %s\n", FILENAME, FNR, value }' "$$file")"; \
		if [ -n "$$bad" ]; then \
			echo "make: $$file names a runner this repository does not pin." >&2; \
			printf '%s\n' "$$bad" >&2; \
			echo "      Rule 4 at the top of validate.yml: the runner image is pinned like" >&2; \
			echo "      the rest of the toolchain, at $(RUNNER_IMAGE), because a floating" >&2; \
			echo "      label moves underneath a repository that pins Terraform to a patch." >&2; \
			echo "      A job that genuinely needs another image changes RUNNER_IMAGE in" >&2; \
			echo "      this Makefile, on purpose and in one place." >&2; \
			status=1; \
		fi; \
		timeouts="$$(grep -cE '^    timeout-minutes:' "$$file" || true)"; \
		if [ "$$strict" != "$$timeouts" ]; then \
			echo "make: $$file declares $$strict runner(s) and $$timeouts job timeout(s)." >&2; \
			echo "      Rule 5 at the top of validate.yml: every job carries a" >&2; \
			echo "      timeout-minutes, because GitHub's default is six hours and the" >&2; \
			echo "      failure shape here is a hang rather than a crash. The counts are" >&2; \
			echo "      compared rather than the jobs matched up, so this names the file" >&2; \
			echo "      and not the job: one missing timeout is one short." >&2; \
			status=1; \
		fi; \
	done <<< "$$files"; \
	exit $$status

# The five audits `audit` cannot run, on demand, and deliberately never a gate.
#
# It is not a stricter `audit`; it is the same tool with a network. Two of the
# properties that make it useful are the same two that disqualify it from being
# a required check: it needs a credential, which the required set is kept free
# of so that bot-authored pull requests can satisfy it, and it can change its
# answer while this repository does not change, because
# `known-vulnerable-actions` reports on a database rather than on this tree.
# Neither belongs in a gate. Both are fine in a command somebody types.
#
# One half of that has since been measured and is weaker than it was written,
# and it is left standing rather than quietly edited because the paragraph is
# what the `audit-online` job in validate.yml points readers at. The
# credential half does not hold: zizmor's online audits are public reads — ref
# listings on github.com, `api.github.com/advisories` — so the token lifts a
# rate limit and selects zizmor's mode rather than authorising anything, and a
# Dependabot pull request's read-only token is enough. The second half is
# untouched and decides it alone: `known-vulnerable-actions` reports on a
# database that moves without a commit, so a required check running it could
# take `main` red on a Tuesday with nothing here having changed.
#
# When it runs, which is no longer only when somebody types it. The
# `audit-online` job in validate.yml runs this target on every pull request,
# which covers the moment `ref-version-mismatch` exists for — a `uses:` pin
# moving — without depending on anyone remembering. .github/dependabot.yml is
# what moves most of them now; a pin moved by hand is covered by the same job
# for the same reason.
#
# Not the lock-refresh workflow, and that is easy to get backwards.
# .github/workflows/provider-lock-refresh.yml rewrites `.terraform.lock.hcl`
# and never touches a `uses:` line, so this target's most useful audit would
# have nothing to read in its diff. Dependabot moves action pins; the lock
# refresh moves provider versions.
#
# Typing it by hand is still worth it in one place: on a branch, before the
# pull request exists, right after the pin was written. The job is the net
# under that rather than a replacement for it.
#
# Two things stand between this target and a pass it has not earned, and they
# are handled differently on purpose.
#
# The token is asserted, because a missing one cannot be constructed away.
# Finding none, zizmor falls back to offline and says so once at WARN level,
# which in a scrollback of INFO lines reads like noise: the target would print
# "No findings to report" having run none of the five audits it exists for.
#
# The mode is constructed, because it can be. `ZIZMOR_OFFLINE` and
# `ZIZMOR_NO_ONLINE_AUDITS` each force offline from the environment, and
# measured at v1.29.0 either one turns this target into a clean pass on a tree
# with a deliberately mismatched version comment — a token in hand and nothing
# looked at. A guard could test for them; unsetting them for the child cannot be
# got wrong, cannot go stale against whatever the next release reads, and is the
# same move `audit` above makes by passing `--offline` on the command line,
# where a flag beats the environment. The wrong state is not detected here, it
# is unrepresentable.
audit-online: check-zizmor ## Run zizmor's online audits too. Needs a GitHub token; never a gate.
	@if [ -z "$${GH_TOKEN:-}$${GITHUB_TOKEN:-}$${ZIZMOR_GITHUB_TOKEN:-}" ]; then \
		echo "make: audit-online needs a GitHub token and the environment has none." >&2; \
		echo "      Without one zizmor falls back to offline mode and reports a clean" >&2; \
		echo "      run having skipped every audit this target exists for." >&2; \
		echo "" >&2; \
		echo '        export GH_TOKEN="$$(gh auth token)"    # or a fine-grained PAT' >&2; \
		echo "" >&2; \
		echo "      make audit is the offline subset and needs no token." >&2; \
		exit 1; \
	fi
	env -u ZIZMOR_OFFLINE -u ZIZMOR_NO_ONLINE_AUDITS zizmor .

# ---------------------------------------------------------------------------
# The environment targets
# ---------------------------------------------------------------------------

# Everything above this line is a check and reaches no AWS account; everything
# below it talks to AWS. All but one of the checks above need no credentials and
# are safe to make a required status check — `audit-online` is the exception,
# and it is deliberately neither. They are separated rather than interleaved so
# that the boundary is visible in the file rather than remembered.
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

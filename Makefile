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
	verify-teardown \
	check-terraform check-tflint check-trivy check-terraform-docs check-zizmor \
	check-aws-cli \
	print-tflint-version print-trivy-version print-terraform-docs-version \
	print-zizmor-version

help: ## Show the available targets.
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*## " } { printf "  %-16s %s\n", $$1, $$2 }'
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

# And a fifth guard, for the AWS CLI, which `verify-teardown` at the bottom of
# this file is built on. It is the only one here that does not pin an exact
# version, and that deviation has to argue for itself rather than be noticed in
# review.
#
# The four guards above compare an exact number because in each case the tool
# *is* the specification. tflint, trivy and zizmor decide what counts as a
# finding and terraform-docs decides what a README says, so a different build
# gives a different answer about this repository, and a check run against an
# unpinned one answers a question nobody asked. The AWS CLI decides nothing of
# the sort: it carries a query to an API versioned by AWS rather than by the
# binary, and the answer is a fact about an account at a moment. Pinning it
# would fix the transport and not the answer, while making `verify-teardown`
# refuse to run on every CI runner and every workstation whose awscli formula
# has moved — a guard that fails for reasons unrelated to what it guards is a
# guard people learn to bypass.
#
# The major version is a different matter and is asserted, because that is the
# one boundary at which the answer really does change. v1 and v2 differ in
# output defaults, in whether pagination is automatic, and in how `--query` is
# applied to a paginated result — and every query in `verify-teardown` is
# written against v2. A v1 binary satisfies `command -v aws` and then returns
# something those queries misread, which is the specific shape this whole target
# exists to avoid: a clean-looking answer to a question that was not asked.
check-aws-cli:
	@if ! command -v aws >/dev/null 2>&1; then \
		echo "make: the AWS CLI was not found on PATH." >&2; \
		echo "      verify-teardown asks AWS what is standing in the account, so" >&2; \
		echo "      there is nothing it can do without one. Version 2 is required." >&2; \
		echo "      install it with:  brew install awscli" >&2; \
		echo "                   or:  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2; \
		exit 1; \
	fi; \
	out="$$(aws --version 2>&1)"; \
	actual="$${out#aws-cli/}"; \
	actual="$${actual%% *}"; \
	case "$$actual" in \
	2.*) ;; \
	*) \
		echo "make: the AWS CLI on PATH is not version 2." >&2; \
		echo "      expected 2.x  (the queries in verify-teardown are written against v2)" >&2; \
		echo "      found    $$actual  ($$(command -v aws))" >&2; \
		echo "      Unlike the four guards above this one does not pin a patch level," >&2; \
		echo "      because the CLI transports a query rather than deciding its answer." >&2; \
		echo "      The major version is asserted because v1 differs in output defaults," >&2; \
		echo "      pagination and --query handling, and would return a clean-looking" >&2; \
		echo "      answer to a query it read differently." >&2; \
		echo "      upgrade with:  brew install awscli" >&2; \
		exit 1; \
		;; \
	esac

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

# ---------------------------------------------------------------------------
# The post-destroy sweep
# ---------------------------------------------------------------------------

# docs/TEARDOWN.md section 6 as a target, because a checklist a human pastes is
# a checklist that drifts from the code it describes. It had already drifted
# when this was written: row 5, the CloudFront Function, reads "not measured —
# this resource postdates the walk-through", and the three commands in section
# 6.1 appear in no Makefile target and no workflow. Prose drifts in silence; a
# target drifts in a diff, where somebody has to approve it.
#
# What it is for. A destroy exiting 0 is a claim about a state file, and the
# resources most worth worrying about are the ones that leave state without
# leaving AWS. Four of the types this module creates —
# `aws_cloudfront_cache_policy`, `aws_cloudfront_response_headers_policy`,
# `aws_cloudfront_origin_access_control` and `aws_cloudfront_function` — expose
# no tags at all; the CloudFront API has nowhere to put them, and for the
# function AWS says so outright: "You can't add tags to edge functions". So the
# tag-based assertion e2e.yml makes at the end of a lifecycle run is
# structurally blind to a leak in any of them, and section 6.2 measures how
# blind: tags cover 6 of the module's 18 resources. What finds the rest is a
# sweep by name, which is this.
#
# ONE ACCOUNT-WIDE TARGET, NOT `verify-teardown-stage` AND `-prod`. That breaks
# the per-environment convention every other AWS-facing target in this file
# follows, so it is argued here rather than left to be noticed.
#
# The decisive reason is that a per-environment sweep has nothing to filter on.
# The origin access control and the CloudFront Function are both named
# `<name_prefix>-site-<env>-<8 hex>`, carrying the site bucket's `random_id`
# suffix, and after a destroy the state that knew that suffix is gone. The
# suffix is therefore unknowable, and the only expression that can find either
# resource is a prefix match on `<name_prefix>-site-`. That prefix is shared by
# every environment, so the sweep is account-wide whether or not its name admits
# it — and a `-stage` variant would either sweep the whole account under a name
# claiming otherwise, or narrow to `<name_prefix>-site-stage-` and look straight
# past a leak left by a root applied with the wrong environment constant.
#
# The second reason is that the account is the more useful question. The custom
# cache policy and response headers policy quotas are 20 per *account*, not per
# distribution, and this module burns 2 of each per environment. "Is this
# account clean" is what predicts the next apply failing on a quota error that
# names nothing about the leak that caused it. "Is stage clean" does not.
#
# WHERE `name_prefix` COMES FROM, which is the one input that can make this
# target lie. README.md names the failure directly: a wrong `project` or prefix
# makes a query match nothing, therefore report clean, over a live leak. So it
# is deliberately not an environment variable and not a `?=` override — an
# exported `NAME_PREFIX` left behind by another repository in the same shell is
# silently wrong in exactly that direction, and an override is at its worst on
# the day somebody is debugging and least likely to reread it.
#
# It is read out of `envs/*/terraform.tfvars` instead: the values the
# environments are actually applied with, tracked on purpose (`.gitignore`
# carries an explicit `!envs/*/terraform.tfvars` so a blanket rule cannot drop
# them), and present in a CI checkout with nothing passed in. `project` and
# `aws_region` come from the same files. The `Env` tag value comes from each
# environment root's `environment` local in main.tf rather than from its
# directory name, because the tag is what the query matches on and a prod root
# copied from stage keeping `environment = "stage"` is the mistake that file's
# own comment warns about — reading the directory name would paper over it.
#
# Those three values are per-account rather than per-environment, by the rule
# envs/*/variables.tf states and envs/prod/terraform.tfvars repeats, so the
# environments have to agree about them. This reads all of them and refuses if
# they disagree rather than picking one: two prefixes in the tree means half the
# account is not being swept, and a sweep that silently covers half an account
# is the thing this target exists to replace.
#
# WHAT IT CHECKS, against the eleven rows of section 6.
#
#   1  Distributions, matched on the module's naming and never counted to zero.
#      Section 6.3: `list-distributions` returns the whole account, and on the
#      account this was measured in it returned one distribution belonging to an
#      unrelated project. The match is on the `Comment` the module composes and
#      on the origin's domain name, either of which carries the bucket name.
#   2  Custom cache policies, and 3 custom response headers policies. `--type
#      custom` is not optional: without it AWS's managed policies come back as
#      well and the count is never zero. Two numbers are reported rather than
#      one — the policies matching this module's prefix, which are a leak and
#      fail this target, and the account's total against the quota of 20, which
#      is information and does not. In a shared account somebody else's custom
#      policy is not this repository's leak, but it does consume the quota that
#      makes the next apply fail, and that is worth printing rather than hiding.
#   4  Origin access controls and 5 CloudFront Functions, by prefix, for the
#      random-suffix reason above. No `--stage` filter on the functions, per
#      section 6.1: a leaked function exists in both stages, and a filter is one
#      more way for a sweep to look past the thing it is for.
#   6  Access log groups under /aws/vendedlogs/cloudfront/<name_prefix>-site-*,
#      in us-east-1 and not in the environment's region, because CloudFront's
#      logging control plane answers in us-east-1 whatever region the
#      environment uses.
#   7  Delivery sources, destinations and deliveries, in us-east-1 for the same
#      reason.
#   8  ACM certificates left PENDING_VALIDATION in us-east-1 — reported, and
#      deliberately not failing this target. Nothing here can attribute one: a
#      certificate is named by a domain the caller brings rather than by
#      `name_prefix`, so an unrelated pending certificate in the account is not
#      this repository's leak, and one this module did create is tagged, which
#      means row 10 below already fails on it. The other half of that row cannot
#      be checked at all: the DNS validation record lives in a hosted zone this
#      repository does not create and has no grant to read, so a stranded record
#      is outside every query here and stays a manual step. Section 7 — no
#      environment in this repository supplies a `domain_name`, so nothing on
#      this path has ever run.
#   9  Site buckets. Answered through the tag inventory below rather than by a
#      name sweep, and this is the one row served differently from the way
#      section 6 wrote it. After a destroy the bucket's random suffix is
#      unknowable exactly as the origin access control's is, and enumerating
#      buckets by prefix needs `s3:ListAllMyBuckets` — an account-wide action
#      the CI apply role deliberately does not hold, its S3 grant being `s3:*`
#      scoped to `<name_prefix>-site-*` and nothing broader. A site bucket is
#      taggable, and section 6.2 measured it as the single resource the
#      environment-region tag query returns, so a surviving one is precisely
#      what that query finds and names.
#
#      That substitution rests on the bucket being *tagged*, not merely
#      taggable, and on it carrying the value this target queries for — so the
#      thing that guarantees both is worth citing rather than trusting.
#      modules/static-site/tags.tf states the contract: every taggable resource
#      is tagged through the caller's provider `default_tags`, deliberately as
#      the only mechanism. tags.tf:47-51 reads `aws_default_tags` from both
#      provider configurations, the default one and the aliased `aws.us_east_1`
#      which inherits nothing from it, and tags.tf:76-77 rejects either that
#      carries an empty `Project` or an `Env` unequal to this module instance's
#      own environment. modules/static-site/logging.tf:106 is the precondition
#      that turns that into a failed plan. A site bucket that exists and is
#      invisible to the tag inventory therefore cannot reach apply.
#
#      The `Env` half is the load-bearing one here, and tags.tf:64-69 names why
#      in the same terms this row needs: the prod root comes into existence by
#      being copied from stage, so `Env = "stage"` on prod's resources is the
#      likely mistake rather than a missing key — and the consequence it states
#      is exactly this substitution's failure mode, "prod's teardown query
#      looks for `Env=prod` and finds nothing".
#
#      One thing that guard does not cover, stated because a citation is only
#      worth having if it is exact. tags.tf:61-63 checks that a `Project`
#      choice was made, not what it was, the value being the caller's to pick.
#      So `project` edited in `envs/*/terraform.tfvars` between an apply and a
#      later sweep leaves the bucket carrying the old value while this target
#      queries the new one, and row 10 reports clean over a bucket that is
#      standing. `Env` is not in that category: it fails the plan. That
#      remaining gap is the same one the name_prefix argument above is written
#      against, and the reason `project` is read from those files rather than
#      from an overridable variable — the value queried with is at least the
#      one the tree declares, and it moves only in a diff somebody approves.
#  10  The tag inventory, for `Project` and `Env`, in BOTH the environment's own
#      region and us-east-1. Section 6.2 measured why: the environment's region
#      returns 1 resource while 5 live us-east-1 resources sit outside it, so a
#      single-region query reports success over surviving resources.
#  11  A stranded `.tflock` beside the state, section 5.2. The state bucket
#      carries a per-account random suffix, so its name is not in the tree: it
#      comes from `TF_STATE_BUCKET` when that is set, which is the variable
#      apply.yml and e2e.yml already pass to `-backend-config`, and otherwise
#      from `envs/*/backend.hcl`. Finding neither is reported as a check that
#      could not run, never as one that passed.
#
# One resource is on none of those rows on purpose:
# `<name_prefix>-app-deploy-boundary`, the managed policy the app deploy role
# carries as its permissions boundary. It outlives every environment by design
# and comes down with the bootstrap in section 8, so finding it standing while
# this runs is the expected result rather than a leak.
#
# WHAT A PASS PROVES, AND WHAT IT DOES NOT. It proves that nothing matching this
# module's naming is standing in this account at the moment it ran. That is the
# whole of it, and the closing message says that rather than "clean", because
# two gaps are structural rather than something this target can close:
#
#   - It only finds what it was told to look for. Every check is a query written
#     by hand against a resource type the module creates today. A type added to
#     the module tomorrow is covered by nothing here until a check is added
#     beside the others, and it will not go missing loudly — it will simply
#     never be mentioned, and this target will report a pass having asserted
#     nothing about it. That is the failure `validate` and `test` above each
#     grew a second pass to prevent, and no equivalent second pass is available
#     here: nothing outside Terraform can enumerate the resource types this
#     module creates.
#   - Every check is scoped to the `name_prefix` this tree declares today. A
#     leak from a cycle run under some other prefix — an earlier value, a
#     colleague's clone of this repository — is invisible to all of it.
#
# THREE OUTCOMES, AND HOW A CALLER TELLS THEM APART — which is not by the exit
# code, and that is the whole of this paragraph. "Found something" and "could not
# look" are different answers, and collapsing them is how a sweep starts
# reporting success over a network error, so the recipe distinguishes them:
#
#   0  every check ran, and none of them found anything.
#   1  at least one check found a resource matching this module's naming.
#   2  at least one check could not run — no credentials, an AWS call that
#      failed, a list the API truncated, an input this target refuses to guess
#      at. Nothing was disproved there; it was not asked.
#
# 1 wins when both happen, a leak being the more actionable of the two.
#
# GNU Make then throws two of those three away, which is the kind of thing that
# is cheap to write down here and expensive to discover in a workflow. Make does
# not propagate a recipe's status: a recipe that fails at all is reported as its
# own `Error N` and make itself exits 2 — measured on the 3.81 that ships with
# macOS and documented identically for 4.x, which is what every job in
# .github/workflows/ runs. So `make verify-teardown` exits 0 for clean and 2 for
# *both* of the others, and a caller reading `$?` cannot tell a leak from an
# expired session. That is exactly the distinction the two codes
# exist for, so the recipe also prints it, as the last line of stdout, on every
# path — including the refusals that happen before the first AWS call:
#
#   verify-teardown-result: clean
#   verify-teardown-result: leak
#   verify-teardown-result: incomplete
#
# That line is the contract for anything reading this target's output. A caller
# branches on it — `make verify-teardown | tail -1` — rather than on the exit
# status, and the workflow step that eventually wires this into e2e.yml is meant
# to do the same. The numeric codes remain for anyone running the recipe's shell
# directly, and are what the `set -e` semantics inside it are written against.
#
# CI-READY WITH NO NEW GRANT, which is a property to preserve rather than a
# plan. Wiring this into e2e.yml and apply.yml is a separate change; what
# matters here is that it can be. Every call below is already allowed to the CI
# apply role by bootstrap/oidc.tf — the five CloudFront list actions
# (ListDistributions, ListCachePolicies, ListResponseHeadersPolicies,
# ListOriginAccessControls, ListFunctions), logs:DescribeLogGroups,
# logs:DescribeDeliverySources, logs:DescribeDeliveryDestinations,
# logs:DescribeDeliveries, acm:ListCertificates, tag:GetResources, and
# s3:ListBucket on the state bucket. The preflight is `sts:GetCallerIdentity`,
# which no policy has to grant: AWS documents it as requiring no permissions,
# and it is what turns an expired session into one sentence rather than a
# traceback per check. A check added here that needs an action outside that set
# is a change to bootstrap/oidc.tf, and should arrive as one rather than be
# discovered as an AccessDenied in a workflow.
#
# TRUNCATION, which is the last way this sweep could have reported clean over a
# leak, and the reason three of the queries below look stranger than the rest.
#
# The CLI paginates for you only where botocore ships a paginator for the
# operation. Checked against the paginator definitions in awscli 2.36.29 rather
# than assumed: `ListDistributions` and `ListOriginAccessControls` have one, and
# so do every logs, ACM, tagging and S3 call here — but `ListCachePolicies`,
# `ListResponseHeadersPolicies` and `ListFunctions` do not. For those three the
# CLI makes exactly one call, takes the API's default `MaxItems` of 100, and
# neither follows nor mentions the `NextMarker` that comes back. A truncated
# list would be read as the whole list.
#
# For the two policy types the 20-per-account quota puts 100 out of reach. For
# functions it does not: that quota is 100, so an account at its function limit
# is exactly the account whose leaked function falls off the end of the page —
# and the CloudFront Function is already the resource with no other detector,
# being untaggable and colliding with nothing on the next apply.
#
# So those three queries ask for the marker as well as the names, in the same
# call rather than a second one, by prepending a `!TRUNCATED!` element when
# `NextMarker` is set: `[X.NextMarker && '!TRUNCATED!', X.Items[…]] | []`. The
# `&&` yields the one-element list only when the marker is truthy, and the
# trailing flatten merges it into the names. The recipe treats that sentinel as
# could-not-look rather than as clean, which is the honest answer — it is not
# pagination, it is a refusal to call a page an answer. The sentinel cannot
# collide with a finding: CloudFront restricts these names to letters, digits,
# underscores and hyphens, and `!` is none of those.
#
# Five details of the recipe worth knowing before editing it. Every query asks
# for `--output text` and is judged by whether it printed anything rather than
# by a count, so a finding names the resource: a count tells you to go and look,
# a name tells you what to look at. The distribution check has no name to print
# — a distribution has an opaque `E…` id — so it prints the id joined to its
# origin's domain name, which carries the site bucket, and both halves are
# wrapped in `not_null` because a distribution with no origin or no comment
# would otherwise fail the whole query with a JMESPath type error rather than
# not matching.
#
# The CLI prints the literal `None` for a JMESPath expression that resolved to
# null, which is what an empty CloudFront list does — the API omits `Items`
# entirely rather than returning `[]` — so that string is stripped, and
# stripping it is this target's equivalent of the ``|| `[]` `` guard the
# commands in section 6.1 carry. Nothing this sweep can match is named `None`,
# because every filter requires the `<name_prefix>-site-` prefix.
#
# Each call's stderr goes to a file rather than to stdout, so that nothing the
# CLI writes there can be read back as a resource name. That file is printed
# only when the call failed, and is overwritten by the next call otherwise: a
# warning from a call that succeeded is discarded, not reported. Discarding it
# is the intended trade — the alternative is a sweep that treats CLI chatter as
# a finding — but it is a discard rather than a report, and the difference is
# worth knowing before trusting silence here.
#
# One call deliberately does not do that. The `sts:GetCallerIdentity` preflight
# leaves its stderr attached to the terminal, because a profile configured with
# an MFA serial prompts for a token code there and reads the answer from the
# tty: with stderr captured, that prompt is invisible and the target looks hung
# on the one account this repository is developed against. By the time the
# checks run the session exists and is cached, so a prompt cannot appear in the
# middle of them.
#
# And the two policy checks are the only ones that filter in the shell rather
# than in JMESPath, because one call has to answer two questions — which
# policies are this module's, and how many exist in total — and asking twice
# would let the two answers describe different moments. That filter is anchored,
# `^` and not a substring, to match the `starts_with()` every other check uses;
# the prefix is safe to use as an expression because
# modules/static-site/variables.tf already constrains `name_prefix` to
# lower-case letters, digits and hyphens, none of which mean anything to a basic
# regular expression.
verify-teardown: check-aws-cli ## Sweep the account for anything this module named that survived a destroy.
	@finish() { printf 'verify-teardown-result: %s\n' "$$1"; exit "$$2"; }; \
	tfvars_list="$$(find envs -mindepth 2 -maxdepth 2 -type f -name terraform.tfvars | sort || true)"; \
	if [ -z "$$tfvars_list" ]; then \
		echo "make: verify-teardown found no envs/*/terraform.tfvars to read." >&2; \
		echo "      Every query it makes is scoped by name_prefix, and a query built" >&2; \
		echo "      from an empty prefix matches nothing — which this target would" >&2; \
		echo "      then report as a clean account. Refusing instead." >&2; \
		finish incomplete 2; \
	fi; \
	tfvars=(); \
	while IFS= read -r file; do tfvars+=("$$file"); done <<< "$$tfvars_list"; \
	lines() { printf '%s\n' "$$1" | grep -c . || true; }; \
	TFVAR=""; \
	read_tfvar() { \
		local name="$$1" values count; \
		values="$$(sed -n "s/^[[:space:]]*$${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$${tfvars[@]}" | sort -u || true)"; \
		count="$$(lines "$$values")"; \
		if [ "$$count" -eq 0 ]; then \
			echo "make: no environment declares $${name}, so verify-teardown has nothing" >&2; \
			echo "      to match on and every query below would match everything or" >&2; \
			echo "      nothing. Looked in:" >&2; \
			printf '        %s\n' "$${tfvars[@]}" >&2; \
			finish incomplete 2; \
		fi; \
		if [ "$$count" -gt 1 ]; then \
			echo "make: the environments disagree about $${name}:" >&2; \
			printf '%s\n' "$$values" | sed 's/^/        /' >&2; \
			echo "      This value is per-account rather than per-environment — see the" >&2; \
			echo "      comment at the top of envs/prod/terraform.tfvars. Refusing rather" >&2; \
			echo "      than picking one and sweeping for part of the account." >&2; \
			finish incomplete 2; \
		fi; \
		TFVAR="$$values"; \
	}; \
	read_tfvar name_prefix; name_prefix="$$TFVAR"; \
	read_tfvar project; project="$$TFVAR"; \
	read_tfvar aws_region; env_region="$$TFVAR"; \
	site="$${name_prefix}-site-"; \
	environments=(); \
	while IFS= read -r file; do \
		dir="$$(dirname "$$file")"; \
		value="$$(sed -n 's/^[[:space:]]*environment[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$$dir/main.tf" | sort -u || true)"; \
		if [ "$$(lines "$$value")" -ne 1 ]; then \
			echo "make: could not read one environment name out of $$dir/main.tf." >&2; \
			echo "      sed's own message, if any, is immediately above this one." >&2; \
			echo "      The Env tag the inventory query filters on comes from the" >&2; \
			echo "      \`environment\` local there, not from the directory name, so a" >&2; \
			echo "      guess here would query a tag nothing carries and report clean." >&2; \
			finish incomplete 2; \
		fi; \
		environments+=("$$value"); \
	done <<< "$$tfvars_list"; \
	state_bucket="$${TF_STATE_BUCKET:-}"; \
	if [ -z "$$state_bucket" ]; then \
		backend_list="$$(find envs -mindepth 2 -maxdepth 2 -type f -name backend.hcl | sort || true)"; \
		if [ -n "$$backend_list" ]; then \
			backends=(); \
			while IFS= read -r file; do backends+=("$$file"); done <<< "$$backend_list"; \
			state_bucket="$$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$${backends[@]}" | sort -u || true)"; \
		fi; \
	fi; \
	state_region="$${TF_STATE_REGION:-$$env_region}"; \
	dirty=0; \
	incomplete=0; \
	if ! errfile="$$(mktemp)"; then \
		echo "make: verify-teardown could not create a temporary file for stderr." >&2; \
		finish incomplete 2; \
	fi; \
	trap 'rm -f "$$errfile"' EXIT; \
	QUERY_RESULT=""; \
	QUERY_TRUNCATED=0; \
	aws_query() { \
		local label="$$1" raw; \
		shift; \
		QUERY_TRUNCATED=0; \
		if ! raw="$$("$$@" 2>"$$errfile")"; then \
			{ printf '??    %s\n' "$$label"; \
			  printf '      the AWS call failed, so this check proved nothing:\n'; \
			  sed 's/^/        /' "$$errfile"; } >&2; \
			incomplete=1; \
			return 1; \
		fi; \
		QUERY_RESULT="$$(printf '%s' "$$raw" | tr -s '[:space:]' '\n' | sed -e '/^None$$/d' -e '/^$$/d')"; \
		if printf '%s\n' "$$QUERY_RESULT" | grep -qxF '!TRUNCATED!'; then \
			QUERY_TRUNCATED=1; \
			incomplete=1; \
			QUERY_RESULT="$$(printf '%s\n' "$$QUERY_RESULT" | grep -vxF '!TRUNCATED!' || true)"; \
		fi; \
		return 0; \
	}; \
	report() { \
		if [ -n "$$QUERY_RESULT" ]; then \
			printf 'LEAK  %s:\n' "$$1"; \
			printf '%s\n' "$$QUERY_RESULT" | sed 's/^/        /'; \
			dirty=1; \
		elif [ "$$QUERY_TRUNCATED" -eq 0 ]; then \
			printf 'ok    %s: nothing\n' "$$1"; \
		fi; \
		if [ "$$QUERY_TRUNCATED" -ne 0 ]; then \
			{ printf '??    %s: the API truncated this list, so what came back is a\n' "$$1"; \
			  printf '      page and not the answer. This operation has no paginator in\n'; \
			  printf '      the CLI, so nothing follows the NextMarker it returned.\n'; \
			  printf '      Counting it as could-not-look rather than as clean.\n'; } >&2; \
		fi; \
	}; \
	sweep() { \
		local label="$$1"; \
		shift; \
		aws_query "$$label" "$$@" || return 0; \
		report "$$label"; \
	}; \
	policy_sweep() { \
		local label="$$1" subcommand="$$2" query="$$3" all total; \
		aws_query "$$label" aws cloudfront "$$subcommand" --region us-east-1 --type custom --output text --query "$$query" || return 0; \
		all="$$QUERY_RESULT"; \
		total="$$(lines "$$all")"; \
		QUERY_RESULT="$$(printf '%s\n' "$$all" | grep -e "^$$site" || true)"; \
		report "$$label"; \
		if [ "$$QUERY_TRUNCATED" -ne 0 ]; then \
			printf '      at least %s of the 20-per-account quota in use — the list was cut short\n' "$$total"; \
		else \
			printf '      %s of the 20-per-account quota in use, by everything in the account\n' "$$total"; \
		fi; \
	}; \
	if ! caller="$$(aws sts get-caller-identity --region us-east-1 --query '[Account,Arn]' --output text)"; then \
		echo "" >&2; \
		echo "make: verify-teardown has no usable AWS credentials." >&2; \
		echo "      The CLI's own message is immediately above this one." >&2; \
		echo "" >&2; \
		echo "      It asks AWS what is standing in the account, so there is no" >&2; \
		echo "      degraded answer it can give here. Authenticate and re-run — a" >&2; \
		echo "      profile is enough for the CLI, unlike the terraform targets above:" >&2; \
		echo "" >&2; \
		echo '        export AWS_PROFILE=<profile>   # or aws sso login --profile <profile>' >&2; \
		finish incomplete 2; \
	fi; \
	printf 'account:     %s\n' "$$(printf '%s' "$$caller" | cut -f1)"; \
	printf 'caller:      %s\n' "$$(printf '%s' "$$caller" | cut -f2)"; \
	printf 'name_prefix: %s   (read from envs/*/terraform.tfvars)\n' "$$name_prefix"; \
	printf 'matching:    %s*\n' "$$site"; \
	printf 'regions:     %s and us-east-1\n' "$$env_region"; \
	printf '\n'; \
	sweep "CloudFront distributions matching $${site}* (id|origin)" \
		aws cloudfront list-distributions --region us-east-1 --output text \
		--query "DistributionList.Items[?contains(not_null(Comment, ''), '$${site}') || contains(not_null(Origins.Items[0].DomainName, ''), '$${site}')].join('|', [Id, not_null(Origins.Items[0].DomainName, 'no-origin')])"; \
	policy_sweep "custom cache policies" list-cache-policies \
		"[CachePolicyList.NextMarker && '!TRUNCATED!', CachePolicyList.Items[].CachePolicy.CachePolicyConfig.Name] | []"; \
	policy_sweep "custom response headers policies" list-response-headers-policies \
		"[ResponseHeadersPolicyList.NextMarker && '!TRUNCATED!', ResponseHeadersPolicyList.Items[].ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name] | []"; \
	sweep "origin access controls" \
		aws cloudfront list-origin-access-controls --region us-east-1 --output text \
		--query "OriginAccessControlList.Items[?starts_with(Name, '$${site}')].Name"; \
	sweep "CloudFront Functions" \
		aws cloudfront list-functions --region us-east-1 --output text \
		--query "[FunctionList.NextMarker && '!TRUNCATED!', FunctionList.Items[?starts_with(Name, '$${site}')].Name] | []"; \
	sweep "access log groups (us-east-1)" \
		aws logs describe-log-groups --region us-east-1 --output text \
		--log-group-name-prefix "/aws/vendedlogs/cloudfront/$${site}" \
		--query 'logGroups[].logGroupName'; \
	sweep "delivery sources (us-east-1)" \
		aws logs describe-delivery-sources --region us-east-1 --output text \
		--query "deliverySources[?starts_with(name, '$${site}')].name"; \
	sweep "delivery destinations (us-east-1)" \
		aws logs describe-delivery-destinations --region us-east-1 --output text \
		--query "deliveryDestinations[?starts_with(name, '$${site}')].name"; \
	sweep "deliveries (us-east-1)" \
		aws logs describe-deliveries --region us-east-1 --output text \
		--query "deliveries[?starts_with(deliverySourceName, '$${site}')].id"; \
	if aws_query "ACM certificates awaiting validation (us-east-1)" \
		aws acm list-certificates --region us-east-1 --output text \
		--certificate-statuses PENDING_VALIDATION \
		--query 'CertificateSummaryList[].DomainName'; then \
		if [ -z "$$QUERY_RESULT" ]; then \
			printf 'ok    ACM certificates awaiting validation (us-east-1): nothing\n'; \
		else \
			printf 'note  ACM certificates awaiting validation (us-east-1):\n'; \
			printf '%s\n' "$$QUERY_RESULT" | sed 's/^/        /'; \
			printf '      Reported, not counted as a leak: a certificate is named by a\n'; \
			printf '      domain rather than by name_prefix, so nothing here can say\n'; \
			printf '      whose it is. One this module created carries tags and would\n'; \
			printf '      fail the inventory below. Its validation record lives in a\n'; \
			printf '      hosted zone this repository neither creates nor can read.\n'; \
		fi; \
	fi; \
	regions=("$$env_region"); \
	[ "$$env_region" = "us-east-1" ] || regions+=("us-east-1"); \
	for environment in "$${environments[@]}"; do \
		for region in "$${regions[@]}"; do \
			sweep "tagged Project=$${project} Env=$${environment} in $${region}" \
				aws resourcegroupstaggingapi get-resources --region "$$region" --output text \
				--tag-filters "Key=Project,Values=$${project}" "Key=Env,Values=$${environment}" \
				--query 'ResourceTagMappingList[].ResourceARN'; \
		done; \
	done; \
	if [ "$$(lines "$$state_bucket")" -ne 1 ]; then \
		echo "??    stranded .tflock: no single state bucket to look in." >&2; \
		echo "      The bucket carries a per-account random suffix, so its name is" >&2; \
		echo "      not in the tree. Set TF_STATE_BUCKET, or create the gitignored" >&2; \
		echo "      envs/<env>/backend.hcl from the example beside it. Section 5.2 of" >&2; \
		echo "      docs/TEARDOWN.md is the check this skipped." >&2; \
		incomplete=1; \
	else \
		sweep "stranded .tflock objects in $${state_bucket}" \
			aws s3api list-objects-v2 --region "$$state_region" --bucket "$$state_bucket" \
			--output text --query "Contents[?ends_with(Key, '.tflock')].Key"; \
	fi; \
	printf '\n'; \
	if [ "$$dirty" -ne 0 ]; then \
		echo "make: verify-teardown found resources matching this module's naming." >&2; \
		echo "      Each is listed above by name. Match it against the module's" >&2; \
		echo "      naming before removing anything by hand — section 6.3 of" >&2; \
		echo "      docs/TEARDOWN.md: this account may hold resources this" >&2; \
		echo "      repository did not create." >&2; \
		finish leak 1; \
	fi; \
	if [ "$$incomplete" -ne 0 ]; then \
		echo "make: verify-teardown could not run every check, so it is not saying" >&2; \
		echo "      the account is clean — it is saying it did not finish asking." >&2; \
		echo "      Each unfinished check is marked '??' above with the reason." >&2; \
		finish incomplete 2; \
	fi; \
	echo "verify-teardown: nothing matching $${site}* is standing in this account right now,"; \
	echo "                 and no resource carries Project=$${project} with any of this"; \
	echo "                 repository's Env values, in $${env_region} or us-east-1."; \
	echo ""; \
	echo "                 That is what this establishes and the whole of it. It looked"; \
	echo "                 for the resource types this module creates today, under the"; \
	echo "                 name_prefix this tree declares today. A type the module gains"; \
	echo "                 later needs a check added here, and a leak from a cycle run"; \
	echo "                 under a different prefix is outside every query above."; \
	echo ""; \
	finish clean 0

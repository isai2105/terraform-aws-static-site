# TFLint — the static checks `terraform validate` cannot make.
#
# `terraform validate` only answers whether a configuration is well-formed and
# internally consistent. It has no opinion on deprecated syntax, on an instance
# type that does not exist, on a variable nobody reads, or on a resource named
# in the wrong case. That is what this file is for.
#
# Nothing configured here contacts AWS. The AWS ruleset's deep-check rules —
# the ones that resolve real ARNs, AMIs and IAM policies through the API — are
# off by default and are deliberately left off, so this gate needs no account,
# no role and no credentials. That is what lets it land before the code it
# lints rather than after it.

# The bundled Terraform-language ruleset. `recommended` is the preset upstream
# maintains, and it carries the deprecated-syntax and unused-declaration rules
# this repository wants. Hand-listing rule names instead would freeze that set
# at whatever today's opinion happens to be.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Naming conventions are not part of `recommended`, and this repository wants
# them: snake_case for every named block, enforced from the first module
# onward rather than retrofitted once the names are load-bearing.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# The AWS ruleset, pinned to an exact release. `version` is an exact match in
# TFLint rather than a constraint, so a new upstream release cannot change
# what these checks mean without a commit that says so.
plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

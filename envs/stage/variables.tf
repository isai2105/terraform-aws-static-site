# Inputs to the stage environment root.
#
# There is exactly one rule deciding what belongs here, and it is worth stating
# because it is what keeps `envs/stage` and `envs/prod` from drifting into two
# unrelated configurations: **a value is a variable here only if it differs
# between accounts, never if it differs between environments.**
#
# Per-account values — the region, the bucket prefix, the tag identity — are
# what a cloner edits in terraform.tfvars to run this in their own account, and
# they are identical across every environment in a given clone.
#
# Per-environment values are not variables at all. The environment name is the
# clearest case and it is a local constant in main.tf, not an input, for the
# reason the bootstrap gives about its own `Env` tag: `envs/stage` has exactly
# one correct value for it, and exposing it as an input would let
# `-var environment=prod` create prod-named resources under stage's state key,
# with the CI apply role's environment-scoped trust none the wiser.
#
# Nothing here is sensitive — no account id, no ARN, no key — which is the
# property that lets terraform.tfvars be committed at all. Everything sensitive
# arrives through OIDC at runtime.

variable "aws_region" {
  description = "AWS region this environment deploys into. Must be the region the bootstrap's state bucket was created in, since that is where this root reads and writes its state."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "The aws_region must look like an AWS region code, for example \"us-east-2\" or \"eu-west-1\"."
  }
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for the site bucket name, which the module composes as
    "<name_prefix>-site-<environment>-<8 hex characters>".

    This must be the same value the bootstrap root was applied with. The CI
    apply role's S3 grant is scoped to "<name_prefix>-site-*" and deliberately
    kept disjoint from the state bucket's "<name_prefix>-tfstate-<hex>", so a
    bucket named outside that pattern cannot be created by CI at all — the
    failure is an AccessDenied during apply that names the bucket and not this
    variable.
  EOT
  type        = string

  # The module validates this value too, and the repetition is deliberate rather
  # than redundant: this check fails naming `envs/stage/terraform.tfvars`, which
  # is the file that has to change, while the module's fails naming a module
  # input two directories away.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "The name_prefix must be lower case letters, digits and hyphens, and must start and end with a letter or digit."
  }
}

variable "project" {
  description = "Value of the Project tag applied to every resource in this environment. The end-to-end teardown assertion queries the resource groups tagging API on this tag together with Env, so it has to identify this deployment rather than a whole account."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._:/=+@-]*$", var.project))
    error_message = "The project must be a non-empty string of characters valid in an AWS tag value."
  }
}

variable "github_owner" {
  description = "GitHub user or organisation that owns this repository. Tagged as Owner, and half of the Repo tag."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](-?[A-Za-z0-9])*$", var.github_owner)) && length(var.github_owner) <= 39
    error_message = "The github_owner must be a valid GitHub account name: alphanumerics separated by single hyphens, 39 characters or fewer."
  }
}

variable "github_repository" {
  description = "Name of this repository within github_owner. Tagged, with the owner, as Repo."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repository)) && length(var.github_repository) <= 100
    error_message = "The github_repository must be a valid GitHub repository name: letters, digits, dots, hyphens and underscores, 100 characters or fewer."
  }
}

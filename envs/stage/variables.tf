# Inputs to the stage environment root.
#
# There is exactly one rule deciding what belongs here, and it is worth stating
# because it is what keeps `envs/stage` and `envs/prod` from drifting into two
# unrelated configurations: **a value is a variable here only if it differs
# between accounts, never if it differs between environments.**
#
# Per-account values — the region, the bucket prefix, the tag identity, the app
# repository's numeric ids and the name of the boundary the bootstrap created —
# are what a cloner edits in terraform.tfvars to run this in their own account,
# and they are identical across every environment in a given clone.
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

# ---------------------------------------------------------------------------
# The app repository, and the boundary its deploy role must carry
# ---------------------------------------------------------------------------
#
# Four values describing things this repository does not own: a GitHub
# repository in someone's account, and a policy the bootstrap root created.
# All four are per-account by the rule above — a cloner's fork of the app
# repository has different ids, and the boundary carries their own prefix — and
# none of them is per-environment, which is why stage and prod declare the same
# four and pass them to the same module argument.
#
# They are inputs rather than literals in main.tf for the reason every value in
# this file is: a literal in main.tf is a literal in the twin as well, and two
# copies of an account-specific string are two chances for the pair to disagree
# after somebody edits one of them.

variable "app_github_owner" {
  description = <<-EOT
    GitHub user or organisation that owns the app repository — the one that
    deploys into this environment, not this one. Part of the OIDC subject the
    module's deploy role trusts.

    Separate from github_owner above even though the two hold the same string
    today. That one names the owner of *this* repository and feeds the Owner and
    Repo tags; nothing requires the two repositories to share an owner, and
    wiring the trust policy to the tag value would mean transferring this
    repository to an organisation silently rewrote a trust policy in another one.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](-?[A-Za-z0-9])*$", var.app_github_owner)) && length(var.app_github_owner) <= 39
    error_message = "The app_github_owner must be a valid GitHub account name: alphanumerics separated by single hyphens, 39 characters or fewer."
  }
}

variable "app_github_owner_id" {
  description = "Numeric id of the GitHub account in app_github_owner. Embedded in the OIDC subject the deploy role trusts, in GitHub's immutable subject format, and not interchangeable with the account name."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.app_github_owner_id))
    error_message = "The app_github_owner_id must be the numeric account id, digits only. Read it with: gh api repos/<owner>/react-cloudfront-app --jq .owner.id"
  }
}

variable "app_github_repository_id" {
  description = "Numeric id of the app repository. Embedded in the OIDC subject the deploy role trusts, alongside the repository name the module holds as a constant because the bootstrap grant is scoped to it."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.app_github_repository_id))
    error_message = "The app_github_repository_id must be the numeric repository id, digits only. Read it with: gh api repos/<owner>/react-cloudfront-app --jq .id"
  }
}

variable "app_deploy_boundary_policy_name" {
  description = <<-EOT
    Name of the permissions boundary the deploy role must carry, read from the
    bootstrap root's app_deploy_boundary_policy_name output.

    The name and not the ARN, because this file is committed and a policy ARN
    embeds the account id. The module composes the ARN from the partition, the
    account id and this name, and it must match the bootstrap's character for
    character: the apply roles condition iam:CreateRole on that exact ARN, so a
    mismatch is an AccessDenied at apply rather than an error in any plan.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.app_deploy_boundary_policy_name))
    error_message = "The app_deploy_boundary_policy_name must be a valid IAM policy name: letters, digits and the characters +=,.@_- , 128 characters or fewer. It is the policy's name, not its ARN and not a path."
  }
}

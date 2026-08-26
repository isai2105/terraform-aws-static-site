# Inputs to the bootstrap root.
#
# Nothing here carries a default that encodes an environment-specific choice.
# A default is a decision made silently, and the values below are exactly the
# ones that differ between the account this was written in and the account a
# cloner runs it in — which makes a default the fastest route to a stranger
# creating resources under someone else's naming scheme without noticing.
#
# The values live in the committed `terraform.tfvars` beside this file. None of
# them is sensitive: no account id, no ARN, no key. That is a property worth
# preserving, because it is what lets the file be committed at all.

variable "aws_region" {
  description = "AWS region the state bucket is created in. The consuming roots read their state from this same region."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "The aws_region must look like an AWS region code, for example \"us-east-2\" or \"eu-west-1\"."
  }
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for the globally unique state bucket name, which is composed as
    "<name_prefix>-tfstate-<8 hex characters>". S3 bucket names share one global
    namespace across every AWS account, so this has to be something a stranger
    is unlikely to have taken — an organisation or account handle works well.
  EOT
  type        = string

  # Two validations rather than one, because they fail for unrelated reasons
  # and a reader fixing the second should not have to re-read the first.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "The name_prefix must be lower case letters, digits and hyphens, and must start and end with a letter or digit. Dots are excluded deliberately: they break virtual-hosted-style TLS against the bucket."
  }

  # 63 is the S3 bucket name limit and "-tfstate-" plus eight hex characters
  # consumes 17 of it. Catching this here costs a plan; catching it at apply
  # costs a round trip to an InvalidBucketName that names no variable.
  validation {
    condition     = length(var.name_prefix) >= 3 && length(var.name_prefix) <= 46
    error_message = "The name_prefix must be between 3 and 46 characters, so that the composed bucket name stays within the 63-character S3 limit."
  }
}

variable "project" {
  description = "Value of the Project tag applied to everything this repository creates. The end-to-end teardown check queries resources by this tag, so it has to identify this deployment and not a whole account."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._:/=+@-]*$", var.project))
    error_message = "The project must be a non-empty string of characters valid in an AWS tag value."
  }
}

variable "github_owner" {
  description = "GitHub user or organisation that owns this repository. Tagged as Owner; the CI trust policies added alongside this root consume it as well."
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

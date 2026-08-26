# The provider for the bootstrap root, and the tag set every root in this
# repository applies.
#
# The tags are not decoration. `Project` and `Env` are what the end-to-end
# workflow's teardown assertion queries through the resource groups tagging
# API to prove that a destroy left nothing behind, so a resource that escapes
# these tags is a resource that check cannot see.

locals {
  # Co-located with `default_tags`, its only consumer, rather than collected
  # into a locals.tf that would put it a file away from the thing it feeds.
  tags = {
    Project = var.project

    # A constant, not a variable. This root is the bootstrap layer — there is
    # no other value it could correctly take, and exposing it as an input
    # would invite someone to label the shared state bucket "prod".
    Env = "bootstrap"

    Owner     = var.github_owner
    Repo      = "${var.github_owner}/${var.github_repository}"
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

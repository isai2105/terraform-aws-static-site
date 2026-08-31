# The two provider configurations this environment gives the module, and the
# tag set both of them carry.
#
# Two configurations rather than one, and neither is optional. CloudFront is a
# global service whose standard logging (v2) control plane answers only in
# us-east-1, so the module declares `configuration_aliases = [aws.us_east_1]`
# and places its delivery source, delivery destination, delivery and log group
# through the alias — as well as the ACM certificate, on the optional custom
# domain path, for the same us-east-1-only reason. A root that passed only the
# default provider would not fail with a missing argument; it would fail at
# apply on resources whose configuration looks entirely correct.

locals {
  # The tag set, declared once and given to *both* provider configurations
  # below. That is the whole point of a local here rather than two literal
  # blocks: `default_tags` is a block inside a single provider configuration,
  # and an aliased provider inherits nothing from the default one, so two
  # literals are two chances to drift and only one of them is ever exercised by
  # a smoke test.
  #
  # This is not a hypothetical. Getting it wrong produces a working distribution
  # and four completely untagged CloudWatch Logs resources — no error, no
  # warning, nothing in the plan that reads as wrong — and the end-to-end
  # workflow proves a teardown left nothing behind by asking the resource groups
  # tagging API for everything carrying Project and Env. An untagged orphan is
  # invisible to that query, so the assertion cannot tell "nothing survived"
  # from "something survived without tags", and a stranded log group is on the
  # post-destroy checklist. The module checks for this at plan time rather than
  # trusting it; this is the shape that passes.
  tags = {
    Project = var.project

    # Sourced from the same constant the module is given, never written out a
    # second time. The module's precondition requires this tag to equal its own
    # `environment` input, and the likeliest way to break that is a prod root
    # copied from this one keeping `Env = "stage"` — which is precisely the
    # mistake a second literal would let through and a shared reference cannot.
    Env = local.environment

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

# Required by the module in every region, always — see the note at the top of
# this file. Its region is a literal rather than a variable because there is no
# other value it could take: this is not "a second region this deployment uses",
# it is the one region CloudFront's control plane answers in.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  # The half that is easy to leave out, and silent when it is. See the local
  # above for what it costs.
  default_tags {
    tags = local.tags
  }
}

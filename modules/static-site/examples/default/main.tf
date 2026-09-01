# The smallest configuration that calls the static-site module correctly.
#
# It exists for two reasons, and the second is the load-bearing one:
#
#   1. It is the worked example the module's README refers to — how the two
#      providers are wired, and which inputs have no default.
#   2. It is what gives `make validate` something to validate. The module
#      declares `configuration_aliases`, so it takes provider configurations
#      from its caller and cannot be initialised as a root on its own; a root
#      that calls it is the only way `terraform validate` ever type-checks its
#      resources. Until envs/ exists, this is that root.
#
# It is an example rather than a deployment: no backend, no committed variable
# values beyond the literals below, and nothing in this repository ever applies
# it. Every one of those literals is there because the input it feeds has no
# default — that is what this root is for.
#
# Its lock file is committed and pinned to the same provider version the
# bootstrap is locked to, deliberately rather than to whatever was newest when
# this root was first initialised. A repository that pins the CLI to an exact
# patch so that local and CI run the same binary has no business running two
# provider versions in two roots, and a module commit is not where a provider
# gets bumped — that is what
# .github/workflows/provider-lock-refresh.yml exists for, so that the bump is a
# reviewed change of its own rather than a side effect of unrelated work. This
# root is one of the five directories that workflow discovers, and it is
# discovered by having the committed lock file rather than by being named.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
  }
}

locals {
  # The tag set every root in this repository applies. Declared once and given
  # to both provider configurations below, because that is the only way they can
  # be guaranteed to agree — `default_tags` is per configuration, so two literal
  # blocks are two chances to drift.
  #
  # Project and Env are the two the module requires and the two the end-to-end
  # teardown assertion queries on; the rest are the repository's convention.
  tags = {
    Project   = "terraform-aws-static-site"
    Env       = "dev"
    Owner     = "example"
    Repo      = "example/terraform-aws-static-site"
    ManagedBy = "terraform"
  }
}

# Deliberately not us-east-1, because that is the point being demonstrated. The
# module works in any region; only its CloudFront logging control plane is
# pinned, and that is what the second provider below is for.
provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = local.tags
  }
}

# Required by the module, in every region, always. CloudFront is global and its
# standard logging (v2) APIs answer only in us-east-1, so the delivery source,
# delivery destination, delivery and log group are created here rather than
# alongside the bucket.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  # The same tags as above, and this is the half that is easy to leave out. An
  # aliased provider inherits nothing from the default one, so without this the
  # four CloudWatch Logs resources are created untagged and the teardown
  # assertion goes green on a leak. The module checks for it at plan time; this
  # example exists partly to show the shape that passes.
  default_tags {
    tags = local.tags
  }
}

# The account's GitHub Actions OIDC provider, resolved rather than written down.
#
# Shown here, in the root that exists to be copied, because the alternative a
# copier would otherwise reach for is a literal ARN in their own configuration —
# and that ARN embeds an account id, which is exactly the material a committed
# file should not carry.
#
# The `arn` form and never the `url` form: the `url` form resolves by calling
# `ListOpenIDConnectProviders`, an action that takes no resource constraint, so
# granting it means an account-wide `Resource: "*"` on whatever identity runs
# the plan.
#
# Data sources are inert under `terraform validate`, which is all this root is
# ever asked to do, so this costs the credential-free check nothing.
data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

module "site" {
  source = "../../"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "example"
  environment = "dev"

  # The app repository's deploy identity. Five inputs with no defaults, so an
  # example that left them out would no longer be an example of a correct call.
  #
  # The three GitHub values describe the repository that deploys into this
  # environment — its owner and the two numeric ids GitHub embeds in the OIDC
  # subject, read with
  # `gh api repos/<owner>/react-cloudfront-app --jq '{owner: .owner.login, owner_id: .owner.id, repo_id: .id}'`.
  # The boundary is the name of the policy the bootstrap root created and
  # published as an output; the module composes the ARN from it.
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  app_github_owner         = "example"
  app_github_owner_id      = "1"
  app_github_repository_id = "2"

  app_deploy_boundary_policy_name = "example-app-deploy-boundary"

  # Left at its default of false, which is the value any environment holding
  # something worth keeping should use. The environments in this repository all
  # set it to true because all of them are ephemeral — see the module's README.
}

output "site_url" {
  description = "Scheme-qualified URL the example site would be served from."
  value       = module.site.site_url
}

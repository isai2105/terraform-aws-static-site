# The stage environment: one call to the static-site module, and nothing else.
#
# Module calls only, deliberately. An environment root exists to say *which*
# infrastructure exists and *with what values*, never how it is built — if this
# file ever grows a resource or a conditional, that logic belongs in a module
# where it can be tested once and called twice, rather than in a directory that
# has a near-identical twin nobody diffs it against.
#
# That rule read "a resource, a data source or a conditional" until the app
# repository's deploy role arrived, and the three data sources below are the one
# carve-out. They are amended into the rule rather than left to contradict it a
# few lines above the block that breaks it.
#
# The carve-out is narrow and it is forced. Resolving this account's GitHub OIDC
# provider ARN takes an API call, and the module cannot make one: every run block
# in its test suite is `command = plan`, plan reads data sources, and that suite
# authenticates with literal fake keys so that it needs no credentials and can be
# a required check on a pull request from a fork. An API-calling data source
# inside the module turns that check red with a 403 that reads like an expired
# local session rather than a design error. So identity resolution lives in the
# roots, which do have credentials, and reaches the module as an input.
#
# Nothing below decides what the infrastructure looks like — that is still the
# module's job, and still the thing this file must not start doing.
#
# The consequence to keep in view while reading this: `envs/prod` is this file
# with different values. Everything that is a literal here is a thing that gets
# copied there, and every copied literal is a chance for the two to disagree
# silently. That is the reasoning behind the local below.

locals {
  # The environment name, a constant rather than an input.
  #
  # `envs/stage` has exactly one correct value for this, so making it a variable
  # would buy nothing and cost the ability to get it wrong: `-var
  # environment=prod` from this directory would create prod-named resources
  # under stage's state key, tag them `Env = prod`, and leave stage's own
  # teardown query unable to see them. The bootstrap made the same call about
  # its own `Env` tag for the same reason.
  #
  # It is referenced in exactly two places — the module call below and the `Env`
  # tag in providers.tf — so the module's precondition that the two agree is
  # satisfied structurally rather than by a reviewer noticing.
  environment = "stage"
}

# The account's GitHub Actions OIDC provider, in the `arn` form.
#
# Never the `url` form. At provider 6.62.0 that form resolves by calling
# `ListOpenIDConnectProviders` and scanning the result; the action takes no
# resource constraint, so granting it would mean an account-wide
# `Resource: "*"` on the plan role — an identity that runs untrusted
# pull-request code. The `arn` form is a single `GetOpenIDConnectProvider` on
# one ARN, which is exactly what `bootstrap/oidc.tf` already grants the plan
# role and both apply roles.
#
# The ARN is composed rather than taken from `terraform.tfvars` because it
# embeds the account id, that file is committed, and a committed account id is
# the material this repository's push protection exists to catch. The issuer
# URL is identical in every account by construction, so this root resolves the
# ARN instead of being told it.
data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

module "site" {
  source = "../../modules/static-site"

  # Both configurations, explicitly. The default one would be passed implicitly,
  # but naming it beside the alias is what makes the pair visible as a pair: the
  # module needs both, and a caller that supplies one is the failure this block
  # exists to make impossible to write by accident.
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = var.name_prefix
  environment = local.environment

  # Ephemeral, so the bucket must be deletable while it still holds objects.
  #
  # This is the value the module refuses to default to, and it refuses for good
  # reason: it converts "destroy declined to remove a bucket holding data" — a
  # safe, loud, recoverable failure — into silent deletion of every object in
  # it. Set here, in a file a reviewer reads, because it is a property of this
  # operating model rather than of the module: nothing in this repository stays
  # deployed, and the app repository deploys real objects into this bucket. With
  # it false, the first teardown after a successful app deploy fails on
  # BucketNotEmpty and strands a CloudFront distribution behind it.
  force_destroy = true

  # The app repository's deploy identity, created and destroyed with this
  # environment because the bucket, the distribution and the parameters its
  # policy names are — a role authored anywhere else would name last cycle's
  # bucket, whose random suffix is re-minted on every apply.
  #
  # Five arguments, and not one of them is a value this root invents. Four come
  # from terraform.tfvars, where a cloner edits them for their own account and
  # their own fork of the app repository; the fifth is the data source above.
  # The module composes the trust subject and the boundary ARN from them, so
  # nothing about how those strings are built lives in this directory or its
  # twin.
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  app_github_owner         = var.app_github_owner
  app_github_owner_id      = var.app_github_owner_id
  app_github_repository_id = var.app_github_repository_id

  app_deploy_boundary_policy_name = var.app_deploy_boundary_policy_name

  # No custom domain, which is what makes this environment applicable in an
  # empty AWS account with no domain to hand — the default CloudFront
  # certificate and the distribution's own *.cloudfront.net hostname.
  #
  # The module supports one, through `domain_name` plus exactly one of
  # `hosted_zone_id` or `acm_certificate_arn`; those arguments are deliberately
  # absent here rather than wired to null-defaulted variables nothing sets.
  # Adding three pass-through inputs to every environment for a path this
  # repository never applies — and honestly documents as plan-verified only —
  # would be interface surface with no consumer. A cloner who has a domain adds
  # the arguments here; the module's README carries the two modes and which to
  # pick.
}

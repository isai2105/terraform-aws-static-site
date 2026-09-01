# The prod environment: one call to the static-site module, and nothing else.
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
# few lines above the block that breaks it — and being the twin makes that worse
# rather than better: a rule this file states and then breaks is a rule the next
# person copies past.
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
# This is that twin. Two values in this directory differ from `envs/stage` and
# no others do: the environment constant below, and the `key` in
# backend.hcl.example. The comments differ wherever the reasoning does — this
# file argues about prod, and stage's argues about stage — but every argument,
# variable, tag and provider configuration is the same, and that is what makes
# the promotion path a promotion rather than a second deployment that happens to
# resemble the first. A prod that differed from stage in some third value would
# mean stage had never exercised prod's configuration, which is the entire claim
# a promotion path makes.

locals {
  # The environment name, a constant rather than an input.
  #
  # `envs/prod` has exactly one correct value for this, so making it a variable
  # would buy nothing and cost the ability to get it wrong: `-var
  # environment=stage` from this directory would create stage-named resources
  # under prod's state key, tag them `Env = stage`, and leave prod's own
  # teardown query unable to see them. The bootstrap made the same call about
  # its own `Env` tag for the same reason.
  #
  # It is referenced in exactly two places — the module call below and the `Env`
  # tag in providers.tf — so the module's precondition that the two agree is
  # satisfied structurally rather than by a reviewer noticing. That precondition
  # exists for this directory in particular: a prod root copied from a stage
  # root keeps the tag it was copied with, and an environment tagged `stage`
  # while named prod is invisible to prod's teardown assertion.
  environment = "prod"
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
  # The same value stage sets, and the argument for it is stronger here rather
  # than weaker, which is the opposite of how this line reads at a glance. Prod
  # is the environment the app repository actually deploys objects into, so it
  # is the environment whose bucket is reliably non-empty by the time anything
  # tears it down. With `force_destroy = false`, the first teardown after a
  # successful app deploy fails on BucketNotEmpty, and it fails at the worst
  # point in the graph: the distribution takes the bucket as its origin, so
  # Terraform removes the distribution first — about three minutes of it, now
  # that it has been measured — and only then reaches a bucket it is not
  # allowed to empty. That ordering is now observed rather than argued: the
  # bucket policy is destroyed before the distribution and the bucket after it,
  # so the failure can only arrive once the whole wait has been spent
  # (docs/TEARDOWN.md section 4).
  # What is left is a half-destroyed environment that every subsequent
  # `destroy` fails on identically until someone empties the bucket by hand,
  # and a teardown interrupted anywhere in that window — a CI job timeout is
  # the obvious one — strands the distribution itself, which is the orphan
  # nothing in this repository can see once its state is gone. A guardrail
  # that guarantees a broken teardown under this operating model is theatre,
  # not safety.
  #
  # This is the module's one refused default, and it refuses for good reason: it
  # converts "destroy declined to remove a bucket holding data" — a safe, loud,
  # recoverable failure — into silent deletion of every object in it. Set here,
  # in a file a reviewer reads, because it is a property of *this* prod rather
  # than of prod: nothing in this repository stays deployed. A durable prod sets
  # it false, enables bucket versioning, and empties the bucket through a
  # documented runbook step; the README's tradeoffs section carries that shape,
  # where it can be explained rather than encoded in a value that breaks the
  # lifecycle this repository exists to demonstrate.
  force_destroy = true

  # The app repository's deploy identity, created and destroyed with this
  # environment because the bucket, the distribution and the parameters its
  # policy names are — a role authored anywhere else would name last cycle's
  # bucket, whose random suffix is re-minted on every apply.
  #
  # These are the same five arguments stage passes, from the same four
  # terraform.tfvars values and the same data source, and that is the correct
  # state of this block rather than a copy nobody finished editing. The trust
  # subject the module composes from them differs between the two environments
  # in nothing at all — it names a branch, not an environment — so what keeps
  # prod's role from being stage's role is the environment in its name and the
  # bucket, distribution and parameters its policy is scoped to.
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  app_github_owner         = var.app_github_owner
  app_github_owner_id      = var.app_github_owner_id
  app_github_repository_id = var.app_github_repository_id

  app_deploy_boundary_policy_name = var.app_deploy_boundary_policy_name

  # No custom domain, which is what makes this environment applicable in an
  # empty AWS account with no domain to hand — the default CloudFront
  # certificate and the distribution's own *.cloudfront.net hostname.
  #
  # A real prod is the one environment that would carry one, and it is left out
  # here for the reason the whole repository is: a cloner may not own a domain,
  # and an environment they cannot apply is an environment that stops being
  # verified. The module supports one, through `domain_name` plus exactly one of
  # `hosted_zone_id` or `acm_certificate_arn`; those arguments are deliberately
  # absent rather than wired to null-defaulted variables nothing sets. Adding
  # three pass-through inputs to every environment for a path this repository
  # never applies — and honestly documents as plan-verified only — would be
  # interface surface with no consumer. A cloner who has a domain adds the
  # arguments here; the module's README carries the two modes and which to pick.
}

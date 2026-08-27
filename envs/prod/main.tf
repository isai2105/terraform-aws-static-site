# The prod environment: one call to the static-site module, and nothing else.
#
# Module calls only, deliberately. An environment root exists to say *which*
# infrastructure exists and *with what values*, never how it is built — if this
# file ever grows a resource, a data source or a conditional, that logic belongs
# in a module where it can be tested once and called twice, rather than in a
# directory that has a near-identical twin nobody diffs it against.
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

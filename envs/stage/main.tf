# The stage environment: one call to the static-site module, and nothing else.
#
# Module calls only, deliberately. An environment root exists to say *which*
# infrastructure exists and *with what values*, never how it is built — if this
# file ever grows a resource, a data source or a conditional, that logic belongs
# in a module where it can be tested once and called twice, rather than in a
# directory that has a near-identical twin nobody diffs it against.
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

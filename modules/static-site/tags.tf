# The module's tagging contract, and the guard that makes breaking it loud.
#
# Every resource this module creates that *can* be tagged is tagged through the
# caller's provider `default_tags` rather than through an input. That is the
# mechanism the environment roots use, and keeping it the only one means there
# is never a second place tags can come from and disagree.
#
# The qualification is not pedantic and it bounds everything below. Four of the
# resource types here accept no tags at all — the two CloudFront policy types in
# policies.tf, the origin access control in cloudfront.tf, and the certificate
# validation record in certificate.tf, none of which expose `tags` or `tags_all`
# in the provider schema, because neither the CloudFront API nor a Route 53
# resource record set has anywhere to put them.
#
# Four, not five: the viewer-request function is not among them, however
# naturally AWS's sentence "You can't add tags to edge functions" invites
# counting it. `aws_cloudfront_function` does expose tagging in the provider
# schema, so it is covered by the rule in the paragraph above rather than
# excepted from it — this module sets no `tags` argument on it, which means it
# carries the caller's `default_tags` and nothing else: Project, Env, Owner, Repo
# and ManagedBy, put there by the same mechanism this file takes a precondition
# on. cloudfront.tf carries the evidence, and `bootstrap/oidc.tf`'s
# `TagSiteCdnResources` statement is a grant that already depends on it.
#
# What that does not settle: whether the resource groups tagging API returns a
# CloudFront function, which is what the teardown assertion actually queries.
# That is unmeasured here — see docs/TEARDOWN.md section 6.1 — so the function is
# neither in the covered half nor in the invisible one.
#
# The precondition in logging.tf, on the access-log group,
# therefore guarantees that everything *taggable* is tagged, which is a narrower
# claim than it looks and is the strongest one available. policies.tf carries
# what that costs the teardown assertion and which detectors are left.
#
# The validation record is the least dangerous of the four and the only one that
# is not quota-bearing: it lives in a zone this module does not own, it is
# created only on the custom-domain path that no environment here uses, and
# `allow_overwrite` on it means a copy stranded by a failed cycle is corrected by
# the next apply rather than blocking it. The ACM certificate beside it *is*
# taggable, which matters more, because a certificate stuck in PENDING_VALIDATION
# is the orphan that path actually produces.
#
# It has one failure mode, and it is silent. `default_tags` is a block inside a
# single `provider` configuration; an aliased provider is a separate
# configuration and inherits nothing from the default one. A caller that
# configures `default_tags` on `aws` and forgets it on `aws.us_east_1` gets a
# working distribution and four completely untagged CloudWatch Logs resources —
# no error, no warning, nothing in the plan that reads as wrong.
#
# That specific mistake is expensive here rather than cosmetic. The end-to-end
# workflow proves a teardown left nothing behind by asking the resource groups
# tagging API for everything carrying this repository's Project and Env tags and
# asserting the answer is empty. An untagged orphan is invisible to that query,
# so the assertion cannot tell "nothing survived" from "something survived
# without tags" — and a stranded log group is on the post-destroy checklist. The
# check would go green on exactly the leak it exists to catch.
#
# So the contract is checked at plan time instead of trusted. The cost is two
# local data reads and a precondition; the alternative is an assertion that
# lies, once, on the run where it matters.

data "aws_default_tags" "current" {}

data "aws_default_tags" "us_east_1" {
  provider = aws.us_east_1
}

locals {
  # Which of the two provider configurations this module is given fail the
  # contract. Both are checked, not just the aliased one: the default provider's
  # tags are conventional rather than guaranteed, and a root that configured
  # neither would otherwise be caught only by whichever check happened to look.
  #
  # Two conditions per configuration, because they fail for different reasons:
  #
  #   - `Project` must be present and non-empty. Its value is the caller's to
  #     choose, so the module checks that a choice was made rather than what it
  #     was.
  #   - `Env` must equal this module instance's own environment. Presence is not
  #     enough. An environment root copied from another one — which is precisely
  #     how the prod root comes into existence — keeps the tag it was copied
  #     with, so `Env = "stage"` on resources belonging to prod is the likely
  #     mistake, not a missing key. Its consequence is the same as an absent
  #     tag: prod's teardown query looks for `Env=prod` and finds nothing.
  untagged_provider_configurations = [
    for configuration in [
      { name = "aws", tags = data.aws_default_tags.current.tags },
      { name = "aws.us_east_1", tags = data.aws_default_tags.us_east_1.tags },
    ] :
    configuration.name
    if try(configuration.tags["Project"], "") == "" ||
    try(configuration.tags["Env"], "") != var.environment
  ]
}

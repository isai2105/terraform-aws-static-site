# The module's tagging contract, and the guard that makes breaking it loud.
#
# Every resource this module creates is tagged through the caller's provider
# `default_tags` rather than through an input. That is the mechanism the
# environment roots use, and keeping it the only one means there is never a
# second place tags can come from and disagree.
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
# without tags" — and a stranded log group is the first item on the post-destroy
# checklist. The check would go green on exactly the leak it exists to catch.
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

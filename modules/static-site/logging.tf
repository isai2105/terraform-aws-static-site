# CloudFront access logging, via standard logging (v2).
#
# Every resource in this file is created through the `aws.us_east_1` provider,
# and that is a hard AWS requirement rather than a preference. CloudFront is a
# global service whose logging control plane answers only in us-east-1: "when
# calling the CloudWatch API to enable standard logging, you must specify the US
# East (N. Virginia) Region, even if you want to enable cross Region delivery to
# another destination". The delivery source, delivery destination and delivery
# below are all CloudWatch Logs resources, and all three carry us-east-1 ARNs no
# matter where the environment itself lives.
#
# That has a consequence for the teardown assertion, and it is recorded here
# because this is the file that causes it. The resource groups tagging API is
# regional: `get-resources` answers for the region it is called in and no other.
# Everything else an environment creates is either in the environment's own
# region (the bucket) or global and returned by the us-east-1 endpoint (the
# distribution) — but these four resources are permanently in us-east-1 whatever
# region the environment uses. An assertion that queries only the environment's
# region therefore verifies the bucket and nothing in this file, and would report
# a clean teardown while every one of these survived. The end-to-end workflow
# needs a second query against us-east-1, and the commit that writes it should
# read this paragraph rather than rediscover it.
#
# ---------------------------------------------------------------------------
# Why v2 and not the distribution's own `logging_config`
# ---------------------------------------------------------------------------
#
# Legacy standard logging delivers to S3 by granting the `awslogsdelivery`
# canonical user FULL_CONTROL through a bucket ACL, which means re-enabling ACLs
# on the receiving bucket. ACLs have been disabled by default on new buckets
# since April 2023 and every bucket in this repository keeps them that way
# (BucketOwnerEnforced, s3.tf). Taking the legacy path would weaken a bucket's
# ownership posture in order to satisfy a rule about logging — the wrong trade,
# and a genuinely confusing one to come across a year later. Standard logging v2
# uses vended-log delivery and needs no ACL at all.
#
# ---------------------------------------------------------------------------
# Why CloudWatch Logs and not an S3 log bucket
# ---------------------------------------------------------------------------
#
# S3 is the conventional destination for CDN logs, and for a durable deployment
# querying months of traffic with Athena it is the right one. It is the wrong one
# here, for three reasons that are specific to this repository rather than
# general:
#
#   1. A log bucket cannot be destroyed while it holds objects, and CloudFront
#      delivers logs on a lag of minutes. Under an operating model where an
#      environment is applied, smoke-tested and destroyed inside the hour, the
#      logs of the smoke test are still in flight when the destroy begins — so an
#      object landing between "empty the bucket" and "delete the bucket" fails
#      the teardown. That is the expected case here, not an edge case.
#   2. AWS attaches the delivery permissions to a log bucket by writing its
#      bucket policy itself. A bucket policy managed by Terraform and rewritten
#      out of band by AWS is a permanent argument between the two.
#   3. A log group is deleted by one API call regardless of what it contains.
#      There is nothing to empty first, so there is no race, and nothing is left
#      behind for the teardown checklist to catch.
#
# The cost of choosing CloudWatch Logs is per-GB ingestion charges above what S3
# storage would be. Section 2 of the operating model is explicit that cost is not
# a design driver here, and an hour of a smoke-tested static site is kilobytes.

# Accepted: no customer-managed KMS key on this log group.
#
# The same argument the state bucket and the site bucket make, and it is stronger
# here. A CMK cannot be deleted synchronously — aws_kms_key schedules deletion
# with a seven-day minimum — so it would be the only resource in an environment
# that a destroy cannot actually reclaim, in the layer whose whole claim is that
# teardown is complete and verifiable.
#
# What the group holds is CloudFront access logs: request paths, status codes,
# edge locations, user agents and viewer IP addresses. That is worth protecting
# from anonymous access, which the log group already is, and it is not worth a
# resource that outlives the environment by a week. Logs are encrypted at rest
# with an AWS-owned key regardless of this setting; the CMK buys a second
# authorisation boundary, not encryption.
#
#trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "access_logs" {
  provider = aws.us_east_1

  # The `/aws/vendedlogs/` prefix is load-bearing, not cosmetic. Vended log
  # delivery authorises itself through an account-level CloudWatch Logs resource
  # policy, that policy has a size limit, and AWS keeps a single managed entry
  # covering `/aws/vendedlogs/*` rather than adding one entry per log group. A
  # group named outside the prefix makes each delivery consume policy budget, and
  # the failure mode when it runs out is a delivery that silently stops working.
  name = "/aws/vendedlogs/cloudfront/${local.bucket_name}"

  # Always bounded. Left unset, a log group retains forever — which under this
  # operating model would mean the one artefact of an ephemeral environment that
  # accrues cost indefinitely after the environment is gone. The group is
  # destroyed with the environment in the ordinary case; this is what covers the
  # case where it is not.
  retention_in_days = var.log_retention_days

  # The module's tagging contract, checked here because this resource is where
  # breaking it costs the most: a stranded log group is on the post-destroy
  # checklist, and an untagged one is invisible to the teardown assertion that
  # exists to find it. tags.tf carries the full reasoning.
  #
  # The check covers both provider configurations rather than only the aliased
  # one, so it is stated once, on the resource most exposed to it, instead of
  # repeated on each of the four this file creates.
  lifecycle {
    precondition {
      condition     = length(local.untagged_provider_configurations) == 0
      error_message = <<-EOT
        These provider configurations are missing the default_tags this module
        requires: ${join(", ", local.untagged_provider_configurations)}.

        Every provider configuration passed to this module — including the
        aliased aws.us_east_1 one, which inherits nothing from the default
        provider — must set default_tags carrying a non-empty Project and an Env
        equal to this module's environment ("${var.environment}").

        Without them the resources created through that configuration are
        untagged, and the end-to-end teardown assertion cannot distinguish them
        from resources that were destroyed. See the module README.
      EOT
    }
  }
}

locals {
  # Deliberately built from the prefix and environment rather than from
  # local.bucket_name, and the reason is a hard API limit rather than taste.
  #
  # PutDeliverySource and PutDeliveryDestination both cap `name` at 60
  # characters. The bucket name may be up to 63 on its own — S3's limit, which
  # variables.tf validates against — so any delivery name derived from it is
  # capable of exceeding 60 while every input is individually legal. That failure
  # would appear only at apply, only for a caller using a long prefix, and with a
  # message about a name rather than about the variable that produced it.
  #
  # Built this way the longest possible delivery name is 54 characters and the
  # longest destination name 59, both inside the cap for every input the module
  # accepts. Anything appended to these needs that arithmetic redone.
  #
  # Losing the random suffix costs nothing here: these names identify an
  # environment's log plumbing, of which there is exactly one per environment,
  # and PutDeliverySource updates in place rather than colliding.
  delivery_name = "${var.name_prefix}-site-${var.environment}"
}

# The source: which AWS resource is producing logs, and which of its log types.
#
# One delivery source per distribution is the AWS limit — a second
# PutDeliverySource naming the same distribution fails with "This ResourceId has
# already been used in another Delivery Source in this account". Nothing here
# creates a second one, but it is the reason a distribution cannot simply be
# given an extra destination by copying this block.
resource "aws_cloudwatch_log_delivery_source" "access_logs" {
  provider = aws.us_east_1

  # Word characters and hyphens only, per PutDeliverySource — so this cannot
  # carry the log group's slashes even if it were short enough to.
  name         = local.delivery_name
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.site.arn
}

# The destination: where those logs are written, and in what shape.
resource "aws_cloudwatch_log_delivery_destination" "access_logs" {
  provider = aws.us_east_1

  name = "${local.delivery_name}-logs"

  # JSON rather than the `plain` default. The destination is CloudWatch Logs,
  # where the only reason to send logs at all is to query them with Logs
  # Insights, and Insights parses JSON fields natively while plain text has to be
  # picked apart with a regex at query time.
  #
  # AWS allows this to be set at creation and never updated: changing it requires
  # destroying and recreating the delivery. Terraform will do that correctly, but
  # it explains why the argument has no business being a variable.
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.access_logs.arn
  }
}

# The link between them. Nothing is delivered until this exists — a source and a
# destination on their own are two unrelated records.
#
# `record_fields` is deliberately not set. Omitted, AWS delivers its full default
# field set, which is the same set legacy standard logging produced; naming a
# subset here would mean this module deciding, on behalf of whoever later has to
# debug a request, which fields they are allowed to have.
resource "aws_cloudwatch_log_delivery" "access_logs" {
  provider = aws.us_east_1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.access_logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.access_logs.arn
}

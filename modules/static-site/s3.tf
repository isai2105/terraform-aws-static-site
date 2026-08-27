# The origin: a private bucket that only CloudFront can read.
#
# Nothing in this file makes the bucket reachable from the internet. There is no
# website configuration, no public read, no ACL grant and no policy statement
# that names a principal other than the CloudFront service. Every viewer request
# arrives at the distribution and is fetched from here over an Origin Access
# Control-signed request, which is the whole reason the bucket can stay closed.

# S3 bucket names are a single global namespace shared by every AWS account, so
# a name that works in the account this was written in tells a cloner nothing
# about whether it will work in theirs. `random_id` is generated on first apply
# and held in state, so the name is stable for the life of the environment
# without being guessable or contended.
#
# Under this repository's operating model that life is under an hour: the state
# holding this suffix is destroyed with the environment, so the next apply mints
# a new name. That is why nothing downstream may hardcode a bucket name, and why
# the app repository reads it from SSM instead.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  # The bucket name is a contract with the bootstrap, not a naming preference.
  #
  # `bootstrap/oidc.tf` scopes the CI apply role's S3 grant to
  # "<name_prefix>-site-*", chosen to be disjoint from the state bucket's
  # "<name_prefix>-tfstate-<hex>" so that a role which may do anything to a site
  # bucket may do nothing to the bucket the whole design depends on surviving.
  # A site bucket named outside this pattern is a bucket CI cannot create, and
  # the failure arrives as an AccessDenied on CreateBucket.
  #
  # The environment name is in here rather than left to tags because the S3
  # console lists buckets by name and shows no tags: on the one occasion someone
  # is deleting a bucket by hand, the name is the only thing telling them which
  # environment they are looking at.
  bucket_name = "${var.name_prefix}-site-${var.environment}-${random_id.bucket_suffix.hex}"
}

# Accepted: no S3 server access logging on this bucket.
#
# The question this check asks — who read what, and when — is answered for this
# bucket by CloudFront standard logging (logging.tf), which records every viewer
# request that reaches the site. S3 server access logging would record something
# strictly less useful: the OAC-signed fetches CloudFront makes on a cache miss,
# attributed to the CloudFront service principal rather than to any viewer.
#
# What the check would have this module do instead is create a second bucket to
# receive those logs. That bucket trips this same rule on itself, has to be
# emptied before the environment can be destroyed, and adds a resource to the
# short list of things capable of surviving a teardown — in exchange for a
# lower-fidelity view of traffic the CloudFront logs already describe.
#
# Accepted: no versioning on this bucket either.
#
# Versioning answers "restore the previous object", and here the previous object
# is the previous build — which is not kept in this bucket. It is kept as the app
# repository's build artefact and redeployed by run id, which is the documented
# rollback path and restores a whole coherent build rather than one object of it.
#
# It would also cost something real under this operating model: versioning turns
# a delete into a delete marker over a retained version, so a bucket that must be
# emptied before it can be destroyed acquires a second class of thing to empty,
# and noncurrent versions are exactly the corner where a `force_destroy` teardown
# quietly fails. The state bucket accepts that cost because rolling back a
# corrupted state file has no other mechanism. This bucket has one.
#
# The resource is absent rather than declared with `status = "Disabled"`. The
# provider does not call PutBucketVersioning for that value, so the declaration
# would neither detect nor correct someone enabling versioning by hand — it would
# read as drift protection while providing none.
#
# A durable deployment should enable versioning, and would then also want a
# lifecycle rule expiring old hashed assets. The README's tradeoffs section
# records both.
#
#trivy:ignore:AVD-AWS-0089
#trivy:ignore:AVD-AWS-0090
resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name

  # Exposed rather than hardcoded, and defaulted to false — see variables.tf for
  # why this is the one value in the module that gets a default at all.
  force_destroy = var.force_destroy
}

# ACLs off, which has been the default for buckets created since April 2023 and
# is set explicitly here so it survives a provider default changing back.
#
# This is also the posture that decides how CloudFront access logging is
# configured. Legacy CloudFront standard logging delivers to S3 by granting the
# awslogsdelivery canonical user FULL_CONTROL through a bucket ACL, which means
# re-enabling ACLs on whichever bucket receives the logs. logging.tf uses
# standard logging v2 precisely so that no bucket in this repository has to give
# this up.
resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# All four switches, not the two that block new grants.
#
# The entire security model of this module is that the bucket is private and
# CloudFront is the only reader. These four settings are what makes that
# structural rather than a property of the current bucket policy: with them set,
# no future policy, ACL or console click can open this bucket to the internet
# without first deleting this resource on purpose.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Accepted: SSE-S3 rather than a customer-managed KMS key.
#
# The bootstrap's state bucket makes this argument at length and it applies here
# with less at stake, so only the part that differs is repeated. A CMK cannot be
# deleted synchronously — aws_kms_key schedules deletion with a seven-day
# minimum — which would make it the only resource in an environment that a
# destroy cannot actually reclaim, in a repository whose stated goal is complete
# and verifiable teardown.
#
# What this bucket holds is a compiled React bundle: public static assets served
# unauthenticated to anyone who visits the site. There is no confidentiality
# boundary here for a key policy to defend. A durable deployment serving anything
# else should flip this and accept the deletion window; the README's tradeoffs
# section says so rather than leaving it to be inferred from here.
#
# `bucket_key_enabled` is not set: it only reduces KMS request charges, and under
# SSE-S3 there are no KMS requests to reduce.
#
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# What may read this bucket, and over what transport.
data "aws_iam_policy_document" "site" {
  # The only read grant on the bucket, and it is not granted to a principal that
  # can hold credentials. `cloudfront.amazonaws.com` is the service principal
  # that signs OAC requests, and the SourceArn condition narrows it from "any
  # CloudFront distribution in any account" to this one distribution — without
  # it, anyone else's distribution could be pointed at this bucket and would be
  # allowed to read it.
  statement {
    sid    = "AllowCloudFrontOriginAccessControlRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # s3:GetObject and nothing else. Deliberately NOT s3:ListBucket, and this is
    # load-bearing rather than merely tidy: without ListBucket, S3 answers a
    # request for a key that does not exist with 403 rather than 404, because it
    # withholds key-existence information from a caller not allowed to enumerate
    # the bucket.
    #
    # Every later decision about SPA routing depends on that. The custom error
    # responses that arrive with the routing work have to map 403 as well as 404
    # for exactly this reason, and a future edit that adds ListBucket here would
    # silently change which status code a missing deep link produces.
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }

  # Refuse plaintext HTTP outright.
  #
  # Default encryption covers the object at rest and the statement above covers
  # who may reach it; neither says anything about the transport, and S3 still
  # answers on port 80. CloudFront's own origin fetches are already HTTPS, so
  # this denies nothing the design does today — it denies what a future direct
  # caller might do, and it does so without depending on anyone remembering.
  #
  # A lone Deny is purely additive: an explicit deny beats any allow, and the
  # absence of an Allow here takes nothing away from the grant above.
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    # Both the bucket and its contents: bucket-level calls are authorised
    # against the first ARN and object-level calls against the second, and a
    # policy naming only one of them leaves the other on HTTP.
    resources = [
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json

  # A bucket policy is public-access-blocked material: applying one before the
  # block is in place opens a window, however short, in which S3 would evaluate
  # it without `block_public_policy` set.
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# The placeholder document, which is what makes this module independently
# servable.
#
# Without it an environment applies to a distribution in front of an empty
# bucket, and the failure is worse than an empty page. A request for `/`
# resolves to `index.html`, the bucket has no such key, and the origin answers
# 403 — so the custom error responses in cloudfront.tf try to fetch their own
# error page, which is that same missing `/index.html`. CloudFront gives up and
# hands the viewer the original error. Every smoke-test assertion in the
# end-to-end workflow would then fail against infrastructure that is in fact
# correct, and the first instinct on reading that failure is to go looking for
# the bug in the distribution.
#
# It is a placeholder, not a fallback. The app repository's deploy overwrites
# this key with the real build, and nothing here should ever put it back.
resource "aws_s3_object" "placeholder_index" {
  count = var.seed_placeholder ? 1 : 0

  bucket = aws_s3_bucket.site.id
  key    = "index.html"

  # Deliberately free of inline <style> and <script>, because this document is
  # served under the module's own Content-Security-Policy — `default-src 'none'`
  # with no 'unsafe-inline'. A placeholder that violated the policy it is
  # served under would be a confusing first thing to see in a browser console,
  # and would make the policy look broken when it is working exactly as
  # written.
  content      = <<-EOT
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>${var.environment} — awaiting deployment</title>
      </head>
      <body>
        <h1>Infrastructure is up.</h1>
        <p>
          This is the placeholder document seeded by the static-site Terraform
          module. It means the bucket, the distribution and the origin access
          control are working, and that no application build has been deployed
          here yet.
        </p>
      </body>
    </html>
  EOT
  content_type = "text/html"

  # No `cache_control` here on purpose. The default cache behaviour already
  # revalidates on every request through its own zero default TTL, and the
  # browser-facing header is set by the response headers policy with
  # `override = true`, so an origin header would be redundant in both
  # directions. It would also be read back as drift the moment the app
  # repository overwrote this key without setting one.

  lifecycle {
    # The whole reason this resource is safe to declare.
    #
    # The app repository deploys by writing this exact key. Without these, the
    # next `terraform apply` would see the real build in place of the content
    # above, call it drift, and silently revert the deployed site to a
    # placeholder — an infrastructure run undoing an application release. With
    # them, Terraform creates the object once and never looks at its contents
    # again.
    ignore_changes = [content, etag]
  }
}

# The S3 bucket every other root in this repository keeps its state in.
#
# This root deliberately has no `backend "s3"` block of its own and runs on
# local state. It is the root that creates the bucket remote state lives in, so
# there is nowhere to put remote state until it has already run; making it
# self-hosting would be a circular dependency dressed up as consistency. The
# state file is small and this root is applied once, so the cost is a file the
# runbook tells the cloner to keep — and losing it means adopting this bucket
# back in by hand.
#
# Keeping that file also keeps the bucket's name stable: the uniqueness suffix
# below is generated once and then remembered by state, and nowhere else.

# S3 bucket names are a single global namespace shared by every AWS account, so
# a name that works in the account this was written in tells a cloner nothing
# about whether it will work in theirs. `random_id` is generated on first apply
# and then held in state, so the name is stable across applies without being
# guessable or contended.
resource "random_id" "state_bucket_suffix" {
  byte_length = 4
}

locals {
  # Composed here rather than inline so the bucket resource and the outputs
  # that publish the name cannot drift into two spellings of it.
  state_bucket_name = "${var.name_prefix}-tfstate-${random_id.state_bucket_suffix.hex}"
}

# Accepted: no S3 server access logging on this bucket.
#
# The question the check is really asking — "who read or wrote state, and from
# which CI run" — is one S3 server access logging answers badly. Delivery is
# best-effort and can lag by hours, and the record identifies the caller no more
# precisely than the role ARN already in the CloudTrail management event for the
# AssumeRoleWithWebIdentity that minted it. The mechanism that answers it
# properly is CloudTrail S3 data events, which are account-level configuration
# rather than a property of this bucket, and which a durable deployment of this
# design should turn on; the README's tradeoffs section says so.
#
# What the check would have this root do instead is create a second bucket to
# receive the logs. That bucket trips this same rule on itself, has to be
# emptied before the two-phase teardown in docs/TEARDOWN.md can remove
# anything, and adds a third resource to the short list of things that outlive
# a destroy — in exchange for a lower-fidelity copy of a record CloudTrail
# already holds.
#trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # `force_destroy` is deliberately left at its default of false. This bucket is
  # the one thing in the design that is meant to outlive a destroy: emptying it
  # is a step in the documented two-phase teardown in docs/TEARDOWN.md, not a
  # thing an errant `terraform destroy` should be able to do on its own.

  lifecycle {
    # The guard, and the reason the bootstrap cannot be torn down by the same
    # command that tears everything else down. `lifecycle` accepts no variables
    # and no expressions, so removing this is necessarily a hand edit to this
    # file — uncommitted, reverted immediately afterwards, and never its own
    # commit. That friction is the feature: a repository whose history contains
    # "remove the state bucket's guard" is one where a revert or a cherry-pick
    # removes it again on a day nobody intended to.
    prevent_destroy = true
  }
}

# ACLs off, which has been the default for buckets created since April 2023 and
# is set explicitly here so it survives a provider default changing back. Every
# bucket in this repository keeps this posture; the one thing that would
# otherwise force it open is CloudFront's legacy access logging, and the module
# uses standard logging v2 precisely so it does not have to.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# All four switches, not the two that block new grants. Terraform state records
# every attribute of every resource, including values the configuration marked
# sensitive; there is no version of this bucket that should be reachable
# anonymously, and no future requirement that should be able to make it so
# without deleting this resource on purpose.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is what makes a corrupted or truncated state file recoverable, and
# it is the reason the lifecycle rule below exists at all.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Accepted: SSE-S3 rather than a customer-managed KMS key.
#
# The check is right about what a CMK buys — a key policy is a second,
# independent authorisation boundary, so a principal holding s3:GetObject but
# no kms:Decrypt still cannot read state. That is the usual way state leaks,
# and on a shared or multi-team bucket it would decide this.
#
# It does not decide it here, for two reasons that are specific to this design
# rather than general. The grant this would defend against does not exist: the
# CI roles added alongside this bucket are scoped to named state keys, not to
# s3:* on the bucket, so the over-broad grant a key policy exists to catch is
# already closed by IAM rather than left to KMS. And a CMK cannot be deleted
# synchronously — aws_kms_key schedules deletion with a seven-day minimum — so
# it would be the only resource in the whole repository that a destroy cannot
# actually reclaim. This layer is precisely the one whose complete teardown is
# a documented, hand-walked and wall-clock-measured procedure, and "back to an
# empty account, apart from a key pending deletion until next week" is not the
# claim that procedure exists to support.
#
# A durable deployment of this design should flip this, accept the window, and
# add kms:Decrypt and kms:GenerateDataKey to the role policies. The README's
# tradeoffs section says so rather than leaving it to be inferred from here.
#
# `bucket_key_enabled` is not set: it only reduces KMS request charges, and
# under SSE-S3 there are no KMS requests to reduce.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bounds what versioning is allowed to accumulate.
#
# This is not housekeeping. With native S3 locking every plan, apply and
# destroy writes a `<key>.tflock` object and then deletes it, and on a versioned
# bucket a delete is a delete marker laid over a retained version. Across three
# state keys, every pull request, plus the weekly end-to-end run, that is a
# steady stream of noncurrent objects that nothing else removes.
#
# S3 lifecycle filters match on prefix, never on suffix, so the `.tflock` keys
# cannot be singled out. The rule is therefore bucket-wide and expressed as the
# only question that has a real answer: how much history is worth keeping.
# Twenty versions is the rollback guarantee written down. Everything past it is
# lock-object exhaust.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Neither resource references the other, so Terraform cannot infer the
  # ordering, and `noncurrent_version_expiration` against a bucket whose
  # versioning has not been turned on yet is a rule that applies to nothing.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "bound-noncurrent-history"
    status = "Enabled"

    # Empty rather than absent: a rule must carry exactly one of `filter` or
    # `prefix`, and an empty filter is how "every object in the bucket" is
    # spelled.
    filter {}

    noncurrent_version_expiration {
      newer_noncurrent_versions = 20
      noncurrent_days           = 30
    }

    # Reaps the delete markers the retained `.tflock` versions leave behind once
    # the versions underneath them have expired. Without this the markers are
    # what accumulates instead of the versions.
    expiration {
      expired_object_delete_marker = true
    }
  }
}

# Refuse plaintext HTTP outright.
#
# Bucket default encryption covers the object at rest and IAM covers who may
# reach it; neither says anything about the transport, and S3 still answers on
# port 80. For the one bucket that holds every attribute of every resource this
# repository creates, "the SDK happens to use TLS" is not the control anyone
# would want to be relying on.
#
# The policy is a lone Deny, which is purely additive: an explicit deny beats
# any allow, and the absence of an Allow here takes nothing away from the
# same-account IAM grants the CI roles will carry.
data "aws_iam_policy_document" "state_transport" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    # Both the bucket and its contents: bucket-level calls such as ListBucket
    # are authorised against the first ARN and object-level calls against the
    # second, and a policy naming only one of them leaves the other on HTTP.
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_transport.json

  # A bucket policy is public-access-blocked material: applying one before the
  # block is in place opens a window, however short, in which S3 would evaluate
  # it without `block_public_policy` set.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

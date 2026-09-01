# What this environment publishes to the repository that deploys into it.
#
# The app repository builds the site and uploads it; it does not create any of
# the infrastructure below it and cannot see this repository's state. Three
# values are the whole of what it needs — which bucket to sync to, which
# distribution to invalidate, and what URL to smoke-test afterwards — and none
# of the three is knowable in advance. The bucket name carries a random suffix
# minted on every apply, the distribution id is assigned by AWS, and the
# distribution's own hostname is reissued every time the environment is torn
# down and re-applied. There is nothing here the other repository could hardcode
# even if it wanted to, which is exactly why it has to be told.
#
# ---------------------------------------------------------------------------
# Why parameters rather than remote state
# ---------------------------------------------------------------------------
#
# The alternative is a `terraform_remote_state` data source in the app
# repository, pointed at this environment's state bucket. That reads as the
# cheaper option and is the more expensive one: it grants that pipeline
# s3:GetObject on the state file, which is read access to *every* attribute of
# *every* resource this module creates — the certificate, the policies, anything
# a future resource marks sensitive — in order to learn a bucket name. It also
# couples the two repositories to the state layout rather than to an interface,
# so a resource rename here becomes a broken deploy there.
#
# Three parameters at a fixed path are the narrow version of the same thing. The
# consumer needs to know the environment name, which it already does, and
# nothing else about this repository.
#
# ---------------------------------------------------------------------------
# Why `String` and not `SecureString`
# ---------------------------------------------------------------------------
#
# None of these three is a secret. The bucket name is visible to anyone who can
# list the account's buckets, the distribution id appears in the console URL of
# the distribution it names, and the site URL is the public address of a
# deliberately public website. Encrypting them would be posture rather than
# protection.
#
# It would also cost something specific rather than nothing. Reading a
# SecureString requires `kms:Decrypt` on the key that encrypted it in addition to
# `ssm:GetParameter`, so the app repository's deploy role would need a KMS grant
# — a second, wider permission, on a key that is shared account-wide when it is
# the AWS-managed `alias/aws/ssm` — bought in exchange for encrypting three
# public facts. The role that reads these is therefore written without one, and
# the type here is what that omission rests on. Flipping a parameter to
# SecureString would not fail here; it would fail in the other repository's next
# deploy, as an AccessDenied naming a KMS key nobody had thought about. The test
# suite asserts the type for that reason — it is the assertion that keeps this
# paragraph true.
#
# ---------------------------------------------------------------------------
# Why one `for_each` rather than three resources
# ---------------------------------------------------------------------------
#
# Three separate resources would write the `/static-site/<env>/` prefix three
# times, and a fourth parameter added later would write it a fourth. One map
# gives the path exactly one definition, so the parameters cannot drift into
# disagreeing about where they live.
#
# It also makes the set itself testable. `toset(keys(...))` is known at plan
# time, so the suite can assert *these three and no others* — a claim that is
# unwritable against three independent resources, where a parameter added,
# removed or renamed is invisible to a test that names the ones it knows about.
# The same collection is one expression for an IAM policy to scope to, instead of
# three ARNs restated by hand in a fourth place.
#
# No `tier` is set. Standard is the default, it is the one with no per-parameter
# monthly charge, and it holds 4 KB — the longest value here is a bucket name.
#
# Tags arrive from the caller's provider `default_tags`, as they do for every
# other taggable resource in this module. Worth stating rather than assuming,
# because tags.tf is careful about which resources are taggable and these are:
# unlike the CloudFront policies, a parameter left behind by a failed teardown is
# visible to the end-to-end assertion that proves an environment took everything
# with it.
resource "aws_ssm_parameter" "site" {
  # The keys are the last segment of each parameter's path. Every value is taken
  # from the graph rather than rebuilt beside it: the bucket name and the
  # distribution id are read off those two resources, and the URL is the same
  # `local.site_url` the output of that name publishes.
  #
  # `aws_s3_bucket.site.bucket` rather than the `local.bucket_name` the bucket is
  # named from — the same string, and not the same thing. Reading the resource is
  # what puts the bucket in this parameter's dependency graph, so the value
  # cannot be published before the bucket it names exists, and it stays correct
  # on the day the bucket stops being named straight from that local.
  for_each = {
    bucket_name = {
      value       = aws_s3_bucket.site.bucket
      description = "Name of the S3 bucket the built site is uploaded to. Minted with a random suffix on every apply, so it must be read from here on every deploy rather than remembered."
    }

    cloudfront_distribution_id = {
      value       = aws_cloudfront_distribution.site.id
      description = "Id of the CloudFront distribution to invalidate after an upload. Assigned by AWS and reissued whenever the environment is re-created."
    }

    site_url = {
      value       = local.site_url
      description = "Scheme-qualified URL the site is served from, resolved by the infrastructure repository. Published whole so that no consumer re-derives it from a hostname and a flag."
    }
  }

  # The one place this path is written. `<env>` rather than the bucket's random
  # suffix, because a consumer that had to know the suffix to find the parameter
  # holding the suffix would be back where it started.
  name = "/static-site/${var.environment}/${each.key}"

  type  = "String"
  value = each.value.value

  # Carried into SSM itself rather than left to this file, because the console
  # and `aws ssm describe-parameters` show it and an operator reading a parameter
  # path in an incident is not reading this repository.
  description = each.value.description

}

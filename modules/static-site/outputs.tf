# What the module hands back to the environment root that called it.
#
# The bucket name and the distribution id are the two values the app repository's
# deploy pipeline cannot function without, and neither is knowable in advance:
# the bucket carries a random suffix minted on every apply, and the distribution
# id is assigned by AWS. They are published here now and republished as SSM
# parameters later, which is how a repository that cannot see this one reads
# them.

output "bucket_name" {
  description = "Name of the private S3 bucket serving as the CloudFront origin. Minted with a random suffix on every apply, so nothing downstream may hardcode it."
  value       = aws_s3_bucket.site.bucket
}

output "bucket_arn" {
  description = "ARN of the site bucket. The app repository's deploy role scopes its S3 grants to this one bucket."
  value       = aws_s3_bucket.site.arn
}

output "distribution_id" {
  description = "Id of the CloudFront distribution. Needed to create an invalidation after a deploy."
  value       = aws_cloudfront_distribution.site.id
}

output "distribution_arn" {
  description = "ARN of the CloudFront distribution. The app repository's deploy role scopes its invalidation grants to this one distribution."
  value       = aws_cloudfront_distribution.site.arn
}

output "distribution_domain_name" {
  description = "The distribution's own `*.cloudfront.net` hostname, without a scheme. Regenerated on every apply."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "site_url" {
  description = "Scheme-qualified URL the site is served from. Published resolved rather than as parts, so that no consumer ever re-derives it and gets the answer wrong."

  # One value, computed once, in the module that owns the conditional: the alias
  # when a custom domain was asked for, the distribution's own hostname
  # otherwise. Every consumer keeps working across that switch without knowing it
  # happened, which is the entire reason this is published resolved rather than
  # as a hostname a caller has to prefix and a flag it has to interpret.
  #
  # It reads `var.domain_name` rather than the distribution's `aliases`, because
  # the two are the same value and only one of them is known at plan time.
  value = "https://${local.custom_domain_enabled ? var.domain_name : aws_cloudfront_distribution.site.domain_name}"
}

output "certificate_arn" {
  description = "ARN of the ACM certificate serving viewer HTTPS, or null when the distribution uses the default CloudFront certificate. Set to the caller's own certificate when one was supplied rather than requested."

  # Published for the teardown runbook rather than for the app repository. A
  # certificate stuck in PENDING_VALIDATION is on the post-destroy checklist, and
  # the value that identifies it is otherwise readable only from state.
  value = local.viewer_certificate_arn
}

output "content_security_policy" {
  description = "The Content-Security-Policy header this distribution serves, exactly as the response headers policies set it. Published so that a test can assert the live header against the value the policies were built from rather than against a second copy of the string."

  # This output exists for the end-to-end workflow, which asserts that the
  # header CloudFront actually serves matches the policy this module
  # configured. Two copies of this string across two repositories is the
  # irreducible cost of neither repository cloning the other; a third copy
  # inside this one, written into a test, would be an unforced error — it would
  # pass while describing a distribution nobody had checked.
  #
  # The environment roots re-export this for the workflow to read with
  # `terraform output`.
  value = local.csp
}

output "access_log_group_name" {
  description = "Name of the CloudWatch Logs group receiving CloudFront access logs. In us-east-1 regardless of the environment's own region, because CloudFront's logging control plane answers only there."
  value       = aws_cloudwatch_log_group.access_logs.name
}

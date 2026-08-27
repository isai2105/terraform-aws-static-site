# What this environment publishes to the workflows that operate it.
#
# A module output is not readable from outside the root that called it, so
# anything a workflow reads with `terraform output` has to be re-exported here.
# That makes this file an interface rather than a convenience, and it is kept to
# values with a named consumer: the module publishes nine outputs and this root
# forwards six. The three it does not — the bucket and distribution ARNs, and
# the distribution's bare hostname — have consumers that live *inside* the
# module (the app repository's deploy role scopes its grants to the first two,
# and `site_url` is the resolved form of the third), so re-exporting them would
# widen this interface without giving anything a way to use it.
#
# The same six stage forwards, deliberately. A workflow that operates both
# environments takes the environment as an input and reads the same output names
# from either; a prod root publishing a different set would make that workflow
# branch on the environment, which is where the two paths start being tested
# unequally.

output "site_url" {
  description = "Scheme-qualified URL the site is served from. The end-to-end workflow's smoke tests request this."
  value       = module.site.site_url
}

output "distribution_id" {
  description = "Id of the CloudFront distribution. The end-to-end workflow waits on this reaching Deployed before it smoke-tests, and an invalidation names it."
  value       = module.site.distribution_id
}

output "bucket_name" {
  description = "Name of the private S3 bucket serving as the origin. Minted with a random suffix on every apply, so nothing downstream may hardcode it."
  value       = module.site.bucket_name
}

output "content_security_policy" {
  description = "The Content-Security-Policy header this distribution serves, exactly as the response headers policies set it."

  # The reason this output exists at all, and the reason it is forwarded rather
  # than left in the module: the end-to-end workflow asserts that the header
  # CloudFront actually serves matches the policy this environment configured,
  # and it must read that expectation from the value the policies were built
  # from rather than from a second copy of the string. Two copies across two
  # repositories is the irreducible cost of neither repository cloning the
  # other; a third copy inside this one — written into a workflow — would pass
  # while describing a distribution nobody had checked.
  value = module.site.content_security_policy
}

output "access_log_group_name" {
  description = "Name of the CloudWatch Logs group receiving CloudFront access logs, in us-east-1 regardless of this environment's own region."

  # Published for the teardown check rather than for day-to-day use. A stranded
  # log group is the first item on the post-destroy checklist, and it is in
  # us-east-1 while the tagging-API assertion runs against this environment's
  # region — so the check that would otherwise find it is looking in the wrong
  # place. Naming the group here is what lets a teardown step assert against it
  # directly instead of inferring it.
  value = module.site.access_log_group_name
}

output "certificate_arn" {
  description = "ARN of the ACM certificate serving viewer HTTPS, or null — as here — when the distribution uses the default CloudFront certificate."

  # Null for this environment, and forwarded anyway. A certificate left in
  # PENDING_VALIDATION is on the post-destroy checklist, so the value has a
  # named consumer the moment anyone sets `domain_name` in main.tf; publishing
  # it now means enabling a domain is one edit rather than two, in a root whose
  # twin would otherwise be edited inconsistently.
  value = module.site.certificate_arn
}

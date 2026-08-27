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
  description = "The distribution's own *.cloudfront.net hostname, without a scheme. Regenerated on every apply."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "site_url" {
  description = "Scheme-qualified URL the site is served from. Published resolved rather than as parts, so that no consumer ever re-derives it and gets the answer wrong."

  # One value, computed once, in the module that owns the conditional. When the
  # optional custom domain arrives this becomes the alias instead of the
  # distribution hostname, and every consumer of this output keeps working
  # without knowing that happened — which is the entire reason it is published
  # resolved rather than as a hostname a caller has to prefix.
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "access_log_group_name" {
  description = "Name of the CloudWatch Logs group receiving CloudFront access logs. In us-east-1 regardless of the environment's own region, because CloudFront's logging control plane answers only there."
  value       = aws_cloudwatch_log_group.access_logs.name
}

# The distribution, and the Origin Access Control that lets it read a bucket
# nothing else can.

# Origin Access Control, not the deprecated Origin Access Identity.
#
# OAI predates SigV4 and cannot sign requests to buckets using SSE-KMS or in
# newer regions; AWS has recommended OAC for all new distributions since 2022
# and adds no features to OAI. `always` signs every origin request rather than
# only those without an Authorization header, which is what allows the bucket
# policy in s3.tf to name a single SourceArn and trust nothing else.
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.bucket_name
  description                       = "Signs CloudFront origin requests to the ${var.environment} site bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# The managed cache policy this distribution uses until the split policies
# arrive.
#
# Resolved by name through a data source rather than hardcoded as the UUID
# 658327ea-f89d-4fab-a63d-7e88639e58f6, which is the form most examples use. The
# UUID is stable, but it is also opaque: a reader cannot tell what it selects,
# and a typo in it produces a distribution that behaves subtly differently
# rather than an error.
#
# CachingOptimized is the right interim choice — it caches on the URI alone,
# forwards no cookies or headers, and honours the origin's Cache-Control — but it
# is interim. It applies one TTL to the whole distribution, and a real SPA host
# needs two: hashed assets immutable for a year, and index.html revalidated on
# every request. The commit that adds SPA routing replaces this data source with
# the module's own pair of cache policies and the response headers policies that
# carry the browser-facing Cache-Control, which no cache policy can emit.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Accepted: no AWS WAF web ACL in front of this distribution.
#
# The check is asking about a real control, and on an application that accepts
# input it would decide this. This distribution accepts none: it serves immutable
# static files from a private bucket, with no origin compute, no form handler, no
# authentication, no session and no database behind it. The injection, credential
# stuffing and bot-abuse rule groups that make a WAF worth its cost have nothing
# here to protect — the worst outcome of a malicious request is a 403 from S3.
#
# It is not free, either in money or in teardown. A web ACL is a billed monthly
# resource whether or not it matches anything, and one attached to a CloudFront
# distribution is a us-east-1 global-scope resource with its own association
# lifecycle — a second thing that can outlive a destroy, in a repository whose
# teardown checklist exists because orphans are the failure mode.
#
# What this distribution relies on instead is that there is nothing to exploit,
# plus CloudFront's own built-in absorption of volumetric attacks (AWS Shield
# Standard, which is always on and needs no configuration).
#
# Accepted: no `logging_config` block on this distribution.
#
# This one is a false negative rather than an accepted risk, and it is the only
# suppression in the module that says the check is looking in the wrong place.
# Access logging IS enabled — logging.tf configures it through CloudFront
# standard logging (v2), which is driven by CloudWatch Logs delivery resources
# rather than by an argument on the distribution. The check predates v2 and can
# only see the legacy `logging_config` block.
#
# Satisfying the check literally would mean adopting legacy logging, whose S3
# delivery works by granting the awslogsdelivery canonical user FULL_CONTROL via
# a bucket ACL — re-enabling ACLs on a bucket this repository deliberately keeps
# at BucketOwnerEnforced. Weakening a bucket's ownership posture to turn a rule
# about logging green, on a distribution that is already logging, is the wrong
# trade in both directions.
#
#trivy:ignore:AVD-AWS-0010
#trivy:ignore:AVD-AWS-0011
resource "aws_cloudfront_distribution" "site" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Static site for ${var.environment} (${local.bucket_name})"

  # Without this, a request for "/" is forwarded to the origin as a bucket-root
  # request, which an OAC-private bucket granting only s3:GetObject denies with a
  # 403. The homepage would then "work" only by falling through to whatever
  # handles origin errors — a correct outcome by an incorrect route, served under
  # the error path's caching rather than index.html's, and one that would break
  # the moment those error responses were narrowed.
  default_root_object = "index.html"

  origin {
    origin_id = local.bucket_name

    # The regional endpoint, never the global `bucket_domain_name`. The global
    # form resolves through the us-east-1 endpoint and can answer a request for a
    # freshly created bucket in another region with a redirect that CloudFront
    # surfaces to the viewer as an error, for as long as DNS propagation takes.
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id = local.bucket_name

    # A static site answers reads. Allowing only the two methods it can serve
    # means anything else is refused at the edge, before it reaches an origin
    # that would refuse it anyway — and it keeps the distribution from silently
    # acquiring an upload surface if the origin ever changes.
    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    # Not `allow-all`, and not `https-only`. `redirect-to-https` upgrades a
    # viewer who typed the hostname without a scheme instead of showing them an
    # error, which is the difference between a working site and a broken one for
    # the only people who reach this over HTTP in practice.
    viewer_protocol_policy = "redirect-to-https"

    # Brotli and gzip at the edge, on a payload that is almost entirely text.
    compress = true

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # No geographic restriction. Declared explicitly because the block is required
  # and an empty one is not valid: this is a public site with no licensing or
  # export constraint on who may read it.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # `minimum_protocol_version` is deliberately absent rather than set low.
  #
  # It is not a choice this block can make. Alongside the default CloudFront
  # certificate AWS requires the value to be TLSv1 and rejects anything higher,
  # because the field only governs viewer connections to a custom domain; what
  # the default *.cloudfront.net certificate negotiates is set by CloudFront's
  # own security policy and is not configurable here at all.
  #
  # The commit that makes the custom domain optional is where this becomes a real
  # decision, because an ACM certificate is the first thing that makes the field
  # meaningful; the value there is TLSv1.2_2021.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # Stated rather than inherited, because the default is a decision here.
  #
  # A CloudFront distribution takes several minutes to propagate to every edge
  # location, and `false` would return control as soon as the API accepted the
  # change. Under this operating model the very next thing that happens after an
  # apply is a smoke test against the distribution, so returning early would mean
  # asserting against edges that have not received the configuration yet — an
  # intermittent failure that looks like a bug in the assertions.
  wait_for_deployment = true

  # CloudFront distributions are identified by an opaque id in the console and in
  # the tagging API alike. Project, Env, Owner, Repo and ManagedBy arrive from
  # the `default_tags` on the *default* provider configuration — the aliased
  # us-east-1 one carries its own copy, which is why tags.tf checks both rather
  # than assuming either. This adds the one thing default_tags cannot, which is a
  # name a human can recognise in a list.
  tags = {
    Name = local.bucket_name
  }
}

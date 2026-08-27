# The distribution, and the Origin Access Control that lets it read a bucket
# nothing else can.

# Origin Access Control, not the deprecated Origin Access Identity.
#
# OAI predates SigV4 and cannot sign requests to buckets using SSE-KMS or in
# newer regions; AWS has recommended OAC for all new distributions since 2022
# and adds no features to OAI. `always` signs every origin request rather than
# only those without an Authorization header, which is what allows the bucket
# policy in s3.tf to name a single SourceArn and trust nothing else.
#
# This resource is untaggable too (see the tagging note in policies.tf), and
# unlike the policies there its name carries the bucket's random suffix — so a
# leaked OAC is invisible to the tag-based teardown assertion *and* collides
# with nothing on the next apply, leaving it the one resource here that no
# automatic check detects. The name is left alone rather than made stable
# because the quota is 100 per account against the policies' 20, so the
# accumulation pressure is an order of magnitude lower; a sweep by name prefix
# finds it if that ever stops being true.
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.bucket_name
  description                       = "Signs CloudFront origin requests to the ${var.environment} site bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
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

  # The document, and everything that is not a hashed asset. Revalidated at the
  # edge and marked `no-cache` to the browser, so a viewer always lands on the
  # current build.
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

    cache_policy_id            = aws_cloudfront_cache_policy.site["default"].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site["default"].id
  }

  # The hashed assets Vite emits, held at the edge for a year and marked
  # `immutable` to the browser.
  #
  # A separate behaviour rather than a longer TTL on the default one, because
  # the two halves of a built SPA have opposite requirements: the document must
  # never be stale and the assets can never *become* stale, since a new build
  # writes new filenames rather than new content at the same URL.
  ordered_cache_behavior {
    path_pattern     = "/assets/*"
    target_origin_id = local.bucket_name

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id            = aws_cloudfront_cache_policy.site["assets"].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site["assets"].id
  }

  # SPA routing, by way of the error path — the canonical CloudFront pattern,
  # and knowingly incomplete.
  #
  # A client-side route like /projects/x is not an object in the bucket. The
  # origin therefore refuses it, and these two mappings turn that refusal into
  # the application shell with a 200, letting the router resolve the path in the
  # browser. Returning the origin's status instead would have search engines
  # deindex every route the application defines.
  #
  # Both codes, not just 404. An OAC bucket answers a request for a missing key
  # with 403 rather than 404, because the bucket policy grants s3:GetObject
  # without s3:ListBucket and S3 withholds key-existence information from a
  # caller that may not enumerate — see the reasoning on that grant in s3.tf. A
  # configuration mapping only 404 would therefore map nothing at all here.
  #
  # What makes this incomplete is that CustomErrorResponses is defined once per
  # distribution and applies to every cache behaviour; it cannot be scoped to
  # the default one. So a request for a missing hashed chunk under /assets/ is
  # also answered with index.html and a 200 — HTML where the browser expects
  # JavaScript. The browser throws a parse error, monitoring sees a healthy 200,
  # and the failure is close to undiagnosable. That is the standard trap of this
  # pattern and it is exactly what a partial deploy produces.
  #
  # It is left in place deliberately rather than pre-empted. No plan-time test
  # can observe it: only a live request for a missing key can, and the
  # end-to-end workflow is the first thing in this repository that makes one.
  # The commit that follows that demonstration replaces both of these mappings
  # with a viewer-request function, which is the only mechanism that can tell a
  # route from an asset before the origin is consulted.
  dynamic "custom_error_response" {
    for_each = toset([403, 404])

    content {
      error_code         = custom_error_response.value
      response_code      = 200
      response_page_path = "/index.html"

      # Stated rather than inherited, because the default is a decision here.
      #
      # CloudFront otherwise caches an error response at the edge for ten
      # seconds. That mapping is keyed on the requested path, so a path that
      # 403s now and exists moments later — which is precisely what the
      # documented deploy sequence produces, since assets are uploaded before
      # the index.html that references them — would keep being answered with
      # the shell after the real object had landed. Zero costs an extra origin
      # round trip on a path that is about to stop taking this route entirely.
      error_caching_min_ttl = 0
    }
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

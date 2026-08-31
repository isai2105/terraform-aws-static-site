# The distribution, the Origin Access Control that lets it read a bucket nothing
# else can, and the viewer-request function that tells a client-side route from
# a file before either reaches the origin.

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

# The viewer-request function that decides, at the edge, whether a request is a
# client-side route or a request for a file.
#
# This replaces the canonical CloudFront SPA pattern — the origin's 403 and 404
# mapped to /index.html with a 200 through `custom_error_response` — and it
# replaces it rather than joining it. That pattern was carried here on purpose,
# with its defect written down beside it, until a live request could demonstrate
# the defect rather than predict it. On 2026-08-31 the end-to-end workflow (run
# 33407227330, against stage) asked for /assets/does-not-exist.js and got `200`
# with `content-type: text/html`. A missing hashed chunk reached the browser as
# the application shell under a healthy status: HTML where a script tag expects
# JavaScript, so the browser throws a parse error, monitoring sees a 200, and
# the failure is close to undiagnosable. Ten of that run's eleven assertions
# passed. The eleventh is why this resource exists.
#
# There was no configuration of the old mechanism that would have avoided it.
# `CustomErrorResponses` is defined once per distribution and applies to every
# cache behaviour — it cannot be scoped to the default one — so any mapping that
# answered a deep link with the shell answered a missing asset with it too.
#
# The two mechanisms also do not compose, which is why the error responses are
# deleted rather than kept underneath this as a second line of defence. A
# viewer-request function runs before CloudFront has consulted the cache or the
# origin, so it cannot know whether a key exists; it can only read the URI. Every
# request it declines to rewrite — every missing asset, precisely — would still
# have fallen through to the 403 mapping and come back as index.html with a 200.
# The trap would have survived the change that exists to close it. So the work is
# split by what is knowable where: the function handles what the edge can decide
# (this path names no file), and the origin's real 403 is allowed through for
# what it cannot.
#
# One argument goes with the deleted mapping and is worth replacing rather than
# mourning. It carried `error_caching_min_ttl = 0`, because the documented deploy
# sequence uploads assets before the index.html that references them, and a path
# that 403s now and exists moments later must not go on being answered from the
# edge. Nothing has to set that any more, and not because the hazard was
# accepted: CloudFront caches an origin 400, 403, 405, 412 or 415 *only* when the
# origin returns a `Cache-Control max-age` or `s-maxage` header, and S3's
# AccessDenied response carries neither. So the refusal for a missing asset is
# not held at the edge at all, and the first request after the object lands
# reaches the origin. The codes CloudFront does cache on its own — 404, 414 and
# the 5xx range — are not what a missing key produces against this bucket, for
# the reason the s3:GetObject grant in s3.tf gives.
#
# ---------------------------------------------------------------------------
# The rule, and what it gets wrong
# ---------------------------------------------------------------------------
#
# A request is a route when the *last* path segment contains no dot, and a route
# is rewritten to the literal /index.html.
#
# The last segment rather than the whole URI, which is what AWS's own published
# example tests (`!uri.includes('.')`). A dot is legal anywhere in a path, so the
# whole-URI test refuses to rewrite /v1.2/changelog — a route carrying a version
# in a directory — and hands the viewer a 403 for a page the application would
# have rendered. Narrowing the test loses nothing: a real file's name is in the
# last segment too.
#
# Rewritten to the constant /index.html rather than appended to the path. AWS
# publishes the appending form (`request.uri += '/index.html'`) under the name
# url-rewrite-single-page-apps, where /projects/x becomes /projects/x/index.html.
# That is right for a static site generator that emits an index document per
# directory and wrong for every single-page build, which emits exactly one
# index.html at the root — copied unread it turns every deep link into a 403.
#
# What the rule gets wrong is a route whose last segment contains a dot.
# /users/jane.doe is read as a file, is not rewritten, and reaches the viewer as
# the origin's 403 rather than as the application. That is a real limitation, it
# is not fixable from here — nothing at the edge can tell that route from a
# request for a file named jane.doe — and the application has to avoid dots in
# the final segment of a route.
#
# The rule errs in the other direction too, and one path is worth naming because
# it is the only extensionless *file* in common use on the public web:
# /.well-known/acme-challenge/<token> has no dot in its last segment, so this
# function would answer an HTTP-01 challenge with the application document.
# Nothing here serves one — certificate.tf validates through DNS, and no
# environment sets a custom domain at all — so it costs nothing today. It is
# written down so that the day something does serve one, the failure is a line
# in a comment rather than a rediscovery.
#
# The alternative that would fix it is an allowlist of known extensions: rewrite
# unless the last segment ends in .js, .css, .png and the rest. It is rejected
# because it fails in the dangerous direction. An extension nobody listed —
# .webmanifest, .avif, whatever ships next — turns a *missing file* into a 200
# carrying HTML, which is the exact defect being removed here, and it arrives
# silently on the day someone adds a file type. The dot rule fails the other way:
# a mislabelled route gets a loud 403. A rule whose failures are loud is the one
# to keep, and the residual is stated in the README rather than papered over.
#
# Trailing slashes and the root need no arm of their own; they fall out of the
# same test. The last segment of /about/ and of / is the empty string, which
# contains no dot, so both are rewritten to /index.html. And /index.html is a
# fixed point, because its last segment has one — which is what makes this safe
# wherever CloudFront's own default-root-object substitution sits relative to it
# (see `default_root_object` below).
resource "aws_cloudfront_function" "spa_routing" {
  # The name carries the bucket's random suffix, exactly as the origin access
  # control above does and for the same two reasons: a CloudFront Function is
  # account-scoped, so two environments would collide on a stable name, and it
  # is untaggable, so a leaked one is invisible to the tag-based teardown
  # assertion. Its own quota is 100 per account — the same number as the origin
  # access control's and five times the policies' 20 — so the trade lands where
  # that one landed: the accumulation pressure is low enough that a stable name
  # is not worth the collision it would cause between environments, and a sweep
  # by name prefix finds a leak. docs/TEARDOWN.md section 6.1 carries the sweep.
  #
  # Two CloudFront limits are met by caller-supplied values here, and both are
  # shown rather than asserted, the way policies.tf shows the CSP's. A function
  # name may be 64 characters; `local.bucket_name` is
  # "<name_prefix>-site-<environment>-<8 hex>", and variables.tf already caps
  # name_prefix + environment at 48 so that name fits S3's 63 — 48 + 15 = 63,
  # which clears this cap with one character to spare, by inheritance rather
  # than by coincidence. A comment may be 128; the fixed text below is 57
  # characters and the widest environment a valid name_prefix leaves room for is
  # 45, so the worst case is 102. Neither is a live constraint, and neither
  # becomes one without the S3 rule being relaxed first.
  name    = local.bucket_name
  comment = "Rewrites extensionless URIs to /index.html for the ${var.environment} site."

  # `cloudfront-js-2.0`, and this is a decision rather than a formality.
  # `runtime` is required and has no default, and the two values are not
  # interchangeable: AWS keeps 1.0 for functions written before 2.0 existed, and
  # 2.0 is the runtime its documentation gives new functions — the one that adds
  # `const` and `let`, `async`/`await`, `String.prototype.replaceAll()`,
  # `atob`/`btoa` and the buffer module, each marked "new in JavaScript runtime
  # 2.0" on the feature page. Template literals and the crypto module are *not*
  # among them: both are in 1.0, and citing them as the reason for this pin —
  # as an earlier version of this comment did — is a check nobody made.
  # Nearly every published copy of this rewrite still carries 1.0, including the
  # aws-samples repository AWS's own documentation links to, and a runtime
  # inherited by copying an example is not a decision anyone made. The code below
  # is ES 5.1 either way, so the pin buys nothing today; what it buys is that the
  # next edit to it is not silently confined to a runtime nobody chose.
  runtime = "cloudfront-js-2.0"

  # Stated rather than inherited, because the default is a decision here. A
  # function has two stages, DEVELOPMENT and LIVE, and a distribution may only
  # associate the LIVE one. Publishing is therefore not optional for a function
  # that is attached to a behaviour; `false` would describe a function that
  # exists and cannot be reached from the distribution that names it.
  publish = true

  # Inline rather than a separate .js file loaded with `file()`, and the honest
  # form of that choice is that nothing in this repository checks JavaScript
  # either way. No pre-commit hook here would check a .js file: the Terraform
  # hooks match `.tf`, `.tfvars` and `.tftest.hcl` (plus the Makefile and a few
  # pinned config files), the workflow hooks match YAML under `.github/` and an
  # `action.yml` at any depth rather than everything in `.github/` — as
  # `.github/CODEOWNERS`, which they skip, now shows — gitleaks reads
  # every file but looks only for secrets, and there is no generic formatter,
  # whitespace or end-of-file hook at all. Only `.editorconfig` would reach it,
  # and that is not a check. Nor are these lines checked where they are: to
  # `terraform fmt`, TFLint and trivy they are the contents of a string. The
  # choice is therefore not between checked and unchecked. It is
  # between unchecked lines in a file nothing here reads at all and unchecked
  # lines in a file every one of those tools opens, beside the reasoning that
  # produced them, which is where this repository keeps reasoning.
  #
  # What does check this JavaScript is CloudFront, which compiles it at
  # CreateFunction and fails the apply on a syntax error, and the end-to-end
  # workflow, which is the only thing that can show the rule is right rather than
  # merely valid. Neither cares which file it came from. The threshold to
  # revisit is size: twenty lines belong in a heredoc and two hundred would not,
  # and at that point the missing linter stops being a footnote.
  #
  # One hazard comes with the choice. Terraform has no non-interpolating
  # heredoc, so a `${...}` written into this JavaScript would be evaluated by
  # Terraform rather than by the runtime. There is none, and there must not be.
  code = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      // The last path segment: everything after the final slash, which is the
      // empty string for "/" and for any path ending in a slash.
      var lastSegment = uri.substring(uri.lastIndexOf('/') + 1);

      // No dot in it means this path names no file, so it is a client-side
      // route and the application document answers it. A dot means it is a
      // request for a file, and a file that is not there must come back as the
      // origin's refusal rather than as HTML with a 200.
      if (lastSegment.indexOf('.') === -1) {
        request.uri = '/index.html';
      }

      return request;
    }
  EOT
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
  # 403.
  #
  # The viewer-request function above also answers "/" — the last segment of "/"
  # is the empty string and therefore carries no dot — so the two overlap, and
  # the overlap is deliberate rather than left over. AWS documents that a
  # request for the root returns the default root object and says nothing
  # anywhere about whether that substitution happens before or after a
  # viewer-request function runs — not on the default root object page, not in
  # the CloudFront Functions event structure, and not in the restrictions on
  # edge functions, which are the three places it would be. Writing the function
  # as a fixed point on /index.html is what makes the ordering something this
  # module does not have to know: if CloudFront substitutes first, the function
  # sees /index.html, whose last segment has a dot, and leaves it alone; if the
  # function runs first it produces /index.html itself, which is no longer the
  # root and is not substituted again. Both orders end at the same object, on
  # the same cache behaviour, under the same policies.
  #
  # It stays because it is the half of the pair that keeps working on its own —
  # a reader who deletes the function to see what it does still gets a homepage,
  # and this argument no longer rests, as the previous version of it did, on
  # error responses that no longer exist.
  default_root_object = "index.html"

  # The custom domain, when there is one. Empty otherwise, which leaves the
  # distribution answering on its own *.cloudfront.net hostname only.
  #
  # An alias and a certificate are two halves of one thing: CloudFront rejects an
  # alias it has no certificate covering, and certificate.tf is what guarantees
  # the two are set together. Neither is set for any environment in this
  # repository.
  aliases = local.custom_domain_enabled ? [var.domain_name] : []

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

    # The rewrite, on this behaviour and deliberately not on /assets/*.
    #
    # CloudFront selects the cache behaviour from the URI the viewer sent, and
    # AWS states that a function changing `uri` "doesn't change the cache
    # behavior for the request or the origin that an origin request is sent to".
    # Both halves of that are load-bearing. A rewritten deep link stays on this
    # behaviour, so /projects/x is answered by /index.html under the document's
    # no-cache policy rather than under whatever the rewritten path would have
    # matched — that is what makes rewriting to a constant safe.
    #
    # And the same sentence is why attaching this to the assets behaviour would
    # be a defect rather than belt and braces. A request for an extensionless
    # path under /assets/ would be rewritten to /index.html and then served
    # under the assets policies: the application shell, carrying
    # `Cache-Control: public, max-age=31536000, immutable`, held for a year by
    # every browser that received it. That is worse than the trap being removed
    # here and it is not fixable by an invalidation, which reaches the edge and
    # not the browser. /assets/* has no function for the same reason it now has
    # no error mapping — everything under it is a file, so a request for one
    # that is not there has to reach the origin and come back refused.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_routing.arn
    }
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

  # No geographic restriction. Declared explicitly because the block is required
  # and an empty one is not valid: this is a public site with no licensing or
  # export constraint on who may read it.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # One block, four conditional arguments, rather than two `dynamic` blocks with
  # complementary conditions. `viewer_certificate` is required exactly once, so
  # the dynamic form would express "exactly one of these two must match" as two
  # independent predicates that nothing checks agree — and every argument here is
  # Optional and not Computed in the provider schema, so null genuinely means
  # unset rather than "leave whatever is there".
  viewer_certificate {
    # Exactly one of these two carries a value. `local.viewer_certificate_arn` is
    # null precisely when no custom domain was asked for, which is the same
    # condition that selects the default certificate.
    cloudfront_default_certificate = local.custom_domain_enabled ? null : true
    acm_certificate_arn            = local.viewer_certificate_arn

    # SNI rather than a dedicated IP address. `vip` provisions dedicated IPs at
    # the edge and is billed at roughly $600 a month for the privilege of
    # supporting clients that predate SNI — Windows XP and Android 2.x. Nothing
    # that can run a Vite ES-module build lacks SNI.
    ssl_support_method = local.custom_domain_enabled ? "sni-only" : null

    # Only meaningful, and only permitted, alongside a custom certificate.
    #
    # With the default CloudFront certificate AWS requires this to be TLSv1 and
    # rejects anything higher — the field governs viewer connections to a custom
    # domain, and what the *.cloudfront.net certificate negotiates is set by
    # CloudFront's own security policy and is not configurable here at all.
    # Leaving it null in that case is what keeps the two configurations from
    # having to disagree about a value one of them cannot set.
    #
    # TLSv1.2_2021 where it does apply: the strongest policy CloudFront offers
    # that is not TLS 1.3-only. It drops TLS 1.0 and 1.1 outright, which have
    # been deprecated since 2021 and which nothing capable of running this
    # application still requires.
    minimum_protocol_version = local.custom_domain_enabled ? "TLSv1.2_2021" : null
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

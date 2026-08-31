# What the edge caches, and what the viewer is told about it.
#
# Two pairs of policies, and the split between them is the point of this file.
# A cache policy governs how long CloudFront keeps an object at the edge. A
# response headers policy governs what the browser is told. They are different
# questions with different answers, and a design that answers only the first is
# a design where a returning visitor re-requests every hashed asset on every
# page load while the edge reports a 100% hit rate.
#
# ---------------------------------------------------------------------------
# The account-wide quota that bounds this file
# ---------------------------------------------------------------------------
#
# CloudFront caps custom cache policies at 20 per AWS account (quota
# L-7D134442) and custom response headers policies at 20 per AWS account. Both
# are account-wide rather than per-distribution, and neither counts the managed
# policies. This module creates two of each per environment — so
# stage and prod together account for four of each, and every environment that
# leaks its policies on teardown consumes more permanently.
#
# That is why the names below are stable rather than carrying the bucket's
# random suffix. A stable name turns a leaked policy into a loud, immediate,
# self-describing collision on the next apply of the same environment. A name
# carrying the random suffix would instead let leaked policies accumulate
# silently until an unrelated environment fails to apply against a quota error
# that names nothing about the leak that caused it. The teardown checklist
# carries this as a post-destroy item for the same reason.
#
# ---------------------------------------------------------------------------
# These resources cannot be tagged, so the teardown assertion cannot see them
# ---------------------------------------------------------------------------
#
# aws_cloudfront_cache_policy and aws_cloudfront_response_headers_policy expose
# no `tags` argument and no `tags_all` attribute — not omitted here, absent from
# the provider schema, because the CloudFront API has nowhere to put them. The
# origin access control and the viewer-request function in cloudfront.tf are the
# same, the second of them by an AWS statement rather than by inference: "You
# can't add tags to edge functions".
#
# That has a consequence which is not local to this file. The end-to-end
# workflow proves a teardown was complete by asking the resource groups tagging
# API for every resource carrying this repository's Project and Env tags and
# asserting the answer is empty — and that API returns only taggable resources.
# So the four quota-bearing resources this file creates per environment are
# invisible to that check, permanently and unfixably: a leak here leaves the
# assertion green.
#
# This is the one place the module's tagging story does not hold, and it is
# worth being exact about what it costs, because the resources it applies to are
# precisely the ones with the tightest quota in the repository. Two detectors
# are available and neither is a tag: an explicit sweep of
# `cloudfront list-cache-policies` and `list-response-headers-policies` filtered
# by the `<name_prefix>-site-` name prefix, or a manual post-destroy checklist
# item. The teardown runbook and the end-to-end workflow are where that choice
# gets made; it is recorded here because here is where it becomes knowable.
#
# It also promotes the stable naming above from a nicety to the primary control.
# With no tag-based detector, a name collision on the next apply of the same
# environment is the only automatic signal that a previous cycle leaked.

locals {
  # The Content-Security-Policy, and the one string in this repository that is
  # also a cross-repository contract.
  #
  # Two consumers read this exact value rather than restating it. The
  # end-to-end workflow asserts the live header against it, and the app
  # repository holds its own copy and refuses to upload anything until the
  # header CloudFront serves matches — compared after normalising both per
  # CSP3 section 2.2.1, so reordering is not a failure and a changed source
  # expression is. Editing this local is therefore a contract change, not a
  # local one: until the same change lands in the app repository, its next
  # deploy is refused. No ordering avoids that window, and the window is the
  # point — a build that has not been tested against the new policy should not
  # reach a distribution serving it.
  #
  # Two limits govern what may ever be written into this string, and both are
  # worth knowing before anyone tries to lengthen it.
  #
  # CloudFront caps the Content-Security-Policy header value at 1,783
  # characters (quota L-E9944CCE, adjustable) and rejects a longer one with
  # TooLongCSPInResponseHeadersPolicy. The assembled value below is 175
  # characters, so the cap is not a live constraint — but it does permanently
  # foreclose a hash-based policy, where every 'sha256-...' source costs about
  # 64 characters and a few dozen inline scripts would exhaust it. The
  # documented escape is a CloudFront Function on the *viewer-response* event,
  # which writes the header in code and is bound by no header-value quota.
  #
  # That is not the viewer-request function cloudfront.tf now attaches, and the
  # distinction is worth keeping straight now that this module has one at all:
  # a viewer-request function runs before the origin is consulted and rewrites
  # the URI, and could not set a response header if it wanted to. The escape
  # described here would be a second function, on the other event, and this
  # module deliberately does not need it.
  #
  # The second is not a size limit at all: multiple policies intersect, they
  # never override (CSP3 section 8.1). An application served by this
  # distribution can only ever tighten what is set here, never relax it. That
  # decides which side may fix a CSP problem — the answer is always this
  # repository — and it is why a <meta http-equiv> tag in the application is
  # not an escape hatch.
  #
  # Built with join() rather than written as one long literal so that each
  # directive can be read, reviewed and commented on its own line. The
  # assembled value is byte-identical to the single-line form.
  csp = join("; ", [
    # Deny by default. Every directive below is an exception to this line, and
    # anything not named here — a plugin, a frame, a manifest, a prefetch — is
    # refused rather than falling back to a permissive default.
    "default-src 'none'",

    # No 'unsafe-inline', no hashes and no nonces, and the reason is Vite's
    # production build rather than anything about the framework on top of it.
    # That build extracts all CSS to files and loads even async-chunk CSS
    # through a JS-created <link rel="stylesheet">, never a <style> element,
    # so a hash-free policy is not a compromise here — it is what the build
    # already emits.
    #
    # Attributing this to Tailwind would be wrong and would mislead whoever
    # maintains it: Tailwind's dev server and Play CDN modes inject <style>
    # tags and would break this policy, while any CSS-in-JS runtime breaks it
    # whether Tailwind is present or not. The constraint is the bundler and
    # the absence of a style runtime, not the CSS framework.
    "script-src 'self'",
    "style-src 'self'",

    # data: is required rather than lax. Vite inlines assets below its
    # assetsInlineLimit as data URIs, so icons and small images arrive in the
    # bundle rather than as separate requests, and they fail to render without
    # it. It is granted to img-src alone; no other directive needs it.
    "img-src 'self' data:",

    "font-src 'self'",
    "connect-src 'self'",

    # base-uri closes the one hole a strict script-src otherwise leaves: an
    # injected <base> element re-points every relative script URL at another
    # origin without ever violating script-src 'self'.
    "base-uri 'none'",

    # This site posts nowhere. A form action is therefore always either a bug
    # or an injection.
    "form-action 'none'",

    # Clickjacking, and the reason X-Frame-Options is deliberately absent from
    # the header set below. CSP Level 2 onward requires a user agent that
    # understands frame-ancestors to ignore X-Frame-Options entirely, so
    # sending both means sending one header that every current browser
    # discards. The directive is also strictly more expressive.
    #
    # It has one property worth knowing before anyone tries to move this
    # policy into the application: frame-ancestors is silently ignored when a
    # policy is delivered by <meta http-equiv>. A policy that works as a
    # header stops protecting against framing the moment it is moved into the
    # document, with no error anywhere.
    "frame-ancestors 'none'",
  ])

  # A year, which is the value the HSTS preload list requires and the
  # conventional maximum. Named rather than inlined because it appears in the
  # policy below and belongs beside the reasoning.
  hsts_max_age_seconds = 31536000

  # A year in seconds, for the immutable assets. Vite emits content-hashed
  # filenames, so a given /assets/ URL never changes content — which is what
  # makes a one-year TTL correct rather than merely aggressive. A new build
  # produces new filenames and new cache entries.
  immutable_max_age_seconds = 31536000

  # The two edge caching profiles, and the two browser-facing Cache-Control
  # values that go with them. Keyed identically so the distribution wires
  # "default" to "default" and "assets" to "assets" in both places.
  #
  # The TTLs answer only "how long may the edge serve this without asking the
  # origin". Nothing here reaches the viewer; that is what the response
  # headers policies below are for.
  cache_behaviours = {
    # index.html, and anything else not under /assets/.
    #
    # default_ttl = 0 means CloudFront revalidates with the origin whenever the
    # origin sent no Cache-Control of its own, which S3 does not. That is
    # precisely "no-cache" in the HTTP sense — the edge may hold the object but
    # must check before serving it — and it costs a conditional request that
    # answers 304 rather than a full fetch.
    #
    # Setting it this way rather than relying on an origin header is what makes
    # the placeholder object in s3.tf able to stay header-free: freshness is a
    # property of the distribution here, not of whatever last wrote the object.
    #
    # max_ttl stays high so that an origin which does send a longer
    # Cache-Control is honoured up to a year. Nothing in this repository does
    # today; refusing it in advance would be the module overriding a caller
    # about that caller's own content.
    default = {
      min_ttl     = 0
      default_ttl = 0
      max_ttl     = local.immutable_max_age_seconds

      # What the browser is told. `no-cache` does not mean "do not store" — it
      # means "store, but revalidate before using", which is what keeps a
      # returning visitor on the current build without re-downloading the
      # document when it has not changed.
      cache_control = "no-cache"
    }

    # /assets/*, which Vite fills with content-hashed filenames.
    #
    # min_ttl stays 0 rather than matching default_ttl. A min_ttl of a year
    # would force the edge to serve a cached object for a year even if the
    # origin explicitly asked for less, which removes the only lever available
    # for shipping a corrected asset without an invalidation.
    assets = {
      min_ttl     = 0
      default_ttl = local.immutable_max_age_seconds
      max_ttl     = local.immutable_max_age_seconds

      # `immutable` is the half that matters for a returning visitor: without
      # it a browser still sends a conditional request on reload even while the
      # object is fresh. With it, a hashed asset is served from disk with no
      # network at all.
      cache_control = "public, max-age=${local.immutable_max_age_seconds}, immutable"
    }
  }
}

# The cache policies.
#
# Written as one resource over a map rather than two resources, because the
# only part that differs between them is three integers — the cache key
# configuration below is identical and security-relevant, and two literal
# copies of it are two things that can drift.
#
# The AWS-managed policies were the alternative and neither fits.
# Managed-CachingOptimized carries a default TTL of one day, not one year, so
# assets uploaded without a Cache-Control header — which is what the documented
# deploy sequence uploads — would be re-fetched daily rather than held for the
# year this design claims. Managed-CachingDisabled would serve for the default
# behaviour, but pairing one managed policy with one custom one makes the split
# unreadable at exactly the point someone is trying to understand it.
resource "aws_cloudfront_cache_policy" "site" {
  for_each = local.cache_behaviours

  name = "${var.name_prefix}-site-${var.environment}-${each.key}-cache"

  # No caller-supplied value is interpolated into a policy comment, here or on
  # the headers policy below, and that is a rule rather than a coincidence.
  #
  # CloudFront caps both CachePolicyConfig.Comment and
  # ResponseHeadersPolicyConfig.Comment at 128 characters and rejects a longer
  # one at apply with an InvalidArgument that names neither the field nor the
  # variable that overflowed it. An earlier draft of this file interpolated
  # var.environment into both. The headers comment was then 85 literal
  # characters plus the key plus the environment, so it broke at an environment
  # name of 37 — and variables.tf legitimately admits one of up to 45, giving a
  # worst case of 137 against a limit of 128. Every input involved passed every
  # validation in the module.
  #
  # Shortening the prose until the worst case happened to fit would have left
  # the safety as arithmetic that has to be redone, correctly, by whoever next
  # edits the wording. Tightening the environment validation instead would have
  # made this module reject a name the bootstrap's own `environments` list
  # accepts, which is the two-files-disagree bug already fixed once in
  # variables.tf. Dropping the interpolation removes the failure mode outright:
  # the only variable part left is each.key, which comes from
  # local.cache_behaviours in this file rather than from a caller.
  #
  # Nothing is lost. The policy *name* directly above carries the environment,
  # and list-cache-policies returns the name alongside the comment.
  #
  # Budget: 62 literal characters here and 65 on the headers policy, so the key
  # would have to reach 66 or 63 characters respectively to overflow. "default"
  # and "assets" render 69 and 72.
  comment = "Edge caching for the ${each.key} behaviour of a static site distribution."

  min_ttl     = each.value.min_ttl
  default_ttl = each.value.default_ttl
  max_ttl     = each.value.max_ttl

  parameters_in_cache_key_and_forwarded_to_origin {
    # The cache key is the URI and nothing else.
    #
    # This is a static site served from a private bucket: the response cannot
    # vary by cookie, header or query string, because the origin has no way to
    # make it vary. Including any of them in the key would fragment the cache
    # into entries that are byte-identical — a query string appended by an ad
    # network or an analytics redirect would mint a fresh cache entry and a
    # fresh origin fetch for a file that has not changed.
    #
    # These also control what is forwarded to the origin, and S3 has no use
    # for any of it.
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    # These two are what make `compress = true` on the behaviours work
    # correctly. CloudFront normalises the viewer's Accept-Encoding into the
    # cache key itself when they are enabled, which is why Accept-Encoding must
    # not also be named in headers_config above — CloudFront rejects a policy
    # that does both.
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# The response headers policies.
#
# One resource over the same map, and here the shared body is the entire
# reason for the construction rather than a convenience. The security headers
# below are written once and therefore attached to both behaviours by the
# structure of the code, not by anyone remembering to keep two blocks in step.
#
# That property is load-bearing beyond this file. The app repository asserts
# the Content-Security-Policy against a single request to `/` and treats the
# result as describing the whole distribution, which is only true while both
# policies carry the same headers. Two literal blocks would let /assets/*
# quietly lose the CSP while the app's check kept passing against the default
# behaviour — the check would go blind to half the distribution without ever
# failing.
resource "aws_cloudfront_response_headers_policy" "site" {
  for_each = local.cache_behaviours

  name = "${var.name_prefix}-site-${var.environment}-${each.key}-headers"

  # Free of caller-supplied values for the reason set out on the cache policy
  # above: this is the field whose 128-character cap was actually reachable.
  comment = "Security headers and browser cache directives for the ${each.key} behaviour."

  security_headers_config {
    # `override = true` on every one of these, and it is load-bearing rather
    # than defensive. With it false, a header of the same name supplied by the
    # origin wins. S3 sends none of these today, so nothing would break — which
    # is exactly why a wrong value here would go unnoticed until the day an
    # origin started sending one, and the security posture this repository
    # advertises would quietly become whatever that origin said.
    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }

    # The only value this header can take, which is why the provider exposes no
    # field for it. It stops a browser from second-guessing the Content-Type on
    # a response and executing a bundle that was served as something else.
    content_type_options {
      override = true
    }

    strict_transport_security {
      access_control_max_age_sec = local.hsts_max_age_seconds

      # A no-op today and a decision to revisit exactly once. The distribution
      # is reached at a *.cloudfront.net hostname, which has no subdomains of
      # its own, so this directive currently binds nothing. It stops being a
      # no-op the moment the optional custom domain lands, because it then
      # binds every subdomain of the caller's zone to HTTPS — including hosts
      # this repository knows nothing about. The commit that adds the custom
      # domain has to make this a real choice rather than inherit it.
      include_subdomains = true

      # Deliberately off. Preloading is a one-way door: it requires submitting
      # a registrable domain to a list browsers ship, and removal takes months
      # to propagate. It is not the module's to request on behalf of a domain
      # the caller owns and the module has not even been told about, and it
      # cannot apply to cloudfront.net, which is on the public suffix list.
      preload  = false
      override = true
    }
  }

  custom_headers_config {
    # The browser-facing Cache-Control, and the reason this resource exists at
    # all. A cache policy emits no header to the viewer — it decides only what
    # the edge does — so without this the split-caching design would be a claim
    # the repository makes and does not deliver.
    items {
      header   = "Cache-Control"
      value    = each.value.cache_control
      override = true
    }
  }
}

# What a plan can establish about this module, and nothing else.
#
# Run with `make test`, which is a check rather than an environment target: it
# reaches no AWS account, needs no credentials and is required on every pull
# request. Everything below is what that claim costs and what it buys.
#
# ---------------------------------------------------------------------------
# Why the provider configurations look like this
# ---------------------------------------------------------------------------
#
# `terraform test` is not credential-free by default, and assuming it was is the
# first thing this file had to correct. The AWS provider validates credentials
# when it is *configured*, not when a resource is created, so a suite of
# `command = plan` run blocks that touches no AWS API still fails before the
# first assertion — measured, on a machine with an expired session:
#
#     Error: Retrieving AWS account details: validating provider credentials:
#     retrieving caller identity from STS: ... InvalidClientTokenId
#
# The `skip_*` arguments and the literal keys look like one guard and are two.
# Each buys a different property, and neither is removable without losing the
# one it buys:
#
#   the three `skip_*` arguments   remove the STS call and the account-id
#                                  lookup, which is what makes this suite
#                                  credential-free. Without them it fails as
#                                  above.
#
#   the literal keys               pin what an *apply* would authenticate with.
#                                  Every run block here is `command = plan`, but
#                                  a run block that omitted `command` would
#                                  default to apply — and with these keys it
#                                  fails loudly instead of falling back to the
#                                  ambient credential chain and creating real
#                                  infrastructure on a machine that happens to
#                                  have working credentials. Delete them as
#                                  apparently-dead weight and the suite stays
#                                  green while that trap quietly opens.
#
# With both, this suite passes with no HOME, no AWS variables of any kind and
# every outbound HTTP request black-holed — the state a pull request from a fork
# runs in, and the reason this can be a required check at all. The job in
# validate.yml has no AWS credentials configured either, so the apply trap has
# two independent halves to defeat.
#
# One thing the keys do not do, since the first version of this comment claimed
# they did: they do not stop the provider reading the shared config file. An
# `AWS_PROFILE` naming a profile that does not exist still fails, with a
# `failed to get shared config profile` parse error and six skipped run blocks.
# That is local, loud and makes no network call — a valid profile, including an
# MFA-gated one, is simply ignored in favour of the keys — so it costs the
# credential-free claim nothing. It is recorded because a comment that overstates
# its own insulation is how the next person stops checking.
#
# ---------------------------------------------------------------------------
# Why not mock_provider
# ---------------------------------------------------------------------------
#
# `mock_provider` is the feature built for this and it is the wrong tool here.
# It replaces the provider's own plan behaviour with values Terraform invents,
# so every schema default, every computed attribute and the `region` attribute
# the alias assertions below turn on would come from the test rather than from
# the provider — a suite that passes by agreeing with its own mocks. The real
# provider, holding credentials it will never use, keeps every plan-time
# computation real while making a network call impossible. Mocking is used in
# exactly one place below, scoped to two attributes that cannot exist at plan
# time, and the reasoning is at that point of use.
#
# ---------------------------------------------------------------------------
# Why the two configurations are in different regions
# ---------------------------------------------------------------------------
#
# eu-west-1 and us-east-1 are not decoration. The module takes `aws` and
# `aws.us_east_1` from its caller, and this file is the caller — so nothing but
# this file decides whether the resources that must be created in us-east-1
# actually are. AWS provider 6.x gives every resource a `region` attribute that
# defaults to its provider configuration's region and is known at plan time,
# which makes it the one plan-visible fact that says which of the two
# configurations a resource is bound to. Two configurations in the same region
# would leave every alias assertion below true no matter how the module was
# wired.
#
# One file rather than several, because provider blocks are scoped to the file
# that declares them: a second file means a second copy of everything above,
# and two chances for the copies to disagree about the regions the alias
# assertions depend on.
#
# ---------------------------------------------------------------------------
# Why there is now a .terraform.lock.hcl beside the module
# ---------------------------------------------------------------------------
#
# `terraform test` initialises this module as a root, so it resolves providers
# through a lock file of its own. That file is committed and pinned to the same
# provider versions every other root here locks, rather than to whatever was
# newest the first time somebody ran the suite. Otherwise these tests would be
# the one thing in the repository asserting against a provider the environments
# do not plan with — and a provider release would turn a required check red on a
# day nothing in this repository changed. It is inert for a caller: a root that
# calls this module resolves providers through its own lock and never reads
# this one.
#
# All five lock files here agree today and nothing compares them, which is worth
# stating plainly rather than leaving as an implied guarantee. That obligation
# was written here as a standing one on whatever refreshed them, and
# .github/workflows/provider-lock-refresh.yml is now what does: it discovers its
# work by finding every committed .terraform.lock.hcl rather than by naming the
# roots, so this file and the module's examples/default/ are covered by the same
# pass that covers envs/ and bootstrap/, and all five move in one commit or
# none. "Bump those and forget this one" is no longer a way for the divergence
# to arrive.
#
# What is left is narrower and still uncovered: a hand edit to one lock file, or
# a root added later whose lock file was never committed, which that workflow
# discovers nothing about because there is nothing to discover.
#
# A mechanical check was considered and deliberately deferred rather than
# written here, and the deferral still holds for the reason it was given.
# Comparing locks across roots is not a one-liner — they hold different provider
# sets, so "in sync" means "agree on every provider both record", not
# "identical" — and it is a question about whether a module should be allowed to
# lag, which nothing has needed to answer. What has changed is the size of the
# thing it would catch: the routine path now produces all five together, so such
# a check would be guarding against a hand edit rather than against the
# automation.

provider "aws" {
  region = "eu-west-1"

  access_key                  = "mock-access-key-id"
  secret_key                  = "mock-secret-access-key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  # The module refuses to plan without these — tags.tf checks both provider
  # configurations for a non-empty Project and an Env matching the module's own
  # environment, because an untagged resource is invisible to the teardown
  # assertion that proves an environment left nothing behind. Supplying them
  # here is what makes this suite exercise the passing side of that
  # precondition rather than route around it.
  default_tags {
    tags = {
      Project = "terraform-aws-static-site"
      Env     = "test"
    }
  }
}

# The configuration alias the module declares. CloudFront's logging control
# plane and any viewer certificate answer only in us-east-1, whatever region the
# rest of the environment lives in.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  access_key                  = "mock-access-key-id"
  secret_key                  = "mock-secret-access-key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  # Stated again rather than shared with the configuration above, because that
  # is exactly the mistake tags.tf exists to catch: an aliased provider inherits
  # nothing from the default one, and a caller that sets default_tags on `aws`
  # alone gets four silently untagged CloudWatch Logs resources.
  default_tags {
    tags = {
      Project = "terraform-aws-static-site"
      Env     = "test"
    }
  }
}

variables {
  name_prefix = "tftest"
  environment = "test"
}

# The configuration every environment in this repository actually uses: no
# custom domain, no certificate, served from the distribution's own hostname.
run "no_custom_domain" {
  command = plan

  # Private, in all four of the ways a bucket can fail to be.
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.site.block_public_acls,
      aws_s3_bucket_public_access_block.site.block_public_policy,
      aws_s3_bucket_public_access_block.site.ignore_public_acls,
      aws_s3_bucket_public_access_block.site.restrict_public_buckets,
    ])
    error_message = "The site bucket's public access block must have all four settings on: it is reachable only through CloudFront's origin access control, and any one of these left off is a route around that."
  }

  # And private in the fifth way, which the block above does not cover: with
  # ACLs disabled outright there is no grant mechanism left for anything but the
  # bucket policy.
  assert {
    condition     = aws_s3_bucket_ownership_controls.site.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "The site bucket must keep object ownership at BucketOwnerEnforced, which disables ACLs entirely. Anything else re-opens a second way to grant access to an object."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.default_root_object == "index.html"
    error_message = "The distribution must serve index.html for a request to \"/\". Whether CloudFront substitutes the default root object before or after a viewer-request function runs is undocumented, so the root is made to work either way: this setting answers it if the substitution comes first, the function's rewrite answers it if the function does. Removing this leaves the root resting on the undocumented half alone."
  }

  # SPA routing, asserted as the absence of the mechanism that used to provide
  # it. The 403 and 404 mappings were removed rather than left beneath the
  # viewer-request function, because a viewer-request function cannot know
  # whether a key exists: every request it declines to rewrite is a request for
  # a file, and one that fell through to a 403 mapping would come back as
  # index.html with a 200 — the exact trap the function exists to close.
  #
  # Written as a length rather than as a loop over the responses, and the
  # difference is not stylistic. `alltrue([])` is `true`, so an assertion of the
  # form "every custom error response satisfies X" passes vacuously the moment
  # the block is gone, and would have gone on reporting green over the design it
  # was written to check. A length is the only shape of this assertion that
  # fails when the thing it describes comes back.
  assert {
    condition     = length(aws_cloudfront_distribution.site.custom_error_response) == 0
    error_message = "The distribution must declare no custom error responses. CustomErrorResponses is defined once per distribution and applies to every cache behaviour, so any mapping that answers a deep link with the application shell answers a missing hashed asset with it too — 200 and HTML where the browser expects JavaScript."
  }

  # And the mechanism that replaced them, on the behaviour it belongs to.
  #
  # The event type and the association's presence are both known at plan time;
  # the function's ARN is not, and nothing here reads it. That is deliberate —
  # an assertion comparing an unknown value is an error rather than a weak test,
  # which the run block "cache_and_header_policies_reach_the_right_behaviours"
  # below argues at length and works around with an override. No override is
  # needed here: what a plan can see without one is that exactly one function
  # runs on the viewer request to the default behaviour, and that is the whole
  # of what this assertion claims.
  assert {
    condition     = [for association in aws_cloudfront_distribution.site.default_cache_behavior[0].function_association : association.event_type] == ["viewer-request"]
    error_message = "The default cache behaviour must carry exactly one function association, on viewer-request. It is what turns a client-side route into a request for /index.html before CloudFront consults an origin that has no such key."
  }

  # The function's own three arguments. Each is called a decision where it is
  # written, all three are literals a plan sees exactly as an apply would, and
  # until this run block nothing checked any of them.
  #
  # `runtime` first, because it is the one that fails silently. A function
  # flipped to cloudfront-js-1.0 plans, applies and serves this rewrite
  # correctly — the body is ES 5.1 — and the loss surfaces years later as an
  # edit that cannot use a language feature nobody knew was missing.
  assert {
    condition     = aws_cloudfront_function.spa_routing.runtime == "cloudfront-js-2.0"
    error_message = "The viewer-request function must pin the cloudfront-js-2.0 runtime. 1.0 is what AWS keeps for functions written before 2.0 existed and what nearly every published copy of this rewrite still carries, so an unpinned or copied runtime is one nobody chose."
  }

  # `publish` fails the other way — loudly, but only at apply, and in the wrong
  # place: only a function's LIVE stage may be associated with a behaviour, so
  # the error names the distribution rather than this argument.
  assert {
    condition     = aws_cloudfront_function.spa_routing.publish
    error_message = "The viewer-request function must be published. Only the LIVE stage of a function can be associated with a cache behaviour, so publish = false describes a function that exists and cannot be reached from the distribution that names it."
  }

  # And the one line of the body a plan can hold: the rewrite target. This
  # asserts the shape this module chose over the shape AWS publishes —
  # `request.uri = '/index.html'`, a constant, rather than `request.uri +=
  # '/index.html'`, which appends. The appending form is correct for a
  # generator emitting an index document per directory and is a 403 on every
  # deep link for a build with one index.html at the root, which is exactly the
  # edit a reader makes after finding AWS's url-rewrite-single-page-apps
  # sample. Both halves are needed: the first alone passes on a body that
  # assigns and then appends.
  assert {
    condition = (
      strcontains(aws_cloudfront_function.spa_routing.code, "request.uri = '/index.html'")
      && !strcontains(aws_cloudfront_function.spa_routing.code, "request.uri +=")
    )
    error_message = "The function must rewrite a route to the constant /index.html and must not append to the requested path. Appending is AWS's published single-page-app sample and it is written for a site with an index document in every directory; against a build with one index.html at the root it turns every deep link into a 403."
  }

  # The other half of that placement, and the one a reader is most likely to
  # undo by making the function look like a distribution-wide setting.
  #
  # A function that changed the URI on the assets behaviour would not change
  # which behaviour served the response, so an extensionless path under
  # /assets/ would be answered with the application shell carrying the assets
  # policies' `immutable` Cache-Control: a document every browser that saw it
  # holds for a year, which no invalidation can reach.
  assert {
    condition     = length(aws_cloudfront_distribution.site.ordered_cache_behavior[0].function_association) == 0
    error_message = "The /assets/* behaviour must carry no function association. Everything under it is a file, so a request for one that is not there has to reach the origin and come back refused rather than rewritten to the document."
  }

  # The default-certificate path, which is what makes this module applicable in
  # an account that owns no domain.
  assert {
    condition     = length(aws_acm_certificate.site) == 0
    error_message = "No certificate may be requested when no domain_name was given."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.viewer_certificate[0].cloudfront_default_certificate == true
    error_message = "With no domain_name the distribution must fall back to the default CloudFront certificate."
  }

  # An empty `aliases` reads back as null rather than as an empty set at plan
  # time, so the emptiness is checked through coalesce rather than by comparing
  # against toset([]) — which fails on the type rather than on the value.
  assert {
    condition     = length(coalesce(aws_cloudfront_distribution.site.aliases, toset([]))) == 0
    error_message = "With no domain_name the distribution must carry no aliases: CloudFront rejects an alias it has no certificate covering."
  }

  # The alias contract, on the path every environment here takes. The log group
  # is created through aws.us_east_1 because CloudFront's standard logging (v2)
  # control plane answers nowhere else; the bucket is the control that shows
  # this assertion can tell the two configurations apart at all.
  assert {
    condition     = aws_cloudwatch_log_group.access_logs.region == "us-east-1"
    error_message = "The access log group must be created through the aws.us_east_1 configuration. CloudFront's logging control plane answers only in us-east-1, and a delivery created anywhere else fails at apply."
  }

  assert {
    condition     = aws_s3_bucket.site.region == "eu-west-1"
    error_message = "The site bucket must be created through the default provider configuration, in the environment's own region. This is also what makes the us-east-1 assertions above mean something: if both configurations resolved to the same region, every one of them would pass regardless of how the module was wired."
  }
}

# Which cache and response headers policy each behaviour actually gets.
#
# policies.tf builds both pairs from one map so that the security headers are
# attached to both behaviours by the structure of the code rather than by
# anyone remembering to keep two blocks in step. The failure that construction
# can still have is the wiring at the other end — a behaviour pointed at the
# wrong key — and until this run block nothing checked it.
#
# It cannot be checked directly. A CloudFront policy's id is assigned by AWS, so
# at plan time both the policy's id and the behaviour's reference to it are
# unknown, and an assertion comparing two unknown values is not a weak test but
# an error ("Condition expression could not be evaluated at this time").
#
# Overriding each policy's id with a distinct literal is what makes the
# reference resolve. It is the narrowest possible use of mocking: four
# attributes that cannot exist before an apply, in the one run block that is
# about how resources refer to each other rather than about what they contain —
# what they contain is asserted in "security_headers" below, where nothing is
# overridden and the provider computes every value. Crossing the default and
# assets wires in
# cloudfront.tf turns this run block red, which is the property that makes it
# worth having.
#
# `override_during = plan` is what makes an override visible before an apply,
# and it arrived in Terraform 1.11.0 — the same floor versions.tf already
# declares for the module itself, so this suite raises nothing. Without it the
# override is applied at apply time only and the assertions below go back to
# being unevaluatable.
run "cache_and_header_policies_reach_the_right_behaviours" {
  command = plan

  override_resource {
    target          = aws_cloudfront_cache_policy.site["default"]
    override_during = plan
    values          = { id = "cache-policy-default" }
  }

  override_resource {
    target          = aws_cloudfront_cache_policy.site["assets"]
    override_during = plan
    values          = { id = "cache-policy-assets" }
  }

  override_resource {
    target          = aws_cloudfront_response_headers_policy.site["default"]
    override_during = plan
    values          = { id = "headers-policy-default" }
  }

  override_resource {
    target          = aws_cloudfront_response_headers_policy.site["assets"]
    override_during = plan
    values          = { id = "headers-policy-assets" }
  }

  assert {
    condition     = aws_cloudfront_distribution.site.default_cache_behavior[0].response_headers_policy_id == "headers-policy-default"
    error_message = "The default behaviour must carry the \"default\" response headers policy. The app repository asserts the Content-Security-Policy against a single request to \"/\" and treats the answer as describing the whole distribution, which is only true while both behaviours carry a policy from this pair."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.ordered_cache_behavior).response_headers_policy_id == "headers-policy-assets"
    error_message = "The /assets/* behaviour must carry the \"assets\" response headers policy. Losing it would leave every hashed asset — including any web worker Vite emits — served with none of the security headers this module advertises."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.default_cache_behavior[0].cache_policy_id == "cache-policy-default"
    error_message = "The default behaviour must carry the \"default\" cache policy, which revalidates the document on every request. The assets policy would hold index.html at the edge for a year."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.ordered_cache_behavior).cache_policy_id == "cache-policy-assets"
    error_message = "The /assets/* behaviour must carry the \"assets\" cache policy. The default policy would revalidate every hashed asset on every request, which is the whole cost the split-caching design exists to avoid."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site.ordered_cache_behavior).path_pattern == "/assets/*"
    error_message = "The second behaviour must match /assets/*, which is where Vite writes its content-hashed output. A pattern matching anything else would apply the immutable caching to the wrong half of the build."
  }
}

# What the two response headers policies actually contain.
#
# The run block above proves each behaviour reaches the policy meant for it and
# deliberately proves nothing about what is in that policy: it overrides the
# policies' ids, so it is a statement about references. This one overrides
# nothing, which is what lets the provider compute the header set and makes
# these assertions statements about the headers themselves. Both were invisible
# to the suite until now — deleting the whole content_security_policy block from
# policies.tf, or dropping HSTS to a 60-second max-age, left it green.
#
# Every assertion iterates over both policies rather than naming one. That is
# the property policies.tf is built to have — one map, one body, so the security
# headers reach both behaviours by construction — and the app repository depends
# on it: it asserts the Content-Security-Policy against a single request to "/"
# and treats the answer as describing the whole distribution. Asserting only the
# default policy here would go blind in exactly the same direction.
#
# It also settles, in code, whether the /assets/* policy carries the CSP. It
# does. A CSP on a JS or CSS response is inert, with one exception: a web worker
# is governed by the policy on the response that delivered its own script, and
# Vite emits workers into assets/. Under one shared body a future worker fails
# loudly against `default-src 'none'`; under a trimmed assets policy it would run
# with no policy at all, quietly outside the posture this repository advertises.
run "security_headers" {
  command = plan

  # The CSP is compared against the module's own output rather than against a
  # copy of the string. outputs.tf publishes it precisely so that nothing
  # restates it: the app repository already holds the second copy this
  # repository cannot avoid, and a third one written into a test here would pass
  # while describing a policy nobody had checked. This asserts the thing that
  # actually matters instead — that the value published to the consumers who
  # verify the live header is the value both policies were built from.
  assert {
    condition = alltrue([
      for policy in values(aws_cloudfront_response_headers_policy.site) :
      length(policy.security_headers_config[0].content_security_policy) == 1 &&
      policy.security_headers_config[0].content_security_policy[0].content_security_policy == output.content_security_policy &&
      policy.security_headers_config[0].content_security_policy[0].override
    ])
    error_message = "Both response headers policies must serve the Content-Security-Policy this module publishes as an output, with override on. The app repository refuses to deploy until the header CloudFront serves matches that output, so a policy that has lost it — or that serves something else — fails the other repository's next deploy rather than this one's pull request."
  }

  assert {
    condition = alltrue([
      for policy in values(aws_cloudfront_response_headers_policy.site) :
      length(policy.security_headers_config[0].content_type_options) == 1 &&
      policy.security_headers_config[0].content_type_options[0].override
    ])
    error_message = "Both response headers policies must send X-Content-Type-Options, which stops a browser second-guessing a Content-Type and executing a bundle served as something else."
  }

  # A year is the threshold the HSTS preload list requires, and it is asserted
  # as a floor rather than as the exact number policies.tf chose. The floor is
  # the requirement; the number is the module's to state once.
  assert {
    condition = alltrue([
      for policy in values(aws_cloudfront_response_headers_policy.site) :
      length(policy.security_headers_config[0].strict_transport_security) == 1 &&
      policy.security_headers_config[0].strict_transport_security[0].access_control_max_age_sec >= 31536000 &&
      policy.security_headers_config[0].strict_transport_security[0].override &&
      !policy.security_headers_config[0].strict_transport_security[0].preload
    ])
    error_message = "Both response headers policies must send HSTS with a max-age of at least a year and override on, and must not request preloading — a one-way door this module has no business walking through on behalf of a domain the caller owns and the module has not been told about."
  }

  # `override = true` throughout, above and here, is load-bearing rather than
  # defensive: with it false a header of the same name from the origin wins. S3
  # sends none of these today, which is exactly why a wrong value would go
  # unnoticed until the day an origin started sending one.
  assert {
    condition = alltrue([
      for policy in values(aws_cloudfront_response_headers_policy.site) :
      length(policy.custom_headers_config[0].items) == 1 &&
      one(policy.custom_headers_config[0].items).header == "Cache-Control" &&
      one(policy.custom_headers_config[0].items).override
    ])
    error_message = "Both response headers policies must send a Cache-Control header with override on. A cache policy emits nothing to the viewer — it decides only what the edge does — so without this the split-caching design is a claim the repository makes and does not deliver."
  }

  # The two values must differ, which is the whole of the split. Asserting the
  # strings themselves would be a second copy of a decision policies.tf already
  # states; asserting they are not the same catches the failure that matters,
  # which is index.html going out with the immutable assets directive and
  # sticking in every viewer's browser for a year.
  assert {
    condition = (
      one(aws_cloudfront_response_headers_policy.site["default"].custom_headers_config[0].items).value !=
      one(aws_cloudfront_response_headers_policy.site["assets"].custom_headers_config[0].items).value
    )
    error_message = "The default and assets behaviours must send different Cache-Control values. Handing the document the assets directive would cache index.html in every viewer's browser for a year, with no way to correct it short of a new hostname."
  }
}

# The optional domain, mode one: this module requests and validates the
# certificate through Route 53.
#
# No environment in this repository sets any of this, which is precisely why it
# is tested. A conditional nothing exercises is a conditional that rots between
# the commit that wrote it and the day somebody needs it.
run "custom_domain_with_a_managed_certificate" {
  command = plan

  variables {
    domain_name    = "app.example.com"
    hosted_zone_id = "Z1D633PJN98FT9"
  }

  # The one part of the custom-domain path a plan-time test genuinely can catch.
  # Everything else about it — that ACM issues the certificate, that the
  # validation record resolves, that CloudFront accepts the result — needs an
  # apply against a domain this repository does not own. That the certificate is
  # requested in us-east-1 does not, and it is also the mistake with the least
  # informative failure: a certificate in the environment's own region is a
  # perfectly valid certificate that CloudFront refuses at apply with
  # InvalidViewerCertificate, an error that names neither the region nor the
  # provider configuration that chose it.
  assert {
    condition     = aws_acm_certificate.site[0].region == "us-east-1"
    error_message = "The viewer certificate must be requested through the aws.us_east_1 configuration. CloudFront reads viewer certificates from us-east-1 only, whatever region the environment itself is in."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.aliases == toset(["app.example.com"])
    error_message = "The distribution must answer on the domain that was asked for."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.viewer_certificate[0].ssl_support_method == "sni-only"
    error_message = "A custom certificate must be served over SNI. The alternative, \"vip\", provisions dedicated edge IP addresses at roughly $600 a month to support clients that predate SNI and cannot run an ES-module build anyway."
  }
}

# The optional domain, mode two: the caller brings a certificate they issued
# themselves, which is the path for a domain whose DNS is not in Route 53 in
# this account.
run "custom_domain_with_a_supplied_certificate" {
  command = plan

  variables {
    domain_name         = "app.example.com"
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = length(aws_acm_certificate.site) == 0
    error_message = "No certificate may be requested when the caller supplied one. This module does not manage a supplied certificate's lifecycle, and requesting a second one would leave an unvalidated certificate behind on every destroy."
  }

  assert {
    condition     = aws_cloudfront_distribution.site.viewer_certificate[0].acm_certificate_arn == "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    error_message = "The distribution must attach the certificate the caller supplied."
  }
}

# The two directions of the rule that keeps the three domain variables coherent.
# certificate.tf claims these are rejected at plan time rather than left to fail
# at apply; these two run blocks are what makes that a fact rather than a
# comment.
run "a_domain_with_no_certificate_source_is_refused" {
  command = plan

  variables {
    domain_name = "app.example.com"
  }

  expect_failures = [var.domain_name]
}

run "a_certificate_source_with_no_domain_is_refused" {
  command = plan

  variables {
    hosted_zone_id = "Z1D633PJN98FT9"
  }

  expect_failures = [var.domain_name]
}

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
# The three `skip_*` arguments below are what remove that STS call, and the
# literal keys are what stop the provider looking for real ones in the
# environment, in ~/.aws or on the instance metadata endpoint. With them, this
# suite passes with no HOME, no AWS variables of any kind and every outbound
# HTTP request black-holed — which is the state a pull request from a fork runs
# in, and the reason this can be a required check at all.
#
# The keys are deliberate nonsense, and that is a second guard rather than a
# formality. Every run block here is `command = plan`; a run block that omitted
# `command` would default to apply, and against these credentials it fails
# loudly instead of reaching an account. The job in validate.yml has no AWS
# credentials configured either, so both halves have to be defeated on purpose.
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
    error_message = "The distribution must serve index.html for a request to \"/\". Without it CloudFront forwards a bucket-root request the OAC-private origin answers with a 403, and the homepage then works only by falling through the error mapping below."
  }

  # SPA routing. Both codes, because an OAC-private bucket answers a missing key
  # with 403 rather than 404, and a configuration mapping only 404 would map
  # nothing at all.
  assert {
    condition     = toset([for response in aws_cloudfront_distribution.site.custom_error_response : response.error_code]) == toset([403, 404])
    error_message = "The distribution must map exactly the 403 and 404 origin responses. 403 is the one an OAC-private bucket actually returns for a client-side route, so a mapping that covers only 404 covers nothing."
  }

  assert {
    condition = alltrue([
      for response in aws_cloudfront_distribution.site.custom_error_response :
      response.response_code == 200 &&
      response.response_page_path == "/index.html" &&
      response.error_caching_min_ttl == 0
    ])
    error_message = "Each mapped error response must return the application shell with a 200 and no edge caching. Returning the origin's status would have search engines deindex every route the application defines, and caching it would keep serving the shell for a path that has since been uploaded."
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
# every assertion on the contents of these policies belongs in a run block where
# the provider computes them. Crossing the default and assets wires in
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

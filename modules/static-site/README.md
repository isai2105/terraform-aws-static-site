# `static-site`

A private S3 bucket served through CloudFront over an Origin Access Control, with
access logging delivered to CloudWatch Logs.

```
viewer ──HTTPS──▶ CloudFront distribution ──OAC/SigV4──▶ S3 bucket (private)
                          │
                          └─ standard logging (v2) ──▶ CloudWatch Logs group
```

The bucket has no website configuration, no public read and no ACLs. The only
grant on it names the CloudFront service principal and is conditioned on this
distribution's ARN, so it is unreachable except through the distribution.

## Using it

```hcl
module "site" {
  source = "../../modules/static-site"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "example"
  environment = "stage"

  # Every environment in this repository is ephemeral, so every one of them sets
  # this. It defaults to false, which is the right default everywhere else.
  force_destroy = true
}
```

## The `aws.us_east_1` provider is required

Every caller must pass a second, aliased AWS provider configured for
`us-east-1`, whatever region the environment itself deploys to:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  # Not optional, and not a copy-paste artefact. `default_tags` belongs to one
  # provider configuration; this one inherits nothing from the block above.
  # Omitting it here creates four untagged CloudWatch Logs resources that the
  # teardown assertion cannot see. The module fails the plan if it is missing.
  default_tags {
    tags = local.tags
  }
}
```

CloudFront is a global service and its standard logging control plane answers
only in `us-east-1` — AWS requires the CloudWatch Logs delivery source, delivery
destination and delivery to be created there "even if you want to enable cross
Region delivery to another destination". The log group is created there for the
same reason, so an environment in `eu-west-1` will find its access logs in
`us-east-1`. That is expected.

The ACM certificate for the optional custom domain has the identical constraint
and uses this same alias.

## Both providers must carry `default_tags`

The module tags nothing itself. Every resource it creates *that can be tagged*
is tagged through the caller's `default_tags`, and it requires two keys of both
provider configurations it is given:

- **`Project`**, present and non-empty;
- **`Env`**, equal to the `environment` input.

This is checked at plan time and fails with the offending configuration named.
The check exists because the alternative failure is silent: the end-to-end
workflow proves a teardown was complete by asking the resource groups tagging
API for everything carrying these two tags and asserting the answer is empty, so
an untagged orphan is indistinguishable from no orphan at all. `Env` is compared
rather than merely required because an environment root copied from another one
keeps the tag it was copied with, which is how prod ends up tagged `stage`.

### Four resources cannot be tagged, and the teardown check cannot see them

`aws_cloudfront_cache_policy`, `aws_cloudfront_response_headers_policy`,
`aws_cloudfront_origin_access_control` and the certificate validation
`aws_route53_record` expose no `tags` and no `tags_all` — neither the CloudFront
API nor a Route 53 resource record set has anywhere to put them. The resource
groups tagging API returns only taggable resources, so **a leak of any of these
leaves the teardown assertion green**. That is not fixable by tagging; it is a
property of the API.

The validation record is the mildest of the four: it is created only on the
custom-domain path, it is not quota-bearing, and `allow_overwrite` means a
stranded copy is corrected by the next apply rather than blocking it. The ACM
certificate beside it **is** taggable, which is what matters, because a
certificate stuck in `PENDING_VALIDATION` is the orphan that path produces.

It matters most where the quota is tightest. This module creates four
untaggable, quota-bearing resources per environment against an account-wide cap
of **20 each** for custom cache policies (`L-7D134442`) and custom response
headers policies. The OAC quota is 100, so it is the same blindness with an
order of magnitude more headroom.

Two detectors are available, and a teardown runbook or end-to-end workflow that
relies on tags alone has neither:

- a sweep of `aws cloudfront list-cache-policies` and
  `list-response-headers-policies`, filtered by the `<name_prefix>-site-` name
  prefix;
- a manual post-destroy checklist item.

The policy names are deliberately stable — they carry `environment` but not the
bucket's random suffix — so that a leaked policy collides loudly on the next
apply of the same environment. With no tag-based detector, that collision is the
only automatic signal a previous cycle leaked.

## Naming is a contract, not a convention

The bucket is named `<name_prefix>-site-<environment>-<8 hex characters>`, and
that shape is required rather than chosen:

- the CI apply role's S3 grant is scoped to `<name_prefix>-site-*`, so a bucket
  named outside the pattern cannot be created by CI;
- that pattern is deliberately disjoint from the state bucket's
  `<name_prefix>-tfstate-<hex>`, so a role that may do anything to a site bucket
  may do nothing to the bucket holding Terraform state;
- log groups are named `/aws/vendedlogs/cloudfront/<bucket name>`, under the
  prefix AWS keeps a standing vended-log delivery policy for, and the apply role
  is scoped to that prefix too.

The random suffix is minted on every apply, and this repository destroys every
environment within the hour — so **the bucket name is different every cycle**.
Nothing downstream may hardcode it.

## Caching is split, and so are the headers

Two cache behaviours, each with its own cache policy and its own response
headers policy. The split exists because the two halves of a built SPA have
opposite requirements:

| | `/assets/*` | everything else |
|---|---|---|
| Edge (cache policy) | one year | revalidate every request |
| Browser (`Cache-Control`) | `public, max-age=31536000, immutable` | `no-cache` |
| Why | Vite emits content-hashed filenames, so a URL's content never changes | the document must always resolve to the current build |

The two columns are set by **different mechanisms**, and conflating them is the
mistake this design exists to avoid. A cache policy decides only how long
CloudFront holds an object; it emits no header to the viewer. The browser-facing
`Cache-Control` comes from the response headers policy or it does not exist at
all — without it, a returning visitor re-requests every hashed asset on every
page load while the edge happily reports a cache hit.

Both response headers policies carry the same security headers — HSTS,
`X-Content-Type-Options` and the Content-Security-Policy — from a single `local`,
attached by construction rather than by anyone keeping two blocks in step. That
matters outside this module: the app repository asserts the CSP against one
request to `/` and treats the answer as describing the whole distribution.

`X-Frame-Options` is deliberately absent. The CSP carries `frame-ancestors
'none'`, and CSP Level 2 onward requires a browser that understands it to ignore
`X-Frame-Options` entirely.

## The Content-Security-Policy is a cross-repository contract

`local.csp` is published as the `content_security_policy` output so that a test
can assert the live header against the value the policies were built from,
rather than against a second copy of the string. The end-to-end workflow reads
it that way; the environment roots re-export it.

Editing it is a **contract change, not a local one**. The app repository holds
its own copy and refuses to deploy until the header CloudFront serves matches
it, so until the same change lands there, its next deploy is refused. No
ordering avoids that window — and the window is the point.

Two limits bound what may ever go in it: CloudFront caps the header value at
1,783 characters (quota `L-E9944CCE`), which permanently forecloses a hash-based
policy; and policies **intersect, never override** (CSP3 §8.1), so an
application can only tighten this, never relax it. A `<meta http-equiv>` tag is
not an escape hatch, and one silently ignores `frame-ancestors` anyway.

## SPA routing is knowingly incomplete

Deep links work: 403 and 404 from the origin are mapped to `/index.html` with a
`200`, so a client-side route resolves in the browser. Both codes are mapped
because an OAC bucket answers a missing key with 403, not 404 — the bucket policy
grants `s3:GetObject` without `s3:ListBucket`.

**This also swallows missing assets.** `CustomErrorResponses` is defined once per
distribution and cannot be scoped to one behaviour, so a request for a missing
hashed chunk returns `200` carrying HTML where the browser expects JavaScript.
The browser throws a parse error, monitoring sees a healthy `200`, and the
failure is close to undiagnosable — which is exactly what a partial deploy
produces.

It is left this way deliberately. No plan-time test can observe it; only a live
request for a missing key can, and the end-to-end workflow is the first thing in
this repository that makes one. The commit after that demonstration replaces
both mappings with a viewer-request function, which is the only mechanism that
can tell a route from an asset before the origin is consulted.

## A placeholder is seeded by default

`seed_placeholder` (default `true`) writes a minimal `index.html` so the site is
servable the moment it is applied. Without it the failure is not a blank page:
`/` resolves to a key that does not exist, the origin returns 403, and the error
response cannot fetch its own error page either — so CloudFront hands the viewer
the original error, and every smoke-test assertion fails against infrastructure
that is in fact correct.

Its content and etag are ignored after creation, so an application deploy is
never reverted by the next `terraform apply`.

## A custom domain is optional

Left alone, the distribution serves from its own `*.cloudfront.net` hostname on
the default CloudFront certificate. That is the default because it is the only
configuration that works in an account whose owner does not happen to own a
domain — and it is what every environment in this repository uses.

Setting `domain_name` turns on the alias, the certificate and the TLS policy
together. Exactly one of two companion inputs must come with it, and which one
depends on where the domain's DNS actually lives:

| | `hosted_zone_id` | `acm_certificate_arn` |
|---|---|---|
| For | a Route 53 public zone in this account | any other DNS — a registrar, another provider, another account |
| The module | requests the certificate, writes the validation record, waits for ACM to issue it | attaches a certificate you have already issued |
| Lifecycle | created and destroyed with the environment | not managed here; survives `terraform destroy` |

```hcl
# Route 53 in this account — fully automated.
domain_name    = "app.example.com"
hosted_zone_id = "Z1D633PJN98FT9"

# DNS anywhere else — issue the certificate first, then pass its ARN.
domain_name         = "app.example.com"
acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abcd1234-..."
```

Setting `domain_name` with neither, or with both, is rejected at plan time.
So is a certificate ARN outside `us-east-1`, a zone *name* where an id belongs,
and a `domain_name` carrying a scheme or a trailing dot — each of these
otherwise fails at apply as an `InvalidViewerCertificate` on the distribution,
an error that names none of them.

One name, never a wildcard: `*.example.com` is rejected on purpose. A wildcard
certificate covers the subdomains and not the apex, so making it useful means
adding `example.com` as a subject alternative name — and this module issues no
SANs by design, which is what lets the validation record be resolved with
`one()` instead of a `for_each` over a set that does not exist until the
certificate does. Accepting a wildcard would advertise half a feature. If you
need one, issue it yourself and attach it through `acm_certificate_arn`.

Supporting only the Route 53 case would make the input narrower than it reads:
`domain_name` would mean "bring a domain hosted in Route 53 in this account".
The second mode also avoids an ordering trap the first does not have — with
external DNS the validation record cannot exist before the certificate that
nominates it, so an apply that requested and waited would block while an
operator raced to read the record out of the ACM console.

Two things follow from a certificate being attached, both handled here: TLS
below 1.2 is refused (`minimum_protocol_version = "TLSv1.2_2021"`, which is only
settable *because* there is a custom certificate — AWS pins the default one to
`TLSv1`), and viewers connect over SNI rather than a dedicated IP, which costs
roughly $600 a month and buys support for clients that predate SNI.

> **This path is plan-verified only. It has never been applied, in CI or by
> hand.** Every environment here leaves `domain_name` null, so nothing exercises
> DNS validation, a certificate/alias mismatch, or ACM's deletion lag against
> real AWS. The variable rules and the conditional wiring are checked at plan
> time and that is the whole of it. Treating a plan-time check as coverage of
> DNS validation would be worse than saying plainly that it is not.

Destroying it has one documented sharp edge: a certificate deletion can fail
with `ResourceInUseException` *after* its distribution is already gone, because
the association lingers cross-service. The provider retries for 20 minutes and
then gives up. Re-running `terraform destroy` is the fix, and a certificate left
in `PENDING_VALIDATION` is on the post-destroy checklist for the same reason.

## What this module does not do yet

- **The cross-repository contract.** The SSM parameters the app repository reads,
  and the scoped OIDC deploy role it assumes, arrive with the contract phase.

## Accepted findings

Each is suppressed inline on the resource it applies to, with the reasoning
beside it rather than in `.trivyignore`:

| Check | Resource | In short |
|---|---|---|
| `AVD-AWS-0089` | site bucket | S3 server access logging duplicates, less usefully, what CloudFront logging already records |
| `AVD-AWS-0090` | site bucket | rollback is redeploying the previous build artefact, not restoring an object version |
| `AVD-AWS-0132` | site bucket encryption | a CMK cannot be deleted synchronously, and the bucket holds public static assets |
| `AVD-AWS-0010` | distribution | logging **is** enabled; the check predates standard logging v2 and only sees the legacy `logging_config` block |
| `AVD-AWS-0011` | distribution | a WAF protects request handling this distribution does not do |
| `AVD-AWS-0017` | log group | a CMK would be the one resource a destroy cannot reclaim |

<!-- BEGIN_TF_DOCS -->
<!-- The inputs and outputs tables are generated by terraform-docs and gated in
     CI. Until that commit lands this block is intentionally empty rather than
     hand-written, so that nothing here can be stale in a way the check would
     not catch. -->
<!-- END_TF_DOCS -->

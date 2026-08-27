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
and will use this same alias when it arrives.

## Both providers must carry `default_tags`

The module tags nothing itself. Every resource it creates is tagged through the
caller's `default_tags`, and it requires two keys of both provider
configurations it is given:

- **`Project`**, present and non-empty;
- **`Env`**, equal to the `environment` input.

This is checked at plan time and fails with the offending configuration named.
The check exists because the alternative failure is silent: the end-to-end
workflow proves a teardown was complete by asking the resource groups tagging
API for everything carrying these two tags and asserting the answer is empty, so
an untagged orphan is indistinguishable from no orphan at all. `Env` is compared
rather than merely required because an environment root copied from another one
keeps the tag it was copied with, which is how prod ends up tagged `stage`.

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

## What this module does not do yet

Deliberately, in the order the repository adds them:

- **SPA routing, split caching and security headers.** The distribution
  currently uses the AWS-managed `CachingOptimized` cache policy and declares no
  custom error responses, so a deep link into a client-side route returns the
  origin's 403 rather than `index.html`. The commit that adds SPA routing
  replaces the managed policy with a `/assets/*` and default pair, adds the two
  response headers policies that carry `Cache-Control` and the CSP, and seeds a
  placeholder `index.html`.
- **A custom domain.** There is no `domain_name` input yet, so the distribution
  serves from its own `*.cloudfront.net` hostname on the default CloudFront
  certificate. This is also why `minimum_protocol_version` is not set: AWS
  requires `TLSv1` alongside the default certificate and rejects anything higher.
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

# The identity the app repository deploys with, and the one place in this
# repository where the obvious home for a piece of IAM is the wrong one.
#
# Every other role in this design lives in `bootstrap/`, because every other
# role is created once and outlives every environment. This one is declared
# here, inside the module, and that is a deliberate inversion worth the
# paragraphs it takes to justify.
#
# ---------------------------------------------------------------------------
# Why not the bootstrap
# ---------------------------------------------------------------------------
#
# The permissions below are scoped to one bucket, one distribution and three
# parameters. The bootstrap knows none of them: it runs before any environment
# exists and holds no reference to resources other roots create. It could only
# name them by pattern or by hand.
#
# Under this operating model, by hand is not merely inelegant, it is wrong
# within the hour. The site bucket carries a `random_id` suffix whose state is
# destroyed on every teardown, so a new bucket name is minted on every cycle. A
# bootstrap-authored policy naming last cycle's ARN is stale as soon as the next
# apply runs, and the failure does not surface here — it surfaces as an
# `AccessDenied` in the *other* repository's deploy job, which is the worst
# place in the whole system to debug it.
#
# Declared here, the role is created and destroyed with the environment it
# grants access to, and every ARN in its policy is an attribute of a resource in
# the same graph: `aws_s3_bucket.site.arn`, `aws_cloudfront_distribution.site.arn`,
# `values(aws_ssm_parameter.site)[*].arn`. Nothing is typed out and nothing can drift.
# That is a property of the code below rather than a wish about it — a
# string-built ARN would compile, pass every check in this repository, and fail
# on first use in the other one. It is also why the test suite asserts parameter
# *names* rather than ARNs: the ARNs need no test, because written this way they
# cannot be wrong.
#
# ---------------------------------------------------------------------------
# What it costs, since the placement is not free
# ---------------------------------------------------------------------------
#
# The role is destroyed and recreated with the environment, as everything else
# here is — and under this operating model that is every cycle, not a rare event.
# Its ARN is therefore stable only because its *name* is, so the name is part of
# the cross-repository contract, and renaming it is a breaking change to the app
# repository, not a refactor. The README says so where a consumer will read it.
#
# ---------------------------------------------------------------------------
# Four shapes below are contracts imposed by the bootstrap, and not one of them
# has a plan-time or a lint-time signal
# ---------------------------------------------------------------------------
#
# Each fails at apply, in AWS, after other resources in this module already
# exist. They are called out at their point of use as well; this list is so that
# a reader changing any of them knows there are four:
#
#   1. the permissions are an inline `aws_iam_role_policy`, never an
#      `aws_iam_policy` plus an attachment;
#   2. the role name is `react-cloudfront-app-deploy-<env>`, deliberately not
#      `${var.name_prefix}-…`;
#   3. `path` is left unset;
#   4. `permissions_boundary` is mandatory and must match the bootstrap's policy
#      ARN character for character.

# The one identity data source a module in this repository may hold, and it is
# safe for one reason: it makes no API call. It resolves from the provider
# configuration, so it answers with no credentials, no network and no account.
#
# `aws_caller_identity` is the one a reader will reach for next and it is not
# available here. Every run block in `tests/plan.tftest.hcl` is `command = plan`,
# plan reads data sources, and that suite authenticates with literal fake keys on
# purpose — so `aws_caller_identity` inside this module turns the required
# `terraform-test` check red with an STS `InvalidClientTokenId` that reads like
# an expired local session rather than a design error. No provider skip flag
# avoids it: `skip_requesting_account_id` is already set in that file and the
# data source issues its own call regardless. Identity resolution that needs an
# API call therefore lives in the environment roots, which have credentials, and
# arrives here as an input.
data "aws_partition" "current" {}

locals {
  # The app repository's name, a constant rather than an input, and that is a
  # contract rather than an economy. `bootstrap/oidc.tf` scopes both apply roles
  # to the hardcoded ARN pattern `role/react-cloudfront-app-deploy-*`, so a role
  # named anything else cannot be created by CI at all. Written once here
  # because it appears twice below — in the role name and in the trust subject —
  # and two literals are two chances to change one of them.
  app_repository = "react-cloudfront-app"

  # Deliberately *not* `${var.name_prefix}-…`, which is this module's convention
  # for every other name it composes. The bootstrap grant above is the reason,
  # and following the convention here would fail at `CreateRole` before anything
  # else was attempted.
  #
  # Simulation against both apply roles confirms the trailing `*` is a real
  # wildcard — `-dev` and `-stage-extra` are allowed too — so the exact suffix
  # is this repository's convention rather than something IAM enforces, and a
  # typo in it will not be caught at `CreateRole`. It would be caught in the
  # other repository, as a trust that matches and a role that is not the one its
  # workflow names.
  app_deploy_role_name = "${local.app_repository}-deploy-${var.environment}"

  # GitHub's immutable subject format, with the numeric owner and repository ids
  # embedded alongside the names. Repositories created after 2026-07-15 mint
  # tokens in this form only, and `react-cloudfront-app` was created for this
  # commit — a trust policy written in the older `repo:owner/name:…` shape fails
  # `AssumeRoleWithWebIdentity` on the very first deploy with an error that gives
  # no hint why. The shape is not read from documentation: `bootstrap/oidc.tf`
  # records that every subject in this design was decoded out of a real token
  # minted on a throwaway branch, and this is the same composition its
  # `local.github_subject_prefix` performs for this repository's own roles.
  #
  # `:ref:refs/heads/main` rather than an environment claim, and that carries a
  # clause the other repository has to honour: its deploy job must declare **no**
  # GitHub Environment. The environment claim REPLACES the ref claim rather than
  # appearing beside it — measured, not assumed, in the same probe — so a job
  # that names an Environment gets a subject this trust does not match, and the
  # deploy fails at the credential exchange. If that repository ever wants an
  # environment gate, this line changes with it.
  app_deploy_subject = "repo:${var.app_github_owner}@${var.app_github_owner_id}/${local.app_repository}@${var.app_github_repository_id}:ref:refs/heads/main"

  # The account the boundary policy lives in, read out of the OIDC provider ARN
  # rather than from `aws_caller_identity`, which this module cannot hold for the
  # reason the data source above gives.
  #
  # This is a parse rather than a lookup, and it is exact: every ARN has the
  # account id in its fifth colon-separated field, and the variable's validation
  # pins the whole string to
  # `arn:<partition>:iam::<12 digits>:oidc-provider/token.actions.githubusercontent.com`
  # so the field cannot be anything else. It is also the *right* account by
  # construction rather than by coincidence — the provider, the boundary policy
  # and this role are all created by the same bootstrap in the same account, and
  # an environment applied against a provider in some other account would be
  # broken long before it reached this line.
  aws_account_id = split(":", var.github_oidc_provider_arn)[4]

  # Composed, never looked up, and never re-derived.
  #
  # Not `data "aws_iam_policy"`: that needs a policy read, and neither
  # `iam:GetPolicy` nor `iam:ListPolicies` is granted to any role in
  # `bootstrap/oidc.tf`, so a lookup fails on the first pull-request plan and the
  # fix would be another hand-applied bootstrap change. Composition needs no
  # grant at all.
  #
  # Not `"${var.name_prefix}-app-deploy-boundary"` either, which is the shape the
  # bootstrap happens to use today: that would duplicate another root's naming in
  # a root that cannot see it, and the bootstrap publishes the name as the
  # `app_deploy_boundary_policy_name` output precisely so it is never re-derived.
  #
  # The result must match the bootstrap's ARN character for character, `path`
  # included — which is why that policy is pinned at `path = "/"` there and why
  # nothing here inserts a path segment. A mismatch is not a plan error; it is an
  # `AccessDenied` on `CreateRole` at apply time, from a condition that names an
  # ARN nothing in the diff mentions.
  app_deploy_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${local.aws_account_id}:policy/${var.app_deploy_boundary_policy_name}"
}

# Two conditions, never one — the same pair `bootstrap/oidc.tf` argues for at
# length. Omitting `aud` is the first of the two classic GitHub-OIDC trust policy
# mistakes: the role would then trust any token this issuer minted for this
# subject, whoever it was minted for. Wildcarding `sub` is the second and worse
# one, and nothing here does it: this subject names one repository, one owner and
# one branch, with no wildcard character in it.
#
# `StringEquals` on the subject rather than `StringLike`. The execution plan
# calls for `StringLike` here, as it did for the two roles in `bootstrap/oidc.tf`;
# that file made the same substitution and its reasoning is what this follows: with no wildcard in the value the two behave identically, but under
# `StringLike` adding a `*` is a one-character change that silently widens the
# trust, while under `StringEquals` it is a change that does not work until
# someone also changes the operator — a second, visible edit a reviewer has to
# look at. Every subject this design trusts was decoded out of a real token and
# is exact, so the wildcard operator buys nothing and costs that — and two trust
# policies in one repository disagreeing about the operator would be the more
# surprising outcome.
data "aws_iam_policy_document" "app_deploy_assume_role" {
  statement {
    sid     = "GitHubActionsDeployFromMain"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.app_deploy_subject]
    }
  }
}

resource "aws_iam_role" "app_deploy" {
  name        = local.app_deploy_role_name
  description = "Assumed by ${var.app_github_owner}/${local.app_repository} from refs/heads/main to deploy into the ${var.environment} environment. Created and destroyed with that environment."

  assume_role_policy = data.aws_iam_policy_document.app_deploy_assume_role.json

  # `path` is deliberately absent, and this is the one of the four contracts that
  # IAM itself enforces. A role at `/app/` has the ARN
  # `role/app/react-cloudfront-app-deploy-<env>`, which does not match the
  # bootstrap's `role/react-cloudfront-app-deploy-*` pattern — simulation returns
  # `implicitDeny` for it. There is no default to state explicitly here: the
  # provider omits the field, and writing `path = "/"` would be a value this
  # module then owned for no reason.

  # Mandatory, not defensive. `iam:CreateRole` on both apply roles is granted
  # only inside a `StringEquals` condition on the `iam:PermissionsBoundary`
  # context key — live simulation returns `allowed` with the key set to this ARN
  # and `implicitDeny` without it — so a role declared here without a boundary
  # cannot be created by CI, and since 2026-09-01 cannot be created by the local
  # operator identity either.
  #
  # What it buys is not this role's own safety: the inline policy below is
  # already minimal. It caps what this role could ever be made to hold if that
  # policy were rewritten by someone who had acquired an apply credential —
  # `PutRolePolicy` is granted on this ARN, and without a ceiling an
  # Administrator inline policy on a role trusted by an attacker-chosen OIDC
  # subject is one API call away.
  permissions_boundary = local.app_deploy_boundary_arn

  # An hour is longer than any deploy this role performs and shorter than a
  # token that outlives the job it was minted for. Stated rather than inherited,
  # as the bootstrap's roles state it, because the number is a decision.
  max_session_duration = 3600

  # Tags arrive from the caller's provider `default_tags`, as they do for every
  # other taggable resource here — an IAM role is taggable, so a role stranded by
  # a failed teardown is visible to the end-to-end assertion that queries on
  # Project and Env.
}

# One statement per resource level rather than one statement listing every ARN.
#
# `s3:ListBucket` is a bucket-level action and `s3:PutObject` an object-level
# one, so a single statement naming both ARNs would grant each action on a
# resource it cannot act on — noise that reads like breadth. Split, each line
# says exactly what it means.
#
# What is absent is as deliberate as what is here:
#
#   - **No `s3:DeleteObject`.** The deploy never passes `--delete` and never
#     removes an object, by design: old hashed assets have to outlive cached
#     copies of the `index.html` that references them, or a viewer holding the
#     previous HTML gets a ChunkLoadError mid-session. A permission for a call
#     the pipeline does not make is a permission an attacker makes it with.
#   - **No `kms:Decrypt`.** The three parameters are published as `String`, not
#     `SecureString`, so no decrypt is required — and the test suite asserts that
#     type precisely so this omission stays safe. Flipping one to `SecureString`
#     would not fail in this repository; it would fail in the app repository's
#     next deploy, naming a KMS key nobody had thought about.
#   - **No `s3:GetObject`.** `aws s3 sync` compares the destination by listing
#     it, not by reading it back.
#
# ---------------------------------------------------------------------------
# This document is only half of what the role can do, and the other half is in a
# repository — a root, rather — that this one cannot read
# ---------------------------------------------------------------------------
#
# The role above carries a permissions boundary, so its effective permissions are
# the *intersection* of the five actions below and
# `data "aws_iam_policy_document" "app_deploy_boundary"` in bootstrap/oidc.tf.
# Today all five fall inside it: `s3:PutObject` under that document's
# `s3:*Object*`, `s3:ListBucket` explicitly, `cloudfront:CreateInvalidation`
# explicitly, `cloudfront:GetInvalidation` under `cloudfront:Get*`, and
# `ssm:GetParameter` under `ssm:Get*` on `parameter/static-site/*`; neither of
# its two denies touches any of them.
#
# Nothing enforces that, here or there. `local.app_deploy_boundary_arn` is
# *composed* from a policy name, for the reason stated where it is built — no
# role in bootstrap/oidc.tf is granted `iam:GetPolicy` or `iam:ListPolicies`, so
# a lookup would fail on the first pull-request plan. This module therefore knows
# the boundary's ARN and has never seen its contents. A sixth action added below
# that the boundary does not permit plans clean, applies clean, produces a role
# whose inline policy names a permission it does not effectively hold, and fails
# for the first time in the app repository's deploy job. Narrowing a verb family
# in bootstrap/oidc.tf breaks these five the same way, from the other side, and
# is even quieter: a policy body edit is a new version applied in place, with no
# role in the diff at all.
#
# A static subset-checker was considered and rejected. IAM's wildcard semantics
# — `*Object*` matching mid-token, `Get*` as a prefix, resource wildcards
# spanning `/` — are fiddly enough that a half-correct implementation would pass
# on exactly the day it mattered, and false confidence is worse than none. The
# enforcement is the app repository's first deploy, which exercises all five
# end-to-end with a real token. It has to be: the trust above names no AWS
# principal, so this role cannot be assumed by hand and nothing in this
# repository can rehearse it. Change either document and deploy stage.
# docs/DEPLOY_CONTRACT.md section 7 states this as the interface it is.
data "aws_iam_policy_document" "app_deploy" {
  statement {
    sid       = "UploadSiteObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  # What `aws s3 sync` needs to decide which objects to upload: it lists the
  # destination prefix and compares, rather than reading objects back.
  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  # `GetInvalidation` alongside `CreateInvalidation`, and the second one is not
  # padding. The deploy waits for the invalidation with
  # `aws cloudfront wait invalidation-completed`, and that waiter polls
  # `GetInvalidation`; a role granted only `CreateInvalidation` fails there with
  # an `AccessDenied` *after* the upload has already landed, which is the one
  # failure mode that leaves the environment half-deployed.
  statement {
    sid     = "InvalidateDistribution"
    effect  = "Allow"
    actions = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]

    resources = [aws_cloudfront_distribution.site.arn]
  }

  # The three published parameters, taken from the resource rather than restated
  # as ARNs. `values(...)[*].arn` also means a fourth parameter added to ssm.tf
  # is readable by this role automatically — which is the correct default here,
  # because anything published at that path is published *for* this consumer.
  statement {
    sid       = "ReadPublishedParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = values(aws_ssm_parameter.site)[*].arn
  }
}

# Inline, never an `aws_iam_policy` plus an attachment, and this is the contract
# with the least visible failure of the four. `iam:CreatePolicy` is absent from
# both apply roles — `bootstrap/oidc.tf` calls that "a contract rather than an
# oversight" — while `CreatePolicyVersion` and `SetDefaultPolicyVersion` are
# explicitly denied. A managed policy would fail after the role itself already
# existed, leaving a half-applied environment, and it would break `plan` too,
# which cannot read managed policies either.
#
# Inline is the right shape here anyway: the policy and the role have identical
# lifetimes, so it is deleted with the role instead of being left behind as an
# orphan for the teardown checklist to find.
resource "aws_iam_role_policy" "app_deploy" {
  name   = "deploy"
  role   = aws_iam_role.app_deploy.id
  policy = data.aws_iam_policy_document.app_deploy.json
}

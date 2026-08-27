# The identity half of the bootstrap: who GitHub Actions is allowed to be in
# this account, and what each of those identities may then do.
#
# There are no long-lived AWS access keys anywhere in either repository. CI
# authenticates by exchanging the OIDC token GitHub mints for the running job,
# which means the credential is scoped to a single workflow run, expires with
# it, and cannot be copied out of the repository settings because it was never
# stored there.
#
# Two roles rather than one, because the two things CI does have different
# blast radii and different triggers. `plan` runs on every pull request, from
# any branch, and reads. `apply` runs only from a job that has named a GitHub
# Environment, and writes. Collapsing them would mean every pull request in the
# repository carried the credential that can destroy production.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# The identity provider itself.
#
# `thumbprint_list` is deliberately not set. It is Optional+Computed in the
# provider, so omitting it leaves whatever AWS itself resolves rather than
# writing a value this repository would then own. Since 2023 IAM validates this
# specific issuer against its own trusted CA store and no longer relies on the
# pinned thumbprint, so a hardcoded value here is not a control — it is a
# 40-character constant that goes stale silently on a CA rotation, and the
# failure mode is every CI run in the repository losing the ability to
# authenticate at once. Copying one out of a blog post is how that happens.
#
# An AWS account can hold exactly one provider per issuer URL. An account that
# already has this one — because something else in it already uses GitHub OIDC
# — must import it rather than apply over it:
#
#   terraform -chdir=bootstrap import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
#
# docs/BOOTSTRAP.md carries that as a runbook step; a cloner hitting
# EntityAlreadyExists on their first apply otherwise has no way to know it is
# recoverable.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience the workflows request and the value both trust policies below
  # assert. Restricting it here as well is defence in depth: a role whose trust
  # policy forgot the `aud` condition still cannot be assumed with a token
  # minted for a different audience.
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # The subject prefix GitHub actually puts in the token, in the immutable
  # format: the numeric owner and repository IDs are embedded alongside the
  # names, and cannot be removed even with claim customisation. Repositories
  # created after 2026-07-15 — this one was created on 2026-08-26 — mint tokens
  # in this form only. A trust policy written in the older `repo:owner/repo:...`
  # shape fails AssumeRoleWithWebIdentity on the very first CI run, with an
  # error message that gives no hint why.
  #
  # This is not inferred from documentation. Before this file was written, a
  # throwaway branch minted a token in each of the three shapes below and
  # printed the decoded claims; every subject here is a value that was read out
  # of a real token rather than assembled from a guess.
  github_subject_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}"

  # Observed: repo:...@.../...@...:pull_request
  #
  # No ref component at all — the pull_request subject is a bare suffix, which
  # is why it needs no wildcard.
  plan_role_subject = "${local.github_subject_prefix}:pull_request"

  # Observed: repo:...@.../...@...:environment:oidc-claim-probe
  #
  # The environment form REPLACES the ref component rather than appearing
  # alongside it — confirmed on both a push-triggered and a pull_request-
  # triggered run, whose `ref` claims differed while their `sub` claims were
  # identical. The whole apply-role design rests on that being true, which is
  # why it was measured rather than assumed, and it has a corollary that has to
  # live somewhere else: a branch restriction cannot be expressed in IAM at the
  # same time as an environment restriction, because the ref is simply not in
  # the subject any more. It lives in each GitHub Environment's deployment
  # branch policy instead.
  apply_role_subjects = [
    for environment in var.environments :
    "${local.github_subject_prefix}:environment:${environment}"
  ]

  # The layout of the state bucket, in one place. The consuming roots are
  # pointed at `<env>/terraform.tfstate` by the init command outputs.tf emits,
  # and the two must agree or the policies below grant access to keys nothing
  # writes.
  state_object_arns = [
    for environment in var.environments :
    "${aws_s3_bucket.state.arn}/${environment}/terraform.tfstate"
  ]

  # Native S3 locking writes `<key>.tflock` beside the state object and deletes
  # it when the run finishes. These are siblings of the ARNs above, not children
  # of them, which is the property the deny statement further down depends on.
  state_lock_arns = [
    for environment in var.environments :
    "${aws_s3_bucket.state.arn}/${environment}/terraform.tfstate.tflock"
  ]

  # The namespace the site buckets live in.
  #
  # A site bucket's name is not knowable here: the module mints it with a
  # random suffix, and a fresh one is minted on every cycle because the state
  # that remembered the last one was destroyed. So the grant has to be a
  # pattern, and a pattern is only least privilege if it excludes the things it
  # should not cover. `<prefix>-*` would also match the state bucket
  # `<prefix>-tfstate-<hex>`, handing the apply role bucket-level control over
  # the one bucket the whole design depends on surviving.
  #
  # Naming site buckets under their own infix is what keeps the two namespaces
  # disjoint, so this is a contract the static-site module has to honour rather
  # than a convenience. It is published as an output for exactly that reason.
  site_bucket_prefix = "${var.name_prefix}-site"

  site_bucket_arns = [
    "arn:${data.aws_partition.current.partition}:s3:::${local.site_bucket_prefix}-*",
    "arn:${data.aws_partition.current.partition}:s3:::${local.site_bucket_prefix}-*/*",
  ]

  # Resource ARNs for the services the environments create. Written out here so
  # the two policies below cannot disagree about what "this repository's
  # resources" means.
  ssm_parameter_arn_pattern = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/static-site/*"

  # The app repository's deploy role, which the static-site module creates and
  # destroys with the environment it grants access to. Named, not wildcarded
  # across IAM: this is the only role either CI identity may touch.
  app_deploy_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/react-cloudfront-app-deploy-*"

  # The log groups CloudFront access logs are delivered into.
  #
  # Pinned to us-east-1 rather than to var.aws_region, and that is a property of
  # CloudFront rather than a choice made here: CloudFront is a global service
  # whose standard logging (v2) control plane answers only in us-east-1, so the
  # delivery source, delivery destination and delivery are us-east-1 resources
  # whatever region the environment lives in — and a CloudWatch Logs destination
  # has to be in the same region as the delivery destination that names it.
  # Scoping this grant to var.aws_region would deny the one region the module can
  # legally use.
  #
  # The `/aws/vendedlogs/` prefix is the one AWS keeps a standing account-level
  # resource policy for, which is why the module names its groups under it.
  # Scoping this grant to the same prefix means CI can create the log groups this
  # repository needs and no others.
  access_log_group_arns = [
    "arn:${data.aws_partition.current.partition}:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/vendedlogs/cloudfront/${local.site_bucket_prefix}-*",
    "arn:${data.aws_partition.current.partition}:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/vendedlogs/cloudfront/${local.site_bucket_prefix}-*:*",
  ]

  # The distributions whose logs may be delivered, for the source-side half of
  # vended-log delivery below.
  #
  # No region, and the empty field is correct rather than a typo: CloudFront is
  # global and AWS documents the distribution ARN as
  # `arn:aws:cloudfront::<account>:distribution/<id>`. The two colons are the
  # region field, present and empty.
  #
  # `distribution/*` rather than a named id, because a distribution id is
  # assigned by AWS and a fresh one is minted on every cycle — the same reason
  # the site bucket grant is a prefix pattern. It could be tightened further
  # with an `aws:ResourceTag/Project` condition, which this resource type
  # supports; that is deliberately not done here because it would make the grant
  # depend on tag propagation having completed at the instant PutDeliverySource
  # is called, turning a permission problem into an intermittent one. The
  # neighbouring CloudFront grant already accepts account-wide scope for the
  # same operating-model reason it states.
  site_distribution_arns = [
    "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*",
  ]
}

# ---------------------------------------------------------------------------
# The plan role — read-only, assumed from pull requests
# ---------------------------------------------------------------------------

# Two conditions, never one.
#
# Omitting `aud` is the first of the two classic GitHub-OIDC trust policy
# mistakes: without it the role trusts any token this issuer minted for this
# subject regardless of who it was minted for. Wildcarding `sub` is the second,
# and it is worse — `repo:owner/name:*` trusts every branch, every tag, every
# environment and every pull request in the repository at once, which is the
# same as trusting anyone who can open a pull request.
#
# StringEquals rather than StringLike on the subject. The plan calls for
# StringLike, and with no wildcard characters in the value the two operators
# behave identically — but they are not equally safe to edit. Under StringLike,
# adding a `*` to this string is a one-character change that silently widens
# the trust; under StringEquals it is a change that does not work until someone
# also changes the operator, which is a second, visible edit that a reviewer
# has to look at. Every subject this repository trusts was read out of a real
# token and is exact, so the wildcard operator buys nothing and costs that.
data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    sid     = "GitHubActionsPullRequest"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.plan_role_subject]
    }
  }
}

resource "aws_iam_role" "plan" {
  name        = "${var.name_prefix}-ci-plan"
  description = "Read-only role assumed by pull-request CI to run terraform plan."

  assume_role_policy = data.aws_iam_policy_document.plan_assume_role.json

  # An hour is longer than any plan in this repository takes and shorter than a
  # token that outlives the job it was minted for. The default is also one hour;
  # it is stated rather than inherited because the number is a decision.
  max_session_duration = 3600
}

# Read permissions, hand-rolled rather than the AWS-managed ReadOnlyAccess.
#
# The managed policy is the conventional choice and it has a real advantage:
# it cannot go stale. A hand-written read list breaks the day the AWS provider
# starts calling a Describe nobody anticipated, and a broken plan is a blocked
# pull request.
#
# It loses anyway, because of which role this is. `plan` is trusted on the
# pull_request subject, so it is assumable from any branch in this repository
# by anyone who can open a pull request — the most exposed trigger there is.
# ReadOnlyAccess on that role means every object in every bucket in the account,
# every parameter and every configuration, readable by a workflow file edited on
# a branch. The failure mode of being too narrow is a red check naming the action
# that was denied, which is loud, diagnosable and fixed by one line. The failure
# mode of being too broad leaves no trace at all.
#
# The same argument decides the shape of the statements below, and it is worth
# stating because it is easy to write a hand-rolled policy that quietly gives up
# the advantage it was written for. A verb wildcard is used only where the
# resource is already scoped to something this repository owns. Where the
# resource has to be `*` — because the API supports no resource-level condition
# — the actions are enumerated instead. `ssm:Get*` on `*` would have handed this
# role every parameter in the account, which is the exact thing ReadOnlyAccess
# was rejected for.
data "aws_iam_policy_document" "plan_read" {
  # CloudFront and ACM: read-only, and unscopable. CloudFront's list operations
  # accept no resource-level condition, and the provider refreshes a
  # distribution by listing before it gets. Neither service holds application
  # data — a certificate read returns the public certificate, never the private
  # key — so the account-wide read here is configuration, not content.
  statement {
    sid    = "ReadCdnAndCertificates"
    effect = "Allow"

    actions = [
      "acm:Describe*",
      "acm:Get*",
      "acm:List*",
      "cloudfront:Describe*",
      "cloudfront:Get*",
      "cloudfront:List*",
      "tag:Get*",
    ]

    resources = ["*"]
  }

  # Route 53 splits across two ARN namespaces and one unscopable list: zone
  # contents are read against the zone, a change is polled against the change
  # id, and finding a zone by name is an account-level operation.
  statement {
    sid    = "ReadDnsZoneContents"
    effect = "Allow"

    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/*"]
  }

  statement {
    sid    = "ResolveDnsZonesAndChanges"
    effect = "Allow"

    actions = [
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]

    resources = ["*"]
  }

  # Log delivery, enumerated rather than `logs:Get*`. The delivery APIs accept
  # no resource-level condition, and the wildcard form would have carried
  # logs:GetLogEvents with it — the contents of every log group in the account,
  # granted to a role assumable from any pull request, to refresh three
  # configuration resources.
  statement {
    sid    = "ReadLogDelivery"
    effect = "Allow"

    actions = [
      "logs:DescribeDeliveries",
      "logs:DescribeDeliveryDestinations",
      "logs:DescribeDeliverySources",
      # An account-level list operation that rejects a resource-level
      # constraint. It returns log group names and metadata, never log contents
      # — the actions that read those are deliberately absent from this role.
      "logs:DescribeLogGroups",
      "logs:GetDelivery",
      "logs:GetDeliveryDestination",
      "logs:GetDeliveryDestinationPolicy",
      "logs:GetDeliverySource",
      "logs:ListTagsForResource",
    ]

    resources = ["*"]
  }

  # The three contract parameters, scoped to the prefix this repository owns.
  # ssm:DescribeParameters is a separate statement because it is an account-level
  # list operation that rejects a resource-level constraint — and, unlike
  # GetParameter, it returns metadata rather than values.
  statement {
    sid    = "ReadContractParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListTagsForResource",
    ]

    resources = [local.ssm_parameter_arn_pattern]
  }

  statement {
    sid       = "ListParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadThisRepositoryBuckets"
    effect = "Allow"

    actions = [
      "s3:Get*",
      "s3:List*",
    ]

    resources = concat(
      local.site_bucket_arns,
      [aws_s3_bucket.state.arn],
      local.state_object_arns,
    )
  }

  # The module reads the OIDC provider back through a data source rather than
  # being handed its ARN in a committed tfvars, because that ARN embeds the
  # account id. Plan therefore has to be able to read it.
  statement {
    sid    = "ReadCiIdentity"
    effect = "Allow"

    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
    ]

    resources = [
      aws_iam_openid_connect_provider.github.arn,
      local.app_deploy_role_arn,
    ]
  }
}

# The backend permissions, exactly as the state bucket's own permission model
# specifies them: read on state, read/write/delete on the lock beside it.
#
# `s3:DeleteObject` on the lock is what lets a run release a lock it took. It
# is granted on the `.tflock` keys and nowhere else.
data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = local.state_object_arns
  }

  statement {
    sid    = "HoldAndReleaseStateLock"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = local.state_lock_arns
  }

  # "Plan needs state write" is broader than it sounds, and this is the statement
  # that refuses it.
  #
  # A plan that refreshes takes the lock, so it genuinely needs to write the
  # `.tflock` object. It never needs to write the state object. Granting both
  # is enough for a workflow file edited on a branch to overwrite state for
  # every environment at once — and pull_request workflows run from the pull
  # request head, so the attacker-controlled file and the credential arrive in
  # the same job. Fork pull requests are not the exposure here: GitHub mints no
  # OIDC token for a fork pull request on a public repository. Same-repo
  # branches are, and they are the ordinary case.
  #
  # Nothing above grants these actions, so this deny is not load-bearing today
  # — it is load-bearing against the future edit that attaches something broader
  # to this role. An explicit deny cannot be overridden by any allow, so the
  # withholding survives that edit rather than depending on nobody making it.
  #
  # The resource list is the exact state object ARNs with no trailing wildcard,
  # and that is not stylistic. `<key>.tflock` is a sibling of `<key>`, not a
  # child of it, so an ARN written as `.../terraform.tfstate*` would match the
  # lock as well and deny the one write this role has to be able to make —
  # breaking every plan in the repository with an error that points at the deny
  # rather than at the wildcard.
  statement {
    sid    = "DenyStateMutation"
    effect = "Deny"

    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]

    resources = local.state_object_arns
  }
}

resource "aws_iam_role_policy" "plan_read" {
  name   = "read"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_read.json
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ---------------------------------------------------------------------------
# The apply role — writes, assumed only from a job that named an Environment
# ---------------------------------------------------------------------------

# Scoped by environment name, not by ref, because the environment claim replaces
# the ref claim (see local.apply_role_subjects). One condition value per
# environment, so the set of things this role may be assumed from is a list
# somebody has to edit rather than a pattern that quietly grows.
#
# This is also what makes prod's required reviewer real: the reviewer gate is a
# property of the GitHub Environment, and a job that does not declare the
# environment gets a subject that does not appear in this list and fails
# AssumeRoleWithWebIdentity outright.
data "aws_iam_policy_document" "apply_assume_role" {
  statement {
    sid     = "GitHubActionsEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.apply_role_subjects
    }
  }
}

resource "aws_iam_role" "apply" {
  name        = "${var.name_prefix}-ci-apply"
  description = "Role assumed by environment-gated CI to apply and destroy an environment."

  assume_role_policy = data.aws_iam_policy_document.apply_assume_role.json

  # Longer than plan's, because credentials that expire mid-destroy leave the
  # distribution half-removed and the state lock held — the failure walked in
  # docs/TEARDOWN.md section 5.
  #
  # The number is headroom, not a measurement. An earlier version of this
  # comment justified it with a 15-to-20 minute CloudFront teardown, which was
  # inherited rather than observed: measured on 2026-08-27 across three
  # distributions, a distribution tears down in about three minutes and a
  # whole 17-resource environment in about the same, so this ceiling is
  # roughly forty times what a destroy needs. It stays at two hours, because the
  # provider's own waiter runs to 90 minutes, a slow day at AWS costs nothing
  # to survive, and the only thing a lower ceiling would buy is a shorter
  # window on a credential that is already scoped to one environment and one
  # workflow run. docs/TEARDOWN.md carries the measurement and its date.
  #
  # Reachable only through AssumeRoleWithWebIdentity, which is how CI assumes
  # this role. A role assumed from another session is capped by AWS at one hour
  # whatever this says.
  max_session_duration = 7200
}

# What apply may do to the state backend, which is the one place it needs more
# than plan: it writes state.
#
# `s3:DeleteObject` on the state object is deliberately absent. Terraform empties
# state on destroy by writing an empty state file, not by deleting the object,
# and the only operation that deletes it is deleting a workspace — something
# nothing in this repository does. If that ever changes it should fail with a
# named AccessDenied rather than have been granted years earlier on a guess.
data "aws_iam_policy_document" "apply_state" {
  statement {
    sid    = "ReadAndWriteState"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = local.state_object_arns
  }

  statement {
    sid    = "HoldAndReleaseStateLock"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = local.state_lock_arns
  }

  # The S3 backend lists the bucket during init.
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # The state bucket is created by this root and must outlive every environment
  # cycle. Apply has no business reconfiguring or removing it, and the grant
  # above is object-level only — but the site-bucket grant further down is a
  # name pattern, and a pattern is exactly the thing that acquires an unintended
  # match later. Denying the bucket-level mutations on this one bucket ARN makes
  # that structural.
  #
  # Bucket ARN only, without `/*`: object operations are authorised against the
  # object ARN, so this cannot reach the state and lock grants above.
  statement {
    sid    = "DenyStateBucketReconfiguration"
    effect = "Deny"

    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]

    resources = [aws_s3_bucket.state.arn]
  }
}

# What apply may do to the infrastructure the environments actually describe.
#
# Derived service by service from what this repository creates, rather than from
# a managed policy that happens to cover it. Everything absent is absent on
# purpose: there is no EC2, no VPC, no RDS, no Lambda and no KMS here, and the
# day one of those is added this policy should be the thing that says so.
data "aws_iam_policy_document" "apply_infrastructure" {
  # The site bucket and its contents.
  #
  # `s3:*` on a resource this narrow rather than an enumerated action list, and
  # the trade is deliberate: the AWS provider touches roughly thirty distinct S3
  # actions across creating, refreshing and destroying a bucket and its eight
  # sub-resources, the list grows with every provider release, and a missing
  # GetBucketNotification breaks an apply the same way a missing CreateBucket
  # does. The control that matters is which buckets, not which verbs, and the
  # resource pattern here is a namespace this repository owns outright — kept
  # disjoint from the state bucket by local.site_bucket_prefix.
  statement {
    sid       = "ManageSiteBuckets"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = local.site_bucket_arns
  }

  # CloudFront: the distribution, its origin access control, the two cache
  # policies, the two response headers policies, and the viewer-request
  # function.
  #
  # Enumerated rather than wildcarded, because here the resource cannot be
  # narrowed and the actions can. CloudFront's create operations do not support
  # resource-level conditions at all, so this role can create these resource
  # types anywhere in the account — which is acceptable only because the
  # operating model gives this repository its own account, and which the
  # README's tradeoffs section says out loud. What the enumeration does buy is
  # excluding the CloudFront surface this repository has no use for: key groups,
  # public keys, streaming distributions, realtime log configs, WAF
  # associations, and the account-level settings.
  statement {
    sid    = "ManageCloudFront"
    effect = "Allow"

    actions = [
      "cloudfront:CreateCachePolicy",
      "cloudfront:CreateDistribution",
      "cloudfront:CreateFunction",
      "cloudfront:CreateInvalidation",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:DeleteCachePolicy",
      "cloudfront:DeleteDistribution",
      "cloudfront:DeleteFunction",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:DescribeFunction",
      "cloudfront:GetCachePolicy",
      "cloudfront:GetCachePolicyConfig",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:GetFunction",
      "cloudfront:GetInvalidation",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicyConfig",
      "cloudfront:ListCachePolicies",
      "cloudfront:ListDistributions",
      "cloudfront:ListFunctions",
      "cloudfront:ListInvalidations",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:ListTagsForResource",
      "cloudfront:PublishFunction",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:UpdateCachePolicy",
      "cloudfront:UpdateDistribution",
      "cloudfront:UpdateFunction",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:UpdateResponseHeadersPolicy",
    ]

    resources = ["*"]
  }

  # The optional custom-domain path: a certificate in us-east-1 and the DNS
  # records that validate and alias it. Both are gated behind
  # `var.domain_name != null` in the module and neither has ever been applied,
  # so these grants are the least exercised in this file.
  #
  # The ACM half is split across two statements, and the split is not stylistic:
  # two AWS documents disagree about whether `acm:RequestCertificate` can be
  # scoped to a certificate ARN, and only one of them is right.
  #
  #   ACM User Guide, authen-apipermissions.html   says certificate/* or *
  #   Service Authorization Reference              resource column is EMPTY
  #
  # The Service Authorization Reference is generated from the IAM model itself
  # and is the one to believe; an empty resource column means the action
  # authorises against `*` and nothing else, so a policy naming `certificate/*`
  # matches no request and denies every one. The User Guide page is
  # hand-maintained, says otherwise, and is the page a search engine reaches
  # first — which is exactly how this was written the wrong way round once
  # already. Corroborating the Reference: AWS documents condition keys for
  # constraining certificate issuance, and its own guidance on using them pairs
  # them with `"Resource": "*"`. Condition keys exist here *because* ARN scoping
  # does not.
  #
  # The failure this split prevents is a quiet one. `plan` reads certificates
  # through ReadCdnAndCertificates on `*` and succeeds, so the mistake surfaces
  # only under `apply`, on the first ACM call, in the one code path the module
  # README states has never been applied in CI.
  statement {
    sid    = "ManageCertificates"
    effect = "Allow"

    # The six that genuinely take a certificate ARN, kept scoped.
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListTagsForCertificate",
      "acm:RemoveTagsFromCertificate",
    ]

    # A certificate for CloudFront must live in us-east-1 whatever region the
    # rest of the environment is in, so this cannot be pinned to var.aws_region.
    resources = ["arn:${data.aws_partition.current.partition}:acm:*:${data.aws_caller_identity.current.account_id}:certificate/*"]
  }

  # Requesting the certificate, which is the call that was silently denied.
  #
  # `RequestCertificate` creates the certificate, so there is no ARN to name yet.
  # What can be constrained instead is constrained: `acm:ValidationMethod` pins
  # issuance to DNS, which is what certificate.tf hardcodes and comments at
  # length. EMAIL validation sends approval mail to addresses at the requested
  # domain, so without this condition the role could make AWS send mail to
  # domains it has nothing to do with. It can never wrongly deny a legitimate
  # call here, because the module exposes no variable for the method — and if
  # someone later adds one, this denies it by name rather than letting it
  # through, which is the review this file wants that change to get.
  #
  # Named residual, because neither the enumeration nor the condition closes it:
  # `acm:DomainNames` would restrict *which* domains may be requested, and is
  # deliberately not set. The bootstrap cannot know them — the domain is a
  # per-environment module input, absent entirely in the default configuration —
  # so setting it would mean a bootstrap variable and a bootstrap re-apply every
  # time an environment's domain changed, to constrain a path that has never
  # been applied. What stays open is requesting a DNS-validated certificate for
  # an arbitrary domain: it issues nothing without control of that domain's DNS,
  # and it consumes the account's certificate-request quota.
  statement {
    sid       = "RequestCertificates"
    effect    = "Allow"
    actions   = ["acm:RequestCertificate"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "acm:ValidationMethod"
      values   = ["DNS"]
    }
  }

  # Its own statement, because the condition above would deny it.
  #
  # `ListCertificates` is an account-level enumeration that carries no
  # ValidationMethod key, and an IAM condition on an absent key evaluates false —
  # so folding this in above would have replaced one silent denial with another.
  # Nothing in the module calls it today: the provider refreshes a certificate by
  # ARN through DescribeCertificate, never by listing. It is granted because a
  # certificate data source is the ordinary next step on this path, and because a
  # read-only enumeration of certificate metadata is the least of what this role
  # already holds — not because anything currently needs it.
  statement {
    sid       = "ListCertificates"
    effect    = "Allow"
    actions   = ["acm:ListCertificates"]
    resources = ["*"]
  }

  statement {
    sid    = "ManageDnsRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/*"]
  }

  # ChangeResourceRecordSets returns a change id that the provider polls until
  # the change is INSYNC, and that poll is authorised against a different ARN
  # namespace. Zone lookup by name is likewise not resource-scopable.
  statement {
    sid    = "ResolveDnsChangesAndZones"
    effect = "Allow"

    actions = [
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]

    resources = ["*"]
  }

  # The cross-repository contract: three String parameters per environment,
  # under a prefix this repository owns.
  statement {
    sid    = "ManageContractParameters"
    effect = "Allow"

    actions = [
      "ssm:AddTagsToResource",
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListTagsForResource",
      "ssm:PutParameter",
      "ssm:RemoveTagsFromResource",
    ]

    resources = [local.ssm_parameter_arn_pattern]
  }

  # ssm:DescribeParameters is an account-level list operation and rejects a
  # resource-level constraint.
  statement {
    sid       = "ListParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # CloudFront standard logging v2, which is vended-log delivery rather than the
  # legacy bucket-ACL path — the delivery source, destination and the link
  # between them are all CloudWatch Logs resources even when the logs land in
  # S3. None of these APIs supports resource-level conditions.
  #
  # The destination-policy actions are here because a delivery to S3 needs one.
  #
  # The module has since chosen its destination — CloudWatch Logs, so that a
  # teardown never has to empty a log bucket that is still receiving deliveries —
  # so the log *group* management this statement once deferred is granted below,
  # scoped to the ARN pattern the module names its groups under rather than to
  # the account.
  #
  # None of the delivery APIs supports a resource-level condition, which is why
  # this statement is `*` and the actions are enumerated instead.
  #
  # The CloudWatch Logs half is not sufficient on its own — see the statement
  # directly below, which is the half a plan cannot discover.
  statement {
    sid    = "ManageLogDelivery"
    effect = "Allow"

    actions = [
      "logs:CreateDelivery",
      "logs:DeleteDelivery",
      "logs:DeleteDeliveryDestination",
      "logs:DeleteDeliveryDestinationPolicy",
      "logs:DeleteDeliverySource",

      # In AWS's documented ListAccessForLogDeliveryActions set alongside the
      # three Describe* calls below. This apply never reached it — it failed one
      # call earlier — so it is granted on the documentation's authority rather
      # than on an observed denial, and that is stated rather than glossed:
      # discovering it later costs another failed apply, for a list-only action
      # over AWS-published delivery templates that exposes nothing.
      "logs:DescribeConfigurationTemplates",
      "logs:DescribeDeliveries",
      "logs:DescribeDeliveryDestinations",
      "logs:DescribeDeliverySources",
      "logs:GetDelivery",
      "logs:GetDeliveryDestination",
      "logs:GetDeliveryDestinationPolicy",
      "logs:GetDeliverySource",
      "logs:ListTagsForResource",
      "logs:PutDeliveryDestination",
      "logs:PutDeliveryDestinationPolicy",
      "logs:PutDeliverySource",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:UpdateDeliveryConfiguration",
    ]

    resources = ["*"]
  }

  # The source-side half of vended-log delivery, and the half no plan can find.
  #
  # PutDeliverySource is a CloudWatch Logs call, but AWS authorises it against
  # the service that *owns the resource being logged* as well: some services
  # require "explicit authorization that customers are allowed to send logs from
  # their resources, as an additional layer of security", expressed as a
  # permission-only action named <service>:AllowVendedLogDeliveryForResource.
  # CloudFront is one of them. Without this the call fails with an
  # AccessDeniedException naming a cloudfront: action, from an API in a
  # different service, on a role whose logs: grants are complete.
  #
  # It is permission-only in the strict sense: it appears in CloudFront's
  # Service Authorization Reference with IsPermissionManagement set and in none
  # of its Operations, so no CloudFront API call maps to it and nothing but an
  # identity policy can grant it. Its one resource type is `distribution`, which
  # is why this is scoped rather than `*`.
  #
  # This is the first defect in this repository that only a real apply could
  # find, and the reason is worth keeping: `terraform plan` was clean for both
  # environments against this exact role. A plan never calls PutDeliverySource,
  # so no amount of planning, linting or scanning could have reached it. It cost
  # a 15-resource partial apply to discover.
  statement {
    sid    = "ServiceLevelAccessForLogDelivery"
    effect = "Allow"

    actions   = ["cloudfront:AllowVendedLogDeliveryForResource"]
    resources = local.site_distribution_arns
  }

  # Vended log delivery authorises itself through an account-level CloudWatch
  # Logs resource policy — the standing `/aws/vendedlogs/*` entry AWS maintains —
  # and the delivery APIs read and update it on the caller's behalf. Every action
  # here is account-level and rejects a resource-level constraint, which is why
  # this statement is `*` where the one below is scoped: logs:DescribeLogGroups
  # is a list operation over the account, and a resource policy has no ARN to
  # name at all.
  #
  # The residual risk, named rather than left to be discovered. CloudWatch Logs
  # resource policies are account-scoped objects with no ARN to condition on, so
  # logs:PutResourcePolicy on `*` is the only form this grant has — and it lets
  # this role overwrite any resource policy in the account, including one that
  # admits log delivery from a different account. Nothing narrows that; the
  # enumeration above only keeps the grant to the two verbs the delivery APIs
  # actually call. What bounds it is that this role is assumable solely from a
  # job that has named a GitHub Environment, and that a policy overwritten here
  # would be restored by the next apply of the environment that owns it. A
  # deployment where CloudWatch Logs carries data from more than this repository
  # should move these two actions to a separate role and grant them only for the
  # duration of an apply.
  statement {
    sid    = "ManageVendedLogDeliveryPolicy"
    effect = "Allow"

    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeResourcePolicies",
      "logs:PutResourcePolicy",
    ]

    resources = ["*"]
  }

  # The log groups themselves, scoped to the prefix the module owns.
  #
  # Unlike the delivery APIs, these do support resource-level conditions, so they
  # get them: this role may create and delete the CloudFront access log groups
  # this repository's environments need, and may not touch any other log group in
  # the account. That distinction is the whole reason the module names its groups
  # under a predictable prefix.
  #
  # The read actions for log *contents* — logs:GetLogEvents, logs:FilterLogEvents
  # — are deliberately absent. Applying an environment requires creating the
  # group, not reading what has been written into it.
  statement {
    sid    = "ManageAccessLogGroups"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteRetentionPolicy",
      "logs:ListTagsForResource",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]

    resources = local.access_log_group_arns
  }

  # The end-to-end workflow's teardown assertion queries this API by the
  # Project and Env tags to prove a destroy left nothing behind. It supports no
  # resource-level conditions and it only reads.
  statement {
    sid    = "VerifyTeardownByTag"
    effect = "Allow"

    actions = [
      "tag:GetResources",
      "tag:GetTagKeys",
      "tag:GetTagValues",
    ]

    resources = ["*"]
  }
}

# The one grant in this file that can be turned into more than it is, which is
# why it is separated from the rest rather than folded into the statement list
# above.
#
# The static-site module creates the app repository's deploy role, so apply
# needs IAM write — and IAM write is how a scoped role becomes an unscoped one.
# The path is short: create a role, put an administrator policy on it, write a
# trust policy naming yourself, assume it. The name pattern below closes the
# first step for every role except the one this repository legitimately owns,
# and the deny closes the last step outright — nothing in this repository ever
# calls sts:AssumeRole, so refusing it costs nothing and removes the exit from
# the escalation.
#
# That is a mitigation, not a proof. The rigorous control is a permissions
# boundary: require, with an iam:PermissionsBoundary condition, that any role
# this identity creates carries a boundary it cannot itself edit. That needs the
# boundary policy to exist and the module to attach it, which is the commit that
# creates the deploy role rather than this one. Recorded here so the gap is
# visible rather than discovered.
data "aws_iam_policy_document" "apply_identity" {
  statement {
    sid    = "ManageAppDeployRole"
    effect = "Allow"

    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]

    # iam:CreatePolicy is absent, and that makes this a contract rather than an
    # oversight: the deploy role's permissions must be an inline role policy,
    # not a customer-managed policy attached to it. Inline is the right shape
    # there anyway — the policy and the role have identical lifetimes, and an
    # inline policy is deleted with the role instead of being left behind as an
    # orphan for the teardown checklist to catch. A managed policy would also
    # need a second ARN pattern granted here, widening this statement for no
    # gain.
    resources = [local.app_deploy_role_arn]
  }

  # The module resolves the provider ARN through a data source rather than
  # being handed it in a committed tfvars, because that ARN embeds the account
  # id and the tfvars are committed.
  statement {
    sid       = "ReadOidcProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [aws_iam_openid_connect_provider.github.arn]
  }

  statement {
    sid       = "DenyRoleChaining"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }
}

# Inline policies rather than customer-managed ones, on both roles.
#
# They have exactly the lifetime of the role they sit on, so a destroy cannot
# strand them — which matters in a repository whose teardown checklist exists
# because orphans are the failure mode. The constraint to know before adding to
# them: IAM caps the *aggregate* size of a role's inline policies at 10,240
# characters, so the limit is shared across the three below rather than applying
# to each. Splitting a long one into two does not buy headroom; moving to a
# managed policy (6,144 characters each, ten attachable) is the escape, at the
# cost of the property in the first sentence.
resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_state.json
}

resource "aws_iam_role_policy" "apply_infrastructure" {
  name   = "infrastructure"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_infrastructure.json
}

resource "aws_iam_role_policy" "apply_identity" {
  name   = "identity"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_identity.json
}

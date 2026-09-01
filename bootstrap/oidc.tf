# The identity half of the bootstrap: who GitHub Actions is allowed to be in
# this account, and what each of those identities may then do.
#
# There are no long-lived AWS access keys anywhere in either repository. CI
# authenticates by exchanging the OIDC token GitHub mints for the running job,
# which means the credential is scoped to a single workflow run, expires with
# it, and cannot be copied out of the repository settings because it was never
# stored there.
#
# The identities are split twice, because what CI does differs in blast radius,
# in trigger, and in which state file it writes.
#
# First by what they do. `plan` runs on every pull request, from any branch,
# and reads. `apply` runs only from a job that has named a GitHub Environment,
# and writes. Collapsing those two would mean every pull request in the
# repository carried the credential that can destroy production.
#
# Then by environment: one `apply` role per name in `var.environments`, each
# trusting exactly one `environment:` subject and able to read and write exactly
# one environment's state. Collapsing *those* is what this file did until the
# apply section below was split, and it meant a job declaring
# `environment: stage` held a credential with write access to
# `prod/terraform.tfstate` — with nothing but the `key=` string in one workflow
# file keeping the two apart. The section header down there is careful about
# how much that split buys, because it is less than it sounds like.

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
  #
  # Keyed by environment rather than collected into a flat list, because there
  # is one apply role per environment and each trusts exactly one of these. A
  # role trusting the whole set is a role that any member of the set can be, in
  # full.
  apply_role_subjects = {
    for environment in var.environments :
    environment => "${local.github_subject_prefix}:environment:${environment}"
  }

  # The layout of the state bucket, in one place. The consuming roots are
  # pointed at `<env>/terraform.tfstate` by the init command outputs.tf emits,
  # and the two must agree or the policies below grant access to keys nothing
  # writes.
  #
  # Keyed by environment for the same reason the subjects above are: the plan
  # role is granted across all of them and each apply role across exactly one,
  # so one definition is read two ways — `values()` where the grant is
  # repository-wide, `[each.key]` where it is not.
  state_object_arns = {
    for environment in var.environments :
    environment => "${aws_s3_bucket.state.arn}/${environment}/terraform.tfstate"
  }

  # Native S3 locking writes `<key>.tflock` beside the state object and deletes
  # it when the run finishes. These are siblings of the ARNs above, not children
  # of them — a property three statements below depend on: the deny in
  # `plan_state`, which must not reach the lock; the per-environment grants in
  # `apply_state`, which have to name both keys rather than one key and a
  # trailing wildcard; and `apply_state`'s cross-environment deny, which has to
  # name both keys of every other environment for the same reason.
  state_lock_arns = {
    for environment in var.environments :
    environment => "${aws_s3_bucket.state.arn}/${environment}/terraform.tfstate.tflock"
  }

  # The state objects an apply role must never touch: every environment's state
  # key and lock except its own, keyed by the environment whose role it is.
  #
  # Derived from the two maps above rather than written out, so the deny that
  # consumes this and the grants it completes cannot disagree about the bucket's
  # layout — the same single definition read a third way, and the reason adding
  # an environment cannot leave the deny naming a key nothing writes.
  #
  # Empty when `var.environments` names one environment, which is why the
  # statement consuming it is `dynamic`: a policy statement whose resource list
  # is empty renders no `Resource` key at all, and IAM rejects that outright.
  other_environment_state_arns = {
    for environment in var.environments :
    environment => concat(
      [for name, arn in local.state_object_arns : arn if name != environment],
      [for name, arn in local.state_lock_arns : arn if name != environment],
    )
  }

  # The namespace the site buckets live in.
  #
  # A site bucket's name is not knowable here: the module mints it with a
  # random suffix, and a fresh one is minted on every cycle because the state
  # that remembered the last one was destroyed. So the grant has to be a
  # pattern, and a pattern is only least privilege if it excludes the things it
  # should not cover. `<prefix>-*` would also match the state bucket
  # `<prefix>-tfstate-<hex>`, handing every apply role bucket-level control over
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

  # The permissions boundary that role must carry, composed rather than read
  # back from `aws_iam_policy.app_deploy_boundary.arn`.
  #
  # That distinction is not stylistic. The condition on the statement that
  # creates the deploy role names this ARN, so referencing the resource makes
  # the whole policy document unknown until the policy exists — and applied to a
  # bootstrap that already stands, which is the case that matters here, each
  # apply role's identity policy is then an update-in-place whose `policy`
  # renders as the *removal* of every existing grant followed by
  # `(known after apply)`. The operator hand-applying this root would be asked to
  # approve a diff showing IAM permissions disappearing and nothing about the
  # split, the condition or the denies that replace them. A security control
  # nobody can see in the plan that installs it is a control on trust.
  #
  # Composing it costs nothing: the name is ours, the account id and partition
  # are already in hand, and this is the shape `app_deploy_role_arn` above
  # already uses. It is also exactly what `outputs.tf` tells the downstream
  # module to do with the same value.
  app_deploy_boundary_name = "${var.name_prefix}-app-deploy-boundary"
  app_deploy_boundary_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.app_deploy_boundary_name}"

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
      values(local.state_object_arns),
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
    resources = values(local.state_object_arns)
  }

  statement {
    sid    = "HoldAndReleaseStateLock"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = values(local.state_lock_arns)
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

    resources = values(local.state_object_arns)
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
# The apply roles — one per environment, writes, each assumed only from a job
# that named that Environment
# ---------------------------------------------------------------------------

# What splitting this role per environment buys, and — the part worth more —
# what it does not.
#
# It isolates **state**, and only state. Each role below can read and write one
# environment's `terraform.tfstate` and the `.tflock` beside it, and no other.
# The other two policies are attached to every one of these roles unchanged, and
# each carries cross-environment reach that the split leaves exactly where it
# was:
#
#   - `apply_infrastructure` still holds `cloudfront:DeleteDistribution`, so the
#     stage role, handed prod's distribution id, will delete prod's
#     distribution. CloudFront accepts no resource-level condition on those
#     calls at all — that policy says so at length, and no arrangement of roles
#     here changes it.
#   - `apply_identity` still grants `iam:CreateRole`, `iam:PutRolePolicy` and
#     `iam:UpdateAssumeRolePolicy` on `role/react-cloudfront-app-deploy-*`,
#     which is one pattern spanning every environment rather than one grant per
#     role. So the stage role can rewrite prod's app deploy role — its trust
#     policy and its inline policy both. The reach is real and it predates this
#     split rather than being introduced by it.
#
#     `DenyRoleChaining` does not cap it, though it reads as though it should:
#     that deny binds this identity, while the assume at the end of such an
#     escalation is performed by GitHub against the rewritten trust policy — a
#     different principal entirely. What caps it is the permissions boundary the
#     conditioned half of `apply_identity` requires, which holds prod's deploy
#     role to three services whoever rewrote it.
#
#     Read that cap precisely. The boundary is one policy shared by every
#     environment, and its resources are `<prefix>-site-*` and `distribution/*`
#     — both environments by construction, and in the CloudFront case every
#     distribution in the account. So the residual is not nothing: it is
#     object-level write, delete included, on the production site bucket, plus
#     invalidation of any distribution. What the boundary removes is the
#     conversion of that reach into a durable identity; it buys no environment
#     isolation, and per-environment boundaries are not available without one
#     policy per environment and a condition per role.
#
# A deliberate raw-API call against a known identifier is therefore exactly as
# possible as it was before this split, through either of those two policies.
#
# What the split closes is the *accident* class: a mistyped `key=`, a matrix
# that expands to the wrong name, a scheduled workflow that drifts onto the
# wrong environment. Terraform reaches an environment's resources by first
# reading that environment's state, and the stage role can no longer read
# prod's — so the mistake now stops at `init` with an AccessDenied naming the
# key it was refused, rather than proceeding against the wrong environment with
# the right credential. That is a narrower claim than "stage cannot touch prod",
# and it is written out because the wider one is the one a reader will otherwise
# assume, and would then rely on.
#
# Timing is the stronger argument for doing it, more than the threat model. In a
# single-maintainer repository the person who could mistype that key can also
# approve their own prod deployment, so against intent the split buys little. It
# earns its keep against `e2e.yml`: unattended, on a schedule, holding this
# credential against stage. Automation nobody is watching should not also carry
# prod's write credential.

# Scoped by environment name, not by ref, because the environment claim replaces
# the ref claim (see local.apply_role_subjects). Exactly one condition value per
# role rather than one per environment on a shared role, which is the whole of
# the change: a trust policy listing several subjects is a role that any one of
# them can assume in full, so the credential a stage job received was
# indistinguishable from the one a prod job received.
#
# This is also what makes prod's required reviewer real: the reviewer gate is a
# property of the GitHub Environment, and a job that does not declare the
# environment gets a subject no role here names, and fails
# AssumeRoleWithWebIdentity outright.
data "aws_iam_policy_document" "apply_assume_role" {
  for_each = toset(var.environments)

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
      values   = [local.apply_role_subjects[each.key]]
    }
  }
}

# The environment is in the role *name*, and the name is the only place on the
# role it appears at all: these roles carry no tags of their own, and the
# provider's default tags are constants for the whole bootstrap root — `Env`
# there is the literal "bootstrap", deliberately, so it cannot distinguish these
# two. The name is what every reference to this role turns out to be: the ARN
# published to the environment-scoped GitHub variable, the identity the trust
# policy is attached to, and the string an AccessDenied quotes back. Someone
# reading a refusal in a run log should be able to tell which environment's
# credential was refused without opening this file.
resource "aws_iam_role" "apply" {
  for_each = toset(var.environments)

  name        = "${var.name_prefix}-ci-apply-${each.key}"
  description = "Role assumed by environment-gated CI to apply and destroy the ${each.key} environment."

  assume_role_policy = data.aws_iam_policy_document.apply_assume_role[each.key].json

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
# One document per environment, and this is where the isolation described at the
# top of this section actually lives — two object ARNs named in full at the top,
# and a deny naming every other environment's two at the bottom. The lock is a
# *sibling* of the state key rather than a child of it, so neither pair can be
# collapsed into `<env>/terraform.tfstate*`: that wildcard reads as tidier and
# would also match `<env>/terraform.tfstate.backup` and anything else someone
# later writes beside the key, which is the opposite of what naming exact
# objects is for.
#
# `s3:DeleteObject` on the state object is deliberately absent. Terraform empties
# state on destroy by writing an empty state file, not by deleting the object,
# and the only operation that deletes it is deleting a workspace — something
# nothing in this repository does. If that ever changes it should fail with a
# named AccessDenied rather than have been granted years earlier on a guess.
data "aws_iam_policy_document" "apply_state" {
  for_each = toset(var.environments)

  statement {
    sid    = "ReadAndWriteState"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = [local.state_object_arns[each.key]]
  }

  statement {
    sid    = "HoldAndReleaseStateLock"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [local.state_lock_arns[each.key]]
  }

  # The S3 backend lists the bucket during init.
  #
  # Bucket-wide, and deliberately not narrowed with an `s3:prefix` condition.
  # Listing returns key names and never their contents, so it grants no part of
  # what the two statements above withhold — and which List calls the S3 backend
  # makes, with which prefixes, is an implementation detail of the backend. A
  # condition guessed at here breaks `init` with an AccessDenied that names
  # nothing a reader can act on, to hide the fact that prod keeps its state in
  # this bucket under a key called `prod/terraform.tfstate`.
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

  # The object-level half of the boundary the statement above draws at the
  # bucket.
  #
  # `DenyStateBucketReconfiguration` stops at the bucket ARN by construction:
  # extending it to `<bucket>/*` would deny the two grants at the top of this
  # document, which are the whole point of the role. Naming the *other*
  # environments' objects is the only form that reaches objects without reaching
  # this role's own, so this finishes a control the file had already started
  # rather than adding a new one.
  #
  # Like its sibling — and like `DenyStateMutation` in `plan_state` — it carves
  # back no grant that exists today, and that is the standard rather than an
  # exception to it. No allow on an apply role reaches another environment's
  # state key: `apply_infrastructure`'s only S3 grant names
  # `local.site_bucket_arns`, `apply_identity` grants no S3 at all, and
  # `local.site_bucket_prefix` exists to keep the site namespace disjoint from
  # `<name_prefix>-tfstate-`. Every deny on this bucket is written against the
  # edit that would change that, on the reasoning `plan_state` sets out in full:
  # an explicit deny cannot be overridden by any allow, so the withholding
  # survives the edit rather than depending on nobody making it.
  #
  # The edit is nameable, which is why the withholding is worth encoding.
  # `ManageSiteBuckets` broadened from `<prefix>-site-*` to `<prefix>-*` is a
  # one-token change on two names that already share a prefix, and it would hand
  # every apply role `s3:*` over the state bucket at once — while
  # docs/BOOTSTRAP.md says that policy is expected to be missing an action or
  # two, which makes it the likeliest thing in this file to be edited.
  #
  # What this closes under that edit, and what it does not, because a deny reads
  # stronger than it is. Closed, permanently and by any S3 action: the other
  # environments' state and lock objects — and closed *explicitly*, which is the
  # whole of the observable change. `iam simulate-principal-policy` answered
  # implicitDeny on those keys before and answers explicitDeny after; nothing an
  # apply role can do today changes either way. Left open: everything else the
  # widening would grant, including `s3:DeleteObject` and
  # `s3:DeleteObjectVersion` on this role's *own* state object, which the first
  # statement withholds on purpose, and object-level reach over any key in this
  # bucket that is not one of the four named here.
  #
  # The form that closes all of it is a `not_resources` whitelist — deny S3 on
  # everything except this role's own two keys, the bucket it lists and the site
  # ARNs — and it is rejected on cost rather than on effect. It would become a
  # second authoritative statement of this role's entire S3 reach, which every
  # future S3 grant in this file would also have to be added to; omit it once
  # and the new grant is refused by a deny no allow can override, so the obvious
  # repair — add the allow — does not work. That inverts the failure preference
  # argued everywhere else here.
  #
  # The statement below carries a smaller version of that hazard, and it is
  # worth naming rather than waving away: a future design in which one
  # environment's root read another's state through `terraform_remote_state`
  # would be refused here by a deny no allow can override either. What makes it
  # acceptable is not that the intent behind it is good — it is that the failure
  # is legible. The refusal quotes the exact object ARN, and that ARN is
  # generated in one place, so the repair is findable from the error. The
  # whitelist's failure is a grant silently missing from a list, which quotes
  # nothing.
  #
  # `s3:*` rather than an enumerated action list, on the reasoning
  # `ManageSiteBuckets` uses for the same operator: the resources are exact
  # object ARNs this role must never touch by any action, so enumerating could
  # only ever leave one out. Object ARNs only, never the bucket ARN —
  # `s3:ListBucket` is authorised against the bucket, so `init`'s listing is
  # untouched by this.
  #
  # `dynamic` because a single-environment `var.environments` leaves nothing to
  # deny. Measured, by rendering this document against a one-element list: an
  # empty `resources` emits a statement with no `Resource` key at all. That such
  # a statement is malformed is inferred from the policy grammar rather than
  # provoked here, since provoking it costs an apply. Adding a third environment
  # rewrites this statement on every role that already exists, in place: these
  # are inline policies, so it is a `PutRolePolicy` and the role itself is
  # untouched.
  dynamic "statement" {
    for_each = length(local.other_environment_state_arns[each.key]) > 0 ? [local.other_environment_state_arns[each.key]] : []

    content {
      sid       = "DenyOtherEnvironmentState"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = statement.value
    }
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

# The permissions boundary the deploy role is required to carry.
#
# A boundary is a ceiling, not a grant: it caps what the role can ever hold, and
# the role's own inline policy still has to allow an action for the role to have
# it. The two controls answer different questions, and confusing them is how a
# boundary ends up either useless or brittle:
#
#   - the inline policy is the ceiling on *verb* — this role may write objects
#     but not delete them, and step by step it is least privilege;
#   - this boundary is the ceiling on *class* — whatever inline policy is
#     written onto the role, by this repository or by someone who has taken over
#     the identity that creates it, the role reaches three services and no
#     others, and never IAM or STS.
#
# So the list here is deliberately a superset of the inline policy the module
# will write onto that role: `s3:DeleteObject` will be granted at the ceiling
# and withheld at the verb. Making them identical looks tighter and is worse —
# the boundary can only be widened by a hand-applied change to this root, landed
# before the change that needs it,
# so a boundary that is an exact copy turns every ordinary permission adjustment
# in the app repository into a two-repository lockstep with a privileged apply
# in the middle. `s3:AbortMultipartUpload` is the case that would have bitten
# first: `aws s3 sync` uses multipart above 8 MB and calls it on a failed part,
# so its absence would surface as a confusing secondary error and leave billable
# incomplete uploads behind.
#
# The resources are scoped, and that is a control in its own right rather than
# tidiness. `resources = ["*"]` would put every bucket in the account inside the
# ceiling. Under exactly the threat model this boundary exists to answer — the
# deploy role's inline policy attacker-written, the boundary the only remaining
# cap — that is object write across the account from a credential that should
# reach one site bucket.
#
# The state bucket specifically is closed twice over: by these patterns, and by
# the explicit `DenyStateBucket` below, which is there so the exclusion survives
# a later edit that widens them. Neither is redundant, and the deny is the one
# to keep if only one survives. The patterns are the same ones the CI grants
# use, so they hold as environments are added.
data "aws_iam_policy_document" "app_deploy_boundary" {
  # Verb families rather than named actions, because a ceiling enumerated action
  # by action is an action ceiling wearing a class ceiling's justification. The
  # deploy will reach for `GetObjectVersion`, `PutObjectTagging` or
  # `GetParametersByPath` sooner or later, and under an enumeration each of
  # those is a privileged hand-apply of this root,
  # landed before the app repository change that needs it.
  #
  # Bucket *configuration* is outside the families: no `PutBucketPolicy`, no
  # `PutBucketAcl`, no `PutBucketPublicAccessBlock`. Those are the S3 calls that
  # change who can reach the content rather than what the content is, and a
  # deploy credential has no business with them.
  #
  # Two escape through the wildcard anyway, and the deny below is what actually
  # keeps that sentence true. `s3:*Object*` matches 50 of S3's actions, and
  # `PutBucketObjectLockConfiguration` and `GetBucketObjectLockConfiguration`
  # are among them despite carrying the *bucket* resource type — the name
  # contains "Object", the glob does not care where.
  statement {
    sid    = "SiteObjects"
    effect = "Allow"

    actions = [
      "s3:*Object*",
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
    ]

    resources = local.site_bucket_arns
  }

  # `Get*` and not `ssm:*`: reading a published parameter is the deploy's job,
  # writing one is the environment root's, and nothing here should be able to
  # rewrite the contract it consumes.
  #
  # No kms:Decrypt anywhere in this document, and that is a contract rather than
  # an omission: the module will publish these as `String`, not `SecureString`,
  # so no decrypt is needed — and a later switch to `SecureString` would fail
  # here rather than silently widening what a deploy credential can read.
  statement {
    sid    = "ReadPublishedParameters"
    effect = "Allow"

    actions = ["ssm:Get*"]

    resources = [local.ssm_parameter_arn_pattern]
  }

  statement {
    sid    = "InvalidateSiteDistributions"
    effect = "Allow"

    # `CreateInvalidation` is the only write. `Get*` and `List*` are reads on a
    # distribution and cannot change one — `cloudfront:*` would have carried
    # `DeleteDistribution`, which is the single most destructive call in this
    # account and belongs nowhere near a deploy credential.
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:Get*",
      "cloudfront:List*",
    ]

    resources = local.site_distribution_arns
  }

  # The exclusions the `s3:*Object*` glob would otherwise swallow.
  #
  # `PutBucketObjectLockConfiguration` is the one that matters: a COMPLIANCE-mode
  # default retention cannot be shortened or lifted by anyone, the account root
  # included. Every object written afterwards becomes immutable for the retention
  # period and the bucket can never be deleted — the permanent form of the orphan
  # class docs/TEARDOWN.md exists to prevent, reachable from a deploy credential.
  #
  # It is unreachable today only because Object Lock requires versioning, the
  # module leaves versioning off, and `s3:PutBucketVersioning` is not matched by
  # the glob. That is three facts in another repository's module holding up a
  # ceiling in this one, and the module's own comment already says a durable
  # deployment should turn versioning on. A ceiling that depends on a setting it
  # does not control is not a ceiling.
  #
  # The ACL and retention writes go with it: those decide who can reach an object
  # and how long it survives, which is the same authority the paragraph above
  # withholds at bucket level.
  #
  # `GetBucketObjectLockConfiguration` is denied too, and it is only a read. It
  # is here so the deny covers the glob's whole bucket-level reach rather than
  # the half of it that is dangerous — the next person to widen `s3:*Object*`
  # should find one exclusion to reason about, not one plus an exception.
  statement {
    sid    = "DenyContentAccessControl"
    effect = "Deny"

    actions = [
      "s3:GetBucketObjectLockConfiguration",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutObjectAcl",
      "s3:PutObjectLegalHold",
      "s3:PutObjectRetention",
      "s3:PutObjectVersionAcl",
    ]

    resources = local.site_bucket_arns
  }

  # Explicit rather than implicit, for the reason `DenyStateMutation` on the
  # plan role is explicit: an allow cannot override it, so the exclusion
  # survives a later edit that widens the statements above rather than depending
  # on nobody making that edit. It matters more here than there, for the reason
  # the `apply_identity` comment below gives about resource-based policies.
  statement {
    sid    = "DenyStateBucket"
    effect = "Deny"

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }
}

# The only customer-managed policy in this root, and the exception is forced
# rather than chosen: a permissions boundary can only be a managed
# policy. `aws_iam_role_policy` cannot express one.
#
# It is created here because it can only be created here. `iam:CreatePolicy` is
# withheld from every apply role — that is the contract the deploy role's inline
# policy rests on — so the module that creates the deploy role cannot create the
# boundary it must attach. The one place that can is the one applied by hand.
#
# It has no lifecycle tie to any role, which is the opposite of the property the
# inline-policy comment further down argues for. That is the cost of the
# exception: destroying an environment leaves this policy standing. It is
# intended to — it outlives every environment and is removed only by the
# bootstrap destroy, which is why
# docs/TEARDOWN.md section 6 lists it as out of scope for a per-environment
# sweep and section 8 carries the check that it is unattached first.
#
# `name` and `description` are both replacement-forcing — IAM has no update API
# for a *managed policy's* description, whatever it offers for a role's — and a
# replacement cannot succeed while any deploy role carries this boundary,
# because a boundary counts as an attachment and
# DeletePolicy answers DeleteConflict. So an idle reword of that sentence plans
# a destroy/create and fails mid-apply, in a root that is applied by hand. Do
# not edit either while an environment is standing. The policy *body* is safe to
# edit: it becomes a new policy version in place.
resource "aws_iam_policy" "app_deploy_boundary" {
  name = local.app_deploy_boundary_name

  # Explicit at its default, because `local.app_deploy_boundary_arn` composes the
  # ARN without one and the two have to agree. Written here rather than left
  # implicit so the assumption is visible in the block a future editor would
  # change, instead of only in a local 1,200 lines up.
  path = "/"

  description = "Ceiling for the app repository's deploy role. Attached as a permissions boundary, never as a policy."
  policy      = data.aws_iam_policy_document.app_deploy_boundary.json
}

# The one thing composing the ARN gives up, bought back.
#
# `local.app_deploy_boundary_arn` shares its name with the resource, so the two
# cannot disagree about that — but the composition also fixes `path` at the
# default by omitting it, and nothing links the two otherwise. Setting `path` on
# the policy above would move its real ARN, leave the condition naming the old
# one, and show no diff whatsoever on either apply role: the next environment
# apply would fail `AccessDenied` on `iam:CreateRole` with nothing in any plan
# pointing at the cause.
#
# A `check` block names it. Not a `lifecycle { postcondition }`, which would hard
# fail: this is a drift detector, and a drift detector that blocks an apply also
# blocks the apply that would fix the drift. The cost is the honest one — a check
# assertion is always a warning, never an error, so it reports rather than stops,
# and a warning in a long plan is easy to miss. At plan time on the apply that
# introduces a `path`, the ARN is unknown and the assertion is skipped with a
# "known after apply" note, so the mismatch is reported after the policy has
# already moved. Setting `path` explicitly on the resource below is what keeps
# that from being the first anyone hears of it.
check "app_deploy_boundary_arn_matches" {
  assert {
    condition     = aws_iam_policy.app_deploy_boundary.arn == local.app_deploy_boundary_arn
    error_message = "local.app_deploy_boundary_arn no longer matches aws_iam_policy.app_deploy_boundary.arn. Most likely cause: a `path` was set on the policy. Two consequences, and the quiet one matters more: the apply roles condition iam:CreateRole on the composed value, so the deploy role can no longer be created — loud, on the next environment apply; and DenyBoundaryPolicyEdit names the composed value too, so it now protects a policy that does not exist and the real boundary can be rewritten with CreatePolicyVersion and SetDefaultPolicyVersion."
  }
}

# The one grant in this file that can be turned into more than it is, which is
# why it is separated from the rest rather than folded into the statement list
# above.
#
# The static-site module creates the app repository's deploy role, so apply
# needs IAM write — and IAM write is how a scoped role becomes an unscoped one.
# The path is short: create a role, put an administrator policy on it, write a
# trust policy naming an identity you control, let that identity assume it. The
# name pattern below closes the first step for every role except the one this
# repository legitimately owns.
#
# `DenyRoleChaining` does not close the last step, and it is worth being explicit
# about why, because it looks as though it should. That deny refuses
# `sts:AssumeRole` by *this* identity. The assume at the end of the escalation
# above is performed by GitHub, against a trust policy naming an
# attacker-controlled OIDC subject — a different principal entirely, unaffected
# by a deny attached here.
#
# What does close it is the permissions boundary, which is why it is no longer
# deferred. The conditioned statement below refuses `CreateRole` unless the new
# role carries `aws_iam_policy.app_deploy_boundary`, and that boundary contains
# no `iam:*` and no `sts:*`. A role minted through this grant therefore cannot
# be given administrator rights no matter what inline policy is written onto it,
# and cannot be turned into a foothold for creating further roles.
#
# The precise claim, because the loose version of it is wrong in a way worth
# knowing: a boundary caps what an *identity policy* can grant. AWS documents
# that a boundary's implicit denies do not limit what a **resource-based**
# policy grants to a session — and an identity holding the apply role can write
# resource policies, `s3:PutBucketPolicy` on the site buckets among them. So the
# boundary does not reduce the reach of someone who already holds the apply
# role; it stops that reach being *converted into a durable second identity*.
# That is the property being bought here. Where containment has to bind
# resource-based policies too, it takes an explicit deny, which is why the
# boundary carries one on the state bucket.
#
# `iam:DeleteRolePermissionsBoundary` is withheld, so the boundary cannot be
# lifted off a role once it is on. `iam:PutRolePermissionsBoundary` is granted,
# but only inside the same condition — it can move a role onto this boundary and
# onto nothing else.
#
# The statement is split in two because the condition cannot cover all of it.
# `iam:PermissionsBoundary` is not a supported condition key for GetRolePolicy,
# ListAttachedRolePolicies, ListInstanceProfilesForRole, ListRolePolicies,
# ListRoleTags, TagRole or UntagRole. The list is worth checking rather than
# reasoning about — AWS publishes it machine-readably at
# servicereference.us-east-1.amazonaws.com/v1/iam/iam.json — because it does not
# follow the intuition that reads are unsupported and writes are supported. A
# request for one of those seven carries no such key, `StringEquals` on an
# absent key does not match, and conditioning them would deny all seven rather
# than constrain them. They are reads and tag calls; none can create a role or
# change what one may do.
#
# Everything that can is conditioned. `UpdateAssumeRolePolicy` is the one to
# notice: it rewrites *who* may use a role, so against a role that already
# carries permissions — one created out of band, by an admin or another
# automation, that happens to match the wildcard below — it is a full escalation
# on its own, with no policy ever being written.
#
# `UpdateRole` and `UpdateRoleDescription` are both there because IAM splits one
# Terraform-level change across two APIs: the provider calls `UpdateRole` for
# `max_session_duration` and `UpdateRoleDescription` for `description`. Granting
# only the first looks complete and denies every description edit. It is the
# same shape of gap as the missing `ListInstanceProfilesForRole` this commit
# also closes, in the same provider file, and the same cost if it is found
# later: a second hand-apply of this root.
#
# `DeleteRole` and `GetRole` support the key and are deliberately left out of
# the condition anyway. `GetRole` is a read. `DeleteRole` is the deliberate one:
# conditioning it would refuse to delete a role whose boundary had been stripped
# by hand, converting a containment problem into a stranded orphan — the failure
# class docs/TEARDOWN.md exists to prevent. Deleting a role is not an escalation,
# so the trade goes the other way here.
data "aws_iam_policy_document" "apply_identity" {
  # The half that can bring a role into existence or change what it may do.
  # Every action here is refused unless the role carries the boundary.
  statement {
    sid    = "ManageAppDeployRoleBounded"
    effect = "Allow"

    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]

    # iam:CreatePolicy is absent, and that makes this a contract rather than an
    # oversight: the deploy role's permissions must be an inline role policy,
    # not a customer-managed policy attached to it. Inline is the right shape
    # there anyway — the policy and the role have identical lifetimes, and an
    # inline policy is deleted with the role instead of being left behind as an
    # orphan for the teardown checklist to catch. A managed policy would also
    # need a second ARN pattern granted here, widening this statement for no
    # gain.
    #
    # iam:AttachRolePolicy survives the absence of iam:CreatePolicy for one
    # reason: AWS-managed policies need no CreatePolicy call. Without the
    # condition below, this single action reaches AdministratorAccess without a
    # line of policy JSON being written — which is why it belongs in this half
    # rather than among the reads.
    resources = [local.app_deploy_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.app_deploy_boundary_arn]
    }
  }

  # The half the condition does not cover. Seven of these nine cannot carry it —
  # iam:PermissionsBoundary is not a supported condition key for them.
  # DeleteRole and GetRole do support it and are left out deliberately, for the
  # reason the block comment above gives.
  #
  # None of them can create a role or widen what one may do, which is what makes
  # leaving them unconditioned acceptable rather than merely unavoidable.
  #
  # iam:ListInstanceProfilesForRole is here for the destroy path rather than for
  # anything this repository reads. The AWS provider's role deletion calls it
  # unconditionally before it deletes the role — ahead of, and outside, both the
  # force-detach branches — and tolerates only NotFound from it. An AccessDenied
  # there aborts the destroy after the inline policy is already gone, leaving a
  # stripped role behind for the teardown checklist. It lists instance profiles,
  # which nothing in this repository creates, so it always returns empty.
  statement {
    sid    = "ManageAppDeployRoleUnbounded"
    effect = "Allow"

    actions = [
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:TagRole",
      "iam:UntagRole",
    ]

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

  # What this deny does close, since two comments above say what it does not.
  # Nothing in this repository calls `sts:AssumeRole` from CI — GitHub's OIDC
  # exchange is `AssumeRoleWithWebIdentity`, a different action — so refusing it
  # account-wide costs nothing and closes chaining by this identity into any
  # role whose trust policy names the account root, a shape most accounts have
  # somewhere and which has nothing to do with the deploy role above.
  statement {
    sid       = "DenyRoleChaining"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }

  # The two denies that keep the boundary a boundary. Every action in them is
  # already absent from the statements above, so these change nothing today;
  # they are explicit for the reason `DenyStateBucket` in the boundary document
  # is, and
  # `DenyStateMutation` on the plan role before it.
  #
  # What they buy is specific to this control. Without them, one broad statement
  # added later for an unrelated need dissolves the whole thing — and does so
  # with no plan diff on any role, because no role changes. The first deny is
  # the obvious route: lift the boundary off a role and the ceiling is gone. The
  # second is the quiet one — `CreatePolicyVersion` plus
  # `SetDefaultPolicyVersion` rewrites the ceiling itself, for every deploy role
  # in the account at once, without touching a single role resource.
  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyBoundaryPolicyEdit"
    effect = "Deny"

    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]

    resources = [local.app_deploy_boundary_arn]
  }
}

# Inline policies rather than customer-managed ones, on every role in this file.
#
# They have exactly the lifetime of the role they sit on, so a destroy cannot
# strand them — which matters in a repository whose teardown checklist exists
# because orphans are the failure mode. The constraint to know before adding to
# them: IAM caps the *aggregate* size of a role's inline policies at 10,240
# characters, so the limit is shared across the three attached to each apply
# role rather than applying to each policy. Splitting a long one into two does
# not buy headroom; moving to a managed policy (6,144 characters each, ten
# attachable) is the escape, at the cost of the property in the first sentence
# — and it would cost it once per environment now rather than once.
#
# `aws_iam_policy.app_deploy_boundary` above is the one exception, and its own
# comment says why it has to be. Note only that the lifetime argument in the
# paragraph above is not merely inapplicable to it — it is inverted. That policy
# is meant to outlive the roles it applies to.
#
# One consequence for anything outside this repository that mirrors these three
# inline policies.
# A local operator identity — a human-assumable role carrying the same
# permissions, so an environment can be applied from a laptop — used to be a
# copy of one apply role's policies. There is no single role to copy any more:
# such an identity has to mirror one apply role per environment, or hold the
# union of their state grants as a deliberate choice. Re-syncing it from one
# role here would silently leave it able to read every environment's state but
# one, and that surfaces as an AccessDenied on a state key part-way through a
# destroy.
#
# `apply_identity` and `apply_infrastructure` allow no such choice: they carry
# no per-environment divergence to make one about, so a mirror of either is
# current or it is wrong. Edit either document and re-sync every mirror of it in
# the same change, not a follow-up one. A mirror that has fallen behind does not
# fail at plan time — it fails part-way through a destroy, after the inline
# policy is already gone, leaving the stripped role the teardown checklist
# exists to prevent. Such an identity is created outside this repository and no
# root here refreshes it, which is why this is a note and not a resource.
resource "aws_iam_role_policy" "apply_state" {
  for_each = aws_iam_role.apply

  name   = "terraform-state"
  role   = each.value.id
  policy = data.aws_iam_policy_document.apply_state[each.key].json
}

# The one policy in this section that is deliberately identical on every apply
# role: same document, rendered once, attached N times. It is the boundary the
# split does not move, and keeping it a single `data` source is what stops it
# drifting into N nearly-identical infrastructure policies that a reader would
# have to diff to compare.
resource "aws_iam_role_policy" "apply_infrastructure" {
  for_each = aws_iam_role.apply

  name   = "infrastructure"
  role   = each.value.id
  policy = data.aws_iam_policy_document.apply_infrastructure.json
}

resource "aws_iam_role_policy" "apply_identity" {
  for_each = aws_iam_role.apply

  name   = "identity"
  role   = each.value.id
  policy = data.aws_iam_policy_document.apply_identity.json
}

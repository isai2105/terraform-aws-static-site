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
  #
  # Repository-wide on purpose, and it has two consumers rather than one. That
  # distinction is worth writing down, because the one-line summary of the
  # narrowing below — "the apply roles no longer use this value" — is false, and
  # believing it is what makes the second consumer easy to break.
  #
  # `plan_read`'s `ReadCiIdentity` names this value directly, and is the reason it
  # must stay a pattern: a pull request plans every environment, so the plan role
  # has to be able to read every environment's deploy role. The map directly
  # below is the second consumer, composed *from* this string by `trimsuffix`, so
  # the apply roles still depend on it transitively — on everything about it
  # except its final character.
  #
  # Do not "tidy" the two back into one, and both consumers are why. Narrowing
  # this value to a single environment silently breaks cross-environment
  # planning; deleting it in favour of writing the role name a second time inside
  # the map duplicates a literal the other repository is held to. The two locals
  # exist because the two consumers need different endings, not because one of
  # them is redundant.
  #
  # The trailing `*` is a live wildcard rather than a formality, and the evidence
  # for that is real but must be read for what it now is.
  # `modules/static-site/iam.tf:93-98` records a `simulate-principal-policy` run
  # against both apply roles in which `-dev` and `-stage-extra` were allowed too
  # — and that run was made while the apply roles still granted on this pattern,
  # which is exactly the grant the map below removed. So it is evidence about the
  # *pattern's semantics*, not about any grant that stands today: IAM reads the
  # trailing `*` as a wildcard, and any statement naming this value reaches every
  # role in the account whose name begins `react-cloudfront-app-deploy-`. The one
  # statement that still names it, `ReadCiIdentity`, has not itself been
  # simulated, and no simulation recorded anywhere in this repository covers the
  # plan role at all. The measurement is the reason the map below exists; the map
  # is what retired the principals it was measured against.
  app_deploy_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/react-cloudfront-app-deploy-*"

  # The same role, one exact ARN per environment. This is what the two
  # `apply_identity` statements grant on, and it is the whole of what stops the
  # stage apply role rewriting prod's deploy role.
  #
  # A second local rather than a narrowing of the one above, and that is a
  # constraint rather than a preference. Narrow `app_deploy_role_arn` in place
  # and `ReadCiIdentity` narrows with it, so the plan role can read one
  # environment's deploy role and no other — which breaks cross-environment
  # planning and does it quietly, because the denial surfaces in a pull request
  # check rather than in the apply whoever made the change was testing.
  #
  # An exact ARN and not a pattern, because the deploy role's name is fully
  # determined: `modules/static-site/iam.tf:99` composes it as
  # `${local.app_repository}-deploy-${var.environment}` — no `random_id`, no hex,
  # nothing AWS mints, unlike the site bucket and the CloudFront function this
  # file has to reach with prefixes. That is why this narrowing carries none of
  # the fragility a tag condition would: no propagation window to lose a race
  # against, no tag another statement could rewrite or remove, and no key that
  # has to agree across two roots.
  #
  # Composed by trimming the wildcard off the pattern above rather than by
  # writing `react-cloudfront-app-deploy-` a second time. The name is a contract
  # with the other repository, which `modules/static-site/iam.tf:80-86` states in
  # those terms and keeps as a single literal for the same reason: two literals
  # are two chances to change one of them.
  #
  # The coupling runs the other way too, and `trimsuffix` is why it needed a
  # guard rather than a warning sentence. `trimsuffix` fails soft: handed a
  # pattern that does not end in a bare `*` — a `?` instead, a `/` or a `-`
  # appended after the wildcard, a suffix added to scope the pattern by path — it
  # raises nothing at all and returns the string unmodified, so this composes
  # `…-deploy-*stage`. That is a syntactically valid ARN pattern. It plans, it
  # applies, it renders into the policy body, and it grants `iam:PutRolePolicy`
  # over every role whose name ends `stage` rather than over the one role
  # intended. Nothing anywhere in either root asks a question about it; the whole
  # of the evidence is a string inside a rendered policy document that nobody
  # reads unless they already suspect it. `check "app_deploy_role_arn_is_a_pattern"`
  # below is what turns that into something a plan says out loud.
  #
  # A property worth having on purpose rather than a side effect. An entry in
  # `var.environments` here that disagrees with the `environment` local in the
  # matching `envs/<env>/main.tf` is now refused at `iam:CreateRole` against an
  # ARN naming the environment, loudly, in the apply that causes it. Under the
  # shared pattern the wildcard absorbed that mismatch and it cost nothing until
  # something else noticed — which, for a coupling that lives in two roots with
  # nothing mechanical holding it equal, is the failure mode worth converting
  # into a first-apply error.
  #
  # The hazard this shape introduces is a slip rather than a design flaw, and it
  # is named because it is silent. `local.app_deploy_role_arn` is still in scope
  # inside `apply_identity`; reaching for it there instead of for this map
  # re-widens both grants to every environment's deploy role, raises no error at
  # plan or apply, and leaves no evidence outside the rendered policy JSON. The
  # two names are deliberately more than one character apart so that a slip has
  # to be a decision.
  app_deploy_role_arns_by_environment = {
    for environment in var.environments :
    environment => "${trimsuffix(local.app_deploy_role_arn, "*")}${environment}"
  }

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
  # is called, turning a permission problem into an intermittent one. That
  # reasoning is this local's own and is not borrowed from anywhere: the
  # `ManageCloudFront` statement below is also account-wide, but for reasons of
  # its own and neither of them this one — ten of its actions are creates and
  # account-level enumerations that take no ARN at all, and the rest are on `*`
  # for a reason that statement gives itself. The two justifications should not
  # be read as one. Each grant stands on the reason written above it.
  site_distribution_arns = [
    "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*",
  ]

  # The CloudFront functions the environments create, which — unlike everything
  # else CloudFront hands this repository — can be scoped by name.
  #
  # The difference is entirely in who chooses the identifier. A distribution id,
  # a cache policy id, a response headers policy id and an origin access control
  # id are all minted by AWS at create time, so a grant written here has nothing
  # to name and `*` is the only honest pattern. The function ARN is
  # `arn:<partition>:cloudfront::<account>:function/<Name>`, and that `Name` is
  # the caller's: the module sets it to `local.bucket_name`, so every function
  # this repository creates lands inside the same `<name_prefix>-site-*`
  # namespace `local.site_bucket_prefix` already exists to keep disjoint from the
  # state bucket. One naming contract, honoured by the module for the bucket's
  # sake, turns out to scope a second service at no extra cost.
  #
  # The trailing `-*` is not slack that a later edit could tighten. The module
  # appends a fresh `random_id` on every cycle — the state remembering the last
  # one is destroyed with the environment — so no exact name is knowable here,
  # and the same pattern therefore spans every environment's function rather than
  # one environment's. This is a prefix grant. It separates this repository from
  # the rest of the account; it does not separate stage from prod, and the
  # section above is careful about that distinction for the same reason.
  #
  # This is also why a name pattern is used here where the tag condition the
  # apply-role section defers is not — and the comparison is worth making
  # precisely rather than flatteringly, because this grant is not free of the
  # failure mode it is being preferred over.
  #
  # `var.name_prefix` is already load-bearing and already fails fast: a bootstrap
  # value that disagrees with what the environments name their buckets is refused
  # at `s3:CreateBucket` with an AccessDenied naming the bucket, on the first
  # apply. What scoping the function actions adds is that the same operator error
  # can now also strand a function. `random_id.bucket_suffix` depends on nothing,
  # so the bucket and the function are created concurrently rather than in
  # sequence; `CreateFunction` still succeeds, since it stays on `*`, and the
  # provider records the id before it publishes — so `PublishFunction` is the
  # call that is denied, with the function already in AWS *and* in state, and
  # `DeleteFunction` denied beside it. Before the split below, all three were on
  # `*` and the same mistake left a function the role could still delete.
  #
  # Two properties keep that smaller than what the tag condition would introduce,
  # and both are about repair rather than about blast radius. The orphan is
  # transient: correcting `name_prefix` in `bootstrap/terraform.tfvars` and
  # re-applying the bootstrap restores this role's ability to delete the
  # function — and that is the same repair the operator already has to make to
  # get past the bucket denial, so it is one fix rather than two. And the mistake
  # announces itself in the very apply that causes it, as an AccessDenied naming
  # the bucket, so it is diagnosable at the moment it happens.
  #
  # A wrong `project` has neither property. It produces no error on apply at all.
  # It surfaces as an AccessDenied on `DeleteDistribution` at destroy, against an
  # environment that has been standing and serving traffic, in a message that
  # says nothing about tags and names nothing a reader can trace back to a
  # tfvars. That is the asymmetry between the two, and it is about which failures
  # are findable rather than about which are harmless.
  site_function_arns = [
    "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:function/${local.site_bucket_prefix}-*",
  ]
}

# The assertion that keeps `local.app_deploy_role_arns_by_environment` an exact
# ARN rather than a pattern with a wildcard buried in the middle of it.
#
# `trimsuffix` has no failure mode, and that is the problem it is guarding
# against: given a pattern whose last character is not `*` it returns the pattern
# unchanged rather than erroring, and the map composes `…-deploy-*stage` — an ARN
# pattern that is well formed, that Terraform will happily plan and apply, and
# that hands one environment's apply role `iam:PutRolePolicy` and
# `iam:UpdateAssumeRolePolicy` over every role in the account whose name happens
# to end in that environment's name. The narrowing this whole item exists to
# perform would be undone, and undone invisibly: the only artefact is a string
# inside a rendered inline policy.
#
# A `check` for the reason the boundary ARN below gets one — a hard failure here
# would be a `lifecycle { postcondition }`, and this file's position is that a
# drift detector that blocks an apply also blocks the apply that repairs it. The
# honest cost is the same: a check assertion is a warning, never an error, so it
# reports rather than stops, and a warning in a long plan is easy to miss.
#
# One thing it does better than its neighbour, though, and it is the reason this
# is worth having at all. The condition depends on nothing but literals, the
# account id and the partition, so it is fully known at plan time on every run
# including the very first — it is never deferred with a "known after apply" note
# and never skipped. Whoever makes this edit sees the warning in the plan that
# introduces it, not in the one after the damage is applied.
check "app_deploy_role_arn_is_a_pattern" {
  assert {
    condition     = endswith(local.app_deploy_role_arn, "*")
    error_message = "local.app_deploy_role_arn no longer ends in a bare `*`. `local.app_deploy_role_arns_by_environment` composes each exact role ARN by trimming that `*` off with `trimsuffix`, and `trimsuffix` does not fail on a suffix that is not there — it returns the pattern unchanged, so the map is now composing an ARN with a wildcard in the middle of it (`…-deploy-*<env>`). Nothing downstream will refuse that: the apply roles' `ManageAppDeployRoleBounded` and `ManageAppDeployRoleUnbounded` will render, plan and apply against it, granting each environment's apply role iam:PutRolePolicy and iam:UpdateAssumeRolePolicy over every role in the account whose name ends in that environment's name. Either restore the trailing `*` or stop composing the map from this value."
  }
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
# It isolates **state**, and the app repository's deploy role. Each role below
# can read and write one environment's `terraform.tfstate` and the `.tflock`
# beside it and no other, and can create, rewrite and delete one environment's
# `react-cloudfront-app-deploy-<env>` role and no other.
#
# It is more than state, but not by much, and "state, and only state" is the
# shorthand to resist. `apply_infrastructure` is the one policy attached to every
# one of these roles unchanged. The two bullets are where each of the other two
# policies stands — the first a cross-environment reach the split leaves exactly
# where it was, the second one it no longer has and the residual that outlived
# closing it:
#
#   - `apply_infrastructure` still holds `cloudfront:DeleteDistribution`, so the
#     stage role, handed prod's distribution id, will delete prod's
#     distribution. That reach is account-wide because this file declines to
#     condition it, not because CloudFront refuses to be conditioned:
#     `DeleteDistribution` and `UpdateDistribution` both take the `distribution`
#     resource type and both support `aws:ResourceTag/${TagKey}`, so the control
#     exists and is being deferred rather than being unavailable.
#
#     What defers it is where the two halves of the comparison live. The
#     condition would have to be `aws:ResourceTag/Project`, written from
#     `var.project` in `bootstrap/terraform.tfvars`, and matched against a tag
#     whose value comes from `project` in `envs/*/terraform.tfvars` — two files,
#     in two roots, with nothing mechanical holding them equal, because this
#     root deliberately exposes no `terraform_remote_state` for the environments
#     to read. A mismatch between those two strings is already the documented
#     quiet footgun for a cloner. Conditioning the delete on it would turn that
#     mismatch into a denied `DeleteDistribution` at destroy time, stranding the
#     distribution and the bucket behind it — precisely the failure class the
#     teardown documentation exists to prevent, and a worse outcome than the
#     cross-environment reach the condition would have closed. So it waits on a
#     written must-match contract between the two roots, and no arrangement of
#     roles here closes it in the meantime.
#   - `apply_identity` used to belong in this list and no longer does, and the
#     shape of what it used to be is worth keeping rather than deleting, because
#     it is the reach a reader would otherwise assume is still here. It granted
#     `iam:CreateRole`, `iam:PutRolePolicy` and `iam:UpdateAssumeRolePolicy` on
#     `role/react-cloudfront-app-deploy-*` — one pattern spanning every
#     environment rather than one grant per role — so the stage role could
#     rewrite prod's app deploy role, its trust policy and its inline policy
#     both, and inherit whatever that role held. The wildcard was confirmed live
#     rather than assumed: `modules/static-site/iam.tf:93-98` records a
#     `simulate-principal-policy` run in which `-dev` and `-stage-extra` were
#     allowed too.
#
#     That document is now rendered per environment and names the exact ARN
#     `role/react-cloudfront-app-deploy-<env>`
#     (`local.app_deploy_role_arns_by_environment`), so the grant reaches one
#     role.
#
#     Be exact about what that bought, because the reading it invites — the stage
#     apply role can no longer reach prod — is wrong, and a control credited with
#     more than it does is worse than no control, since the next reader stops
#     looking. The permissions boundary is a single policy shared by both
#     environments. A stage apply role that can no longer rewrite *prod's* deploy
#     role can still rewrite *stage's own*, install the same access on prod's
#     bucket under that same shared ceiling, retrust it to a subject it controls,
#     and arrive at an identical capability set. The narrowing moved the vehicle;
#     it did not narrow the destination.
#
#     What it does close is real, and it is smaller than the change looks:
#       - `iam:DeleteRole` against prod's deploy role. That is not an escalation
#         — which is why the unbounded half was able to hold it in the first
#         place — it is an availability break in the *other* repository: the
#         identity prod's deploys assume, deleted mid-cycle, as easily by a
#         mistyped matrix as on purpose, with nothing in this root positioned to
#         notice and no repair available in that root.
#       - `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy` and `iam:UpdateRole`
#         against prod's deploy role. The *reach* those bought is redundant now,
#         for the reason the paragraph above gives, but the *name* is not: this
#         was the only route to a durable credential actually called
#         `react-cloudfront-app-deploy-prod`. Everything reachable the other way
#         carries stage's name in every CloudTrail record and every
#         `GetCallerIdentity`, and the difference between an escalation that hides
#         inside the expected traffic of prod's deploy and one that stands out in
#         it is most of what detection has to work with here.
#       - a genuinely new fail-fast, set out in full beside the map: an entry in
#         `var.environments` that disagrees with the `environment` local in the
#         matching `envs/<env>/main.tf` is now refused at `iam:CreateRole` against
#         an ARN naming the environment, where the shared wildcard used to absorb
#         it silently.
#
#     It was still the right item to take first, for a reason about ordering
#     rather than about size: it was the unblocked one. It needed no written
#     contract between two roots, no assumption about tag propagation, and no new
#     policy per environment — unlike the `aws:ResourceTag/Project` condition
#     above, which waits on that contract, and unlike per-environment site bucket
#     ARNs, which is where the largest reduction in stage-to-prod reach actually
#     lives and which the paragraphs below spend their length on. An exact role
#     ARN is also the better instrument on its own terms: it admits no retagging
#     into scope and needs no assumption about when AWS makes a tag readable to an
#     authorization decision, neither of which a tag condition on
#     `DeleteDistribution` can say.
#
#     Be precise about what that closed, because a neighbouring escalation
#     survives it intact. `DenyRoleChaining` was never the cap and still is not:
#     that deny binds this identity, while the assume at the end of such an
#     escalation is performed by GitHub against the rewritten trust policy — a
#     different principal entirely. The cap on what a rewritten deploy role may
#     hold is the permissions boundary the conditioned half of `apply_identity`
#     requires.
#
#     Read that cap precisely, because it is now the whole of the residual rather
#     than a backstop behind a wildcard. The boundary is one policy shared by
#     every environment — deliberately, which is why
#     `local.app_deploy_boundary_arn` was not narrowed alongside the role ARN —
#     and its resources are `<prefix>-site-*` and `distribution/*`: both
#     environments by construction, and in the CloudFront case every distribution
#     in the account.
#
#     Before walking that escalation, note the shorter route, because this
#     passage is the file's answer to "what can the stage apply role still do to
#     prod" and answering it with an escalation would overstate the work an
#     attacker has to do. `apply_infrastructure`'s `ManageSiteBuckets` grants
#     `s3:*` on `local.site_bucket_arns`, and that local is the pair
#     `<prefix>-site-*` and `<prefix>-site-*/*` — the bucket form and the object
#     form, with no environment in either, rendered identically onto every apply
#     role. The stage apply role therefore holds every S3 action there is on the
#     production site bucket and on its contents, directly, under its own
#     credential, with no IAM call in front of it. Not object write and delete:
#     `s3:DeleteBucket`, `s3:PutBucketPolicy`, `s3:PutBucketPublicAccessBlock`,
#     `s3:PutBucketVersioning` and the rest of the bucket surface as well — which
#     is strictly *more* than the boundary permits a deploy role, since the
#     boundary caps that at `s3:*Object*` plus listing and denies the bucket-level
#     access controls outright in `DenyContentAccessControl`. Scoping the site
#     bucket ARNs per environment is the item that closes this, and it is not this
#     one.
#
#     The escalation survives on top of that and is still worth stating, because
#     it reaches two things the direct grant does not. The stage role can write an
#     inline policy onto *stage's own* deploy role carrying the boundary's whole
#     ceiling against the production site bucket, plus `CreateInvalidation` on any
#     distribution in the account, and rewrite that role's trust policy to name a
#     subject it controls — a credential that outlives the job and answers to none
#     of the OIDC conditions this file spends its length on. For data reach on
#     prod's bucket it is redundant with the paragraph above; what it adds is
#     durability and CloudFront. Naming the exact role ARN moved the escalation
#     from prod's deploy role to stage's; it did not narrow what the role at the
#     end of it can reach. What the boundary removes is `iam:` and `sts:` — the
#     conversion of that reach into a durable *second* identity, as distinct from
#     a retrusted first one, which the apply role's own
#     `iam:UpdateAssumeRolePolicy` still supplies — and per-environment boundaries
#     are not available without one policy per environment and a condition per
#     role.
#
# A deliberate raw-API call against a known identifier is therefore exactly as
# possible as it was before this split, through `apply_infrastructure` — most
# directly through `ManageSiteBuckets`, which names no environment, and
# additionally, by the route in the second bullet, through the environment's own
# deploy role under a boundary that spans every environment.
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
  # The number is headroom, not a measurement, and in particular it is not
  # derived from the 15-to-20 minute CloudFront teardown figure that circulates
  # unsourced — that figure is inherited rather than observed. Measured on
  # 2026-08-27 across three
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
  # Enumerated rather than wildcarded, and split across the three statements
  # here rather than written as one, because "the resource cannot be narrowed"
  # is true of only part of this surface. Do not read it as a property of the
  # whole of it; the split is what keeps the two parts distinguishable.
  #
  # Ten of the thirty-four CloudFront actions in these three statements
  # authorise against `*` and nothing else, per AWS's machine-readable service
  # reference — thirty-four being this CDN surface rather than everything the
  # role holds, since `ServiceLevelAccessForLogDelivery` further down grants a
  # thirty-fifth. They are the five
  # creates — CreateCachePolicy, CreateDistribution, CreateFunction,
  # CreateOriginAccessControl, CreateResponseHeadersPolicy — which have no ARN
  # to name because they are the calls that mint one, and the five account-level
  # enumerations — ListCachePolicies, ListDistributions, ListFunctions,
  # ListOriginAccessControls, ListResponseHeadersPolicies. Those are why this
  # statement is `*`, and they mean this role can create these resource types
  # anywhere in the account: acceptable only because the operating model gives
  # this repository its own account, which the README's tradeoffs section says
  # out loud. The other twenty-four do take a resource ARN, and where naming
  # one subtracts anything it is named — the five `function` actions and the
  # three multi-type tag actions are in their own statements directly below.
  #
  # The twelve remaining cache-policy, response-headers-policy and
  # origin-access-control actions — the deletes, gets, config-gets and updates,
  # once each family's create and list are counted among the ten above — stay
  # here deliberately, and the reason is written down so a later reader does not
  # "fix" it: each of those action names already determines its
  # one resource type — `GetCachePolicy` cannot be authorised against anything
  # but a cache policy — so `Resource: "*"` and `Resource: "cache-policy/*"`
  # admit and refuse exactly the same set of requests. Scoping them buys no
  # access control whatsoever and spends characters against the
  # 10,240-character aggregate inline-policy cap this file documents at the
  # bottom. The same argument keeps the four distribution-typed actions here —
  # `DeleteDistribution`, `UpdateDistribution`, `GetDistribution` and
  # `GetDistributionConfig`: until the `aws:ResourceTag/Project` condition the
  # apply-role section above defers is actually written, `distribution/*` is
  # another spelling of `*`.
  #
  # What the enumeration itself buys — and no ARN scoping would have bought — is
  # excluding the CloudFront surface this repository has no use for: key groups,
  # public keys, streaming distributions, realtime log configs, WAF
  # associations, and the account-level settings.
  #
  # Three invalidation actions are deliberately absent, and their absence is the
  # thing most likely to be read as an oversight here, so it is written down.
  # `cloudfront:CreateInvalidation`, `cloudfront:GetInvalidation` and
  # `cloudfront:ListInvalidations` used to sit in the list below and were removed
  # because nothing in this repository ever called them with this role. There is
  # no `aws_cloudfront_invalidation` resource in the AWS provider, this module
  # declares nothing that invalidates, and no workflow here shells out to
  # `aws cloudfront`. A permission granted against a call that is never made is
  # not spare capacity; it is reach nobody is watching.
  #
  # The apparent contradiction, and the reason it is not one. This role *does*
  # write an invalidation grant on every apply: `modules/static-site/iam.tf`'s
  # `InvalidateDistribution` statement grants `cloudfront:CreateInvalidation` and
  # `cloudfront:GetInvalidation` to the app repository's deploy role, and this
  # role installs it with `iam:PutRolePolicy`. That is allowed, and it is allowed
  # by design rather than by an accident of the boundary: **IAM does not require
  # a principal to hold a permission in order to grant it.** There is no
  # `iam:PassRole`-style coupling between writing a policy and holding what it
  # says. What constrains the deploy role is the permissions boundary the
  # conditioned half of `apply_identity` insists on, not the granting role's own
  # grants. Without that sentence sitting here, the first reader to notice that
  # this file hands out an invalidation permission it does not itself hold will
  # restore these three actions and undo the subtraction.
  #
  # If invalidation ever moves out of the app repository and into these
  # workflows, the actions come back — but not to this statement. Copy the shape
  # of `InvalidateDistribution` in `modules/static-site/iam.tf` instead: it pins
  # both actions to the exact distribution ARN, because that module knows the id
  # at the moment it writes the policy, which is the one place in this system
  # where that is true. Re-adding them here would put them back on `*`, which is
  # the shape this deletion exists to remove. Note also that
  # `InvalidateDistribution` carries `GetInvalidation` alongside
  # `CreateInvalidation` for a stated reason — the deploy's
  # `aws cloudfront wait invalidation-completed` polls it — so a copy that takes
  # only the create fails after the upload has already landed.
  statement {
    sid    = "ManageCloudFront"
    effect = "Allow"

    actions = [
      "cloudfront:CreateCachePolicy",
      "cloudfront:CreateDistribution",
      "cloudfront:CreateFunction",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:DeleteCachePolicy",
      "cloudfront:DeleteDistribution",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:GetCachePolicy",
      "cloudfront:GetCachePolicyConfig",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicyConfig",
      "cloudfront:ListCachePolicies",
      "cloudfront:ListDistributions",
      "cloudfront:ListFunctions",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:UpdateCachePolicy",
      "cloudfront:UpdateDistribution",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:UpdateResponseHeadersPolicy",
    ]

    resources = ["*"]
  }

  # The five `function` actions that take an ARN, held to the namespace this
  # repository names its functions in.
  #
  # `cloudfront:CreateFunction` is deliberately not among them and stays in the
  # statement above: it is one of the ten actions that authorise against `*`
  # only, so naming an ARN for it would match no request and deny every one —
  # the same trap the ACM split further down was written to avoid, in a service
  # where the mistake is even quieter because a plan never calls it.
  #
  # What this subtracts is real rather than cosmetic, which is what distinguishes
  # it from the cache-policy and OAC actions left above. `function/*` would have
  # been another spelling of `*`, but `function/<name_prefix>-site-*` is not:
  # a CloudFront function is account-scoped, functions created by anything else
  # in this account are outside the pattern, and this role can therefore no
  # longer read, republish, rewrite or delete one that does not belong to this
  # repository. The pattern is `local.site_function_arns`, whose comment carries
  # why a name pattern is trustworthy here where a tag condition is not.
  statement {
    sid    = "ManageSiteFunctions"
    effect = "Allow"

    actions = [
      "cloudfront:DeleteFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:GetFunction",
      "cloudfront:PublishFunction",
      "cloudfront:UpdateFunction",
    ]

    resources = local.site_function_arns
  }

  # The three tag actions, which are the only actions in these three statements
  # that reach more than one CloudFront resource type — and therefore the only
  # ones where naming ARNs removes something a `*` would have allowed.
  #
  # `TagResource` and `UntagResource` reach ten types on `*`;
  # `ListTagsForResource` reaches nine, the missing one being streaming
  # distributions, which cannot be listed this way. Past the distribution and the
  # function this repository actually creates, that is: streaming distributions
  # (the two writes only), key value stores, VPC origins, trust stores, anycast
  # IP lists, connection groups, connection functions and distribution tenants.
  # This repository creates none of them and has no use for any of them, so
  # naming the two types it does create is what takes them away.
  #
  # ---------------------------------------------------------------------------
  # `local.site_function_arns` is load-bearing on every run of every
  # environment. Do not remove it.
  # ---------------------------------------------------------------------------
  #
  # A CloudFront function is taggable — AWS's machine-readable service reference
  # lists the `function` resource type under all three of these actions, and
  # `CreateFunction` takes a `Tags` member — and the AWS provider tags it
  # transparently. `aws_cloudfront_function` carries the provider's
  # `@Tags(identifierAttribute="arn")` annotation, which wires the generic
  # tagging interceptor onto the resource, and the generated `listTags()` behind
  # that interceptor calls `cloudfront:ListTagsForResource` against the function
  # ARN on every *read* of it. Not only when a tag changes: on every refresh,
  # every plan against existing state, every apply and every destroy. Strike this
  # ARN out of the list and the next run of any environment fails on a read,
  # before it reaches anything it meant to change.
  #
  # Scoping this statement is what makes that dependency explicit — on `*` in
  # `ManageCloudFront` nobody had to know it existed — and it is written down
  # because the obvious tidy-up, "a function is untaggable, drop the second
  # pattern", is both wrong and silent in review. Nor is this a forward-looking
  # allowance: function tagging landed in AWS provider 6.49.0, thirteen minor
  # releases below the 6.62.0 this repository pins.
  #
  # ---------------------------------------------------------------------------
  # This statement carries no condition, and in particular no `aws:ResourceTag`.
  # That is not an omission. Do not add one.
  # ---------------------------------------------------------------------------
  #
  # The AWS provider does not create a distribution and then tag it in a second
  # call. It calls CreateDistributionWithTags — one API call, authorised against
  # `cloudfront:CreateDistribution` and `cloudfront:TagResource` together,
  # against a distribution that does not exist yet. A resource-tag condition
  # here would be evaluated against a resource with no tags to read, and in fact
  # with no resource at all; `StringEquals` on an absent key does not match, so
  # TagResource is refused and the create fails with it. The ARN pattern is not
  # the problem — `distribution/*` matches the distribution being created
  # perfectly well. It is the condition specifically that breaks it, which is
  # exactly the shape of mistake that reads as a tightening in review.
  #
  # Nothing in this repository would catch it. `validate.yml` runs without AWS
  # credentials and never calls CreateDistribution, so fmt, validate, lint, scan
  # and the module's plan tests all stay green; the failure surfaces on a real
  # apply, in whichever environment somebody deploys first after the edit, after
  # the bootstrap has already been hand-applied. This comment is the only
  # warning a future editor gets, which is why it is here rather than in a commit
  # message.
  statement {
    sid    = "TagSiteCdnResources"
    effect = "Allow"

    actions = [
      "cloudfront:ListTagsForResource",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
    ]

    resources = concat(
      local.site_distribution_arns,
      local.site_function_arns,
    )
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
#
# ---------------------------------------------------------------------------
# The other half of this ceiling is `data "aws_iam_policy_document" "app_deploy"`
# in modules/static-site/iam.tf, and nothing enforces the pair
# ---------------------------------------------------------------------------
#
# What the deploy role can actually do is the *intersection* of that document
# and this one. Today the five actions it grants all fall inside these
# statements: `s3:PutObject` under `s3:*Object*`, `s3:ListBucket` explicitly,
# `cloudfront:CreateInvalidation` explicitly, `cloudfront:GetInvalidation` under
# `cloudfront:Get*`, and `ssm:GetParameter` under `ssm:Get*` — and neither deny
# below touches any of them.
#
# That holds by inspection and by nothing else. The module receives this policy
# by *name* — `app_deploy_boundary_policy_name`, the output below — and composes
# an ARN from it; it never reads this body, and it could not, since no role here
# is granted `iam:GetPolicy` or `iam:ListPolicies`. The `check` further down
# asserts the composed ARN and says nothing about what is in it.
#
# So narrowing a family here is a change with no signal anywhere. It plans
# clean, it applies clean — a policy body edit is a new version applied in place,
# with no role touched — and this repository's plan, tests, lint and review all
# stay green. It surfaces as a runtime `AccessDenied` in the *app* repository's
# deploy job, naming an action whose grant is plainly visible in the role's own
# inline policy, from a ceiling that repository cannot see. Widening the module's
# policy past this one fails the same way, from the other direction.
#
# No static check closes that: implementing IAM's wildcard semantics correctly
# (`*Object*` matching mid-token, `Get*` as a prefix, resource wildcards spanning
# `/`) is fiddly, and a half-correct subset-checker would pass on the day it
# mattered. What actually exercises the intersection is the app repository's
# first deploy, with a real token — no AWS principal is trusted by that role, so
# nothing here can rehearse it. Change either document and deploy stage.
# docs/DEPLOY_CONTRACT.md section 7 is where a consumer reads this.
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
#
# Rendered once per environment, and that `for_each` is doing the whole of the
# work that turns the two grants below from a namespace grant into a role grant.
# Both name `local.app_deploy_role_arns_by_environment[each.key]` — the exact ARN
# of the one deploy role this environment's apply role has any business
# touching — where they used to name `role/react-cloudfront-app-deploy-*`, under
# which the stage apply role could rewrite prod's deploy role outright. The
# apply-role section above walks that reach, why closing it came before the
# CloudFront scoping this file still defers, and — the part not to skip — the
# neighbouring escalation the change does *not* close.
#
# `local.app_deploy_boundary_arn` is deliberately not per-environment beside it.
# One boundary policy, shared, named both by the condition on the bounded half
# and by `DenyBoundaryPolicyEdit`, and `aws_iam_policy.app_deploy_boundary` is a
# single resource rather than one per environment. Splitting it would take a
# policy per environment and a condition per role, for a ceiling that is
# identical in every one of them; the price of not splitting it is the residual
# the section above states in full.
data "aws_iam_policy_document" "apply_identity" {
  for_each = toset(var.environments)

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
    #
    # One exact role ARN, not the `app_deploy_role_arn` pattern still in scope
    # here. Substituting the pattern back in raises no error at plan or apply and
    # hands this environment's apply role `iam:UpdateAssumeRolePolicy` over every
    # other environment's deploy role.
    resources = [local.app_deploy_role_arns_by_environment[each.key]]

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

    # The same exact ARN as the bounded half above, and it matters more here than
    # it looks. This is the half the `iam:PermissionsBoundary` condition cannot
    # cover, so the resource is the *only* thing narrowing it: under the old
    # pattern, `iam:DeleteRole` in this list reached every environment's deploy
    # role with no condition anywhere in the way, and deleting prod's deploy role
    # mid-cycle is a broken deploy in the other repository rather than an
    # escalation — quieter than the escalation above and easier to do by
    # accident.
    resources = [local.app_deploy_role_arns_by_environment[each.key]]
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
# `apply_infrastructure` allows no such choice: it carries no per-environment
# divergence to make one about, so a mirror of it is current or it is wrong.
#
# `apply_identity` used to be in that sentence and is not any more, which is the
# kind of change a mirror maintainer will not notice until it costs them. It is
# rendered per environment now, naming one exact app deploy role ARN in each
# copy, so it has the same property `apply_state` has: a mirror copied from one
# environment's rendering is silently wrong for every other. It would create and
# delete stage's deploy role and no other, and that surfaces as an AccessDenied
# on `iam:CreateRole` part-way through an apply of prod, quoting an ARN the
# mirror does not mention anywhere. Mirror one per environment, or take the union
# of the role ARNs as a deliberate choice.
#
# Edit any of these documents and re-sync every mirror of it in the same change,
# not a follow-up one. A mirror that has fallen behind does not
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

# Per environment, unlike the one above: `apply_identity` names the exact ARN of
# this environment's app deploy role, so there is one rendered document per
# environment to index into rather than one document attached N times. It is
# still a single `data` block, so the argument the comment above makes about not
# letting a shared document drift into N hand-maintained copies is satisfied here
# too — `for_each` is what keeps both properties at once.
resource "aws_iam_role_policy" "apply_identity" {
  for_each = aws_iam_role.apply

  name   = "identity"
  role   = each.value.id
  policy = data.aws_iam_policy_document.apply_identity[each.key].json
}

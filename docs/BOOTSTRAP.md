# Bootstrap runbook

`bootstrap/` is the chicken-and-egg layer. It creates the S3 bucket that every other root in
this repository keeps its state in, the GitHub Actions OIDC provider, and the two roles CI
assumes — the things that have to exist before any environment can be applied at all.

It is applied **once, by hand, on local state**, and it is the only root in this repository
ever applied with an elevated AWS identity. Everything afterwards runs through the two roles it
creates, from a workflow, with no long-lived access key anywhere.

This document is written for a stranger with an empty AWS account. Follow it top to bottom.

> **This runbook has not been walked end to end.** Nothing in this repository has been applied
> against a real AWS account yet, so the procedure below is derived from the configuration
> rather than from a run that produced it. Step 6.1 of the build plan is where the from-zero
> path — empty account, fresh clone, bootstrap, apply, verify, destroy, and the bootstrap
> teardown itself — gets walked and dated in the README. Until that date is there, treat the
> AWS-side steps as reviewed but unexecuted, and expect the apply role's policy in particular
> to be missing an action or two: it was derived service by service from what this repository
> creates, and its intended failure mode is a named `AccessDenied` rather than a wildcard that
> never fails.

## Why there are no values in this runbook

Every value the bootstrap produces is emitted by `bootstrap/outputs.tf`, and this document
points at those outputs rather than transcribing them. That is deliberate three times over: a
cloner's bucket name, account id and role ARNs differ from anyone else's in every character
that matters; the bucket name carries a `random_id` suffix that is re-minted on every teardown
cycle, so a recorded literal is stale within the hour; and this file is committed to a public
repository, where a pasted account id is the likeliest leak in the whole project.

Placeholders below — `<owner>`, `<repo>`, `<account-id>`, `<env>`, `<name_prefix>` — are yours
to substitute.

---

## 1. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Terraform | exactly what `.terraform-version` pins | `tfenv` and `tenv` both read that file |
| AWS CLI | v2 | |
| `gh` | recent | authenticated as an account that admins the repository |

Homebrew's `hashicorp/tap` currently serves a patch *below* the pinned one, so
`brew install terraform` cannot satisfy `.terraform-version`. Install through `tfenv` or `tenv`,
or take the binary from `releases.hashicorp.com`. A pin no local install can reach is a pin that
gets quietly edited downward by the first person who hits it.

**The AWS identity for this step is elevated and temporary.** The bootstrap creates an IAM
OIDC provider and two IAM roles with inline policies, so it needs roughly:

```
s3:CreateBucket, s3:PutBucket*, s3:PutEncryptionConfiguration, s3:PutLifecycleConfiguration,
s3:GetBucket*, s3:GetEncryptionConfiguration, s3:GetLifecycleConfiguration, s3:ListBucket
iam:CreateOpenIDConnectProvider, iam:GetOpenIDConnectProvider, iam:TagOpenIDConnectProvider
iam:CreateRole, iam:GetRole, iam:PutRolePolicy, iam:GetRolePolicy, iam:TagRole,
iam:ListRolePolicies, iam:ListAttachedRolePolicies, iam:ListRoleTags
sts:GetCallerIdentity
```

Most people will run this as an account administrator, which is fine for a one-shot manual
step. The list is here for anyone who cannot. Add the matching `Delete*` actions if you intend
to walk the teardown in section 9.

## 2. Fill in `bootstrap/terraform.tfvars`

Five of the values are yours to name — region, `name_prefix`, `project`, `github_owner`,
`github_repository`. Two are not: the numeric GitHub owner and repository ids are facts about
your repository, and **the trust policies never match if they are left as someone else's**.
Read them from the API rather than typing them:

```bash
gh api repos/<owner>/<repo> --jq '{owner: .owner.id, repo: .id}'
```

Both ids are embedded in the OIDC subject GitHub actually mints — see section 10 — and neither
can be removed with claim customisation.

`name_prefix` becomes part of a globally unique S3 bucket name, so pick something a stranger is
unlikely to have taken. `environments` is the list of environment names this repository
deploys; it drives the state keys, the apply role's trusted-subject list, and the GitHub
Environments you create at build-plan step 4.2.

Nothing in this file is sensitive, which is why it is committed at all. Keep it that way: no
account id, no ARN, no token.

## 3. Apply

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
```

If the apply fails with `EntityAlreadyExists` on the OIDC provider, the account already has one
— an AWS account can hold exactly one provider per issuer URL, and something else in yours is
already using GitHub OIDC. Adopt it rather than working around it:

```bash
terraform -chdir=bootstrap import aws_iam_openid_connect_provider.github \
  arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
```

Then re-run the apply. Note that a subsequent `terraform destroy` of the bootstrap would then
delete a provider you did not create; if the account shares it, remove it from state with
`terraform state rm` before tearing down instead.

## 4. Keep the state file

`bootstrap/terraform.tfstate` is **local, gitignored, and worth keeping.** This root is
deliberately not self-hosting — it is the root that creates the bucket remote state lives in,
so there is nowhere to put remote state until it has already run.

That file is also the only place the state bucket's `random_id` suffix is remembered. Lose it
and the bucket, the provider and both roles have to be adopted back in one `terraform import`
at a time, against a bucket name you can only recover by listing the account.

Back it up somewhere outside the working copy.

## 5. Read the outputs

```bash
terraform -chdir=bootstrap output
```

The four that matter downstream:

| Output | Used by |
|---|---|
| `backend_init_command` | the literal `init -backend-config=…` line for an environment root |
| `repository_variable_commands` | the four `gh variable set` calls in section 6 |
| `oidc_provider_arn` | the `static-site` module, when it creates the app repository's deploy role |
| `site_bucket_name_prefix` | the name every site bucket must be created under (section 10) |

`terraform -chdir=bootstrap output -raw <name>` prints one without quoting, which is what you
want when piping it into anything.

## 6. Set the repository variables

```bash
terraform -chdir=bootstrap output -raw repository_variable_commands
```

Run the four lines it prints. They set `TF_STATE_BUCKET`, `AWS_REGION`, `AWS_PLAN_ROLE_ARN` and
`AWS_APPLY_ROLE_ARN` as repository **variables**, not secrets — `bootstrap/outputs.tf` argues
why at the point the values are produced, and the short version is that masking a role ARN
turns the single most common OIDC failure into an unreadable one.

Without these four, `plan.yml`, `apply.yml` and `e2e.yml` have no `role-to-assume` and no
backend configuration, and a fresh clone is unrunnable.

## 7. Configure the GitHub repository

Branch protection here is a reproducible API call, not something someone once clicked. Applied
against `main` from the first push onward.

### 7.1 The ruleset

```bash
gh api --method POST /repos/<owner>/<repo>/rulesets --input - <<'JSON'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge", "squash", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "terraform" },
          { "context": "tflint" },
          { "context": "trivy" },
          { "context": "actionlint" },
          { "context": "pr-title" }
        ]
      }
    }
  ]
}
JSON
```

**This is the shape, not a frozen final answer.** The required-check list grows once per gate
through Phases 2 to 4 — the module docs check, the module tests, the plan gate, the
workflow-policy check — and each of those steps re-issues this call with its own context added,
in the same step that introduces the check. A check that is not added to the ruleset when it
lands is a check that stays advisory until somebody notices. Update the ruleset in place with
`--method PUT /repos/<owner>/<repo>/rulesets/<id>` rather than creating a second one.

`strict_required_status_checks_policy` is `false` deliberately: requiring branches to be
up to date with `main` before merging forces a rebase and a full re-run of every check on every
merge, and buys nothing back when there is never anything else in flight. Flip it when a second
regular contributor arrives, or when a merge queue does.

### 7.2 The approving-review rule, which is deliberately not enabled

A single maintainer cannot approve their own pull request, so a required approval would mean
bypassing the ruleset on every commit — and a rule bypassed on every use is an off switch with
extra steps. The same argument keeps "require review from Code Owners" off once `CODEOWNERS`
lands: it drives review *requests*, which is what it is good for.

**Enable when a second maintainer exists** by replacing the `pull_request` rule's parameters
above with:

```json
{
  "required_approving_review_count": 1,
  "dismiss_stale_reviews_on_push": true,
  "require_code_owner_review": true,
  "require_last_push_approval": true,
  "required_review_thread_resolution": true,
  "allowed_merge_methods": ["squash"]
}
```

Kept as a separate block rather than as comments inside the payload above, because JSON has no
comment syntax and a payload you cannot paste is not a runbook step.

### 7.3 Secret scanning, push protection, and auto-merge

```bash
gh api --method PATCH /repos/<owner>/<repo> \
  -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

gh api --method PATCH /repos/<owner>/<repo> -F allow_auto_merge=true
```

Push protection is the only control in this repository that can be correct from the very first
push: it is server-side, it cannot be skipped with `--no-verify`, and it blocks the push rather
than reporting after the fact. `bootstrap/terraform.tfvars` and every `envs/*/terraform.tfvars`
are committed on the understanding that they hold no secrets; this is the backstop for the day
that stops being true.

`allow_auto_merge` is not cosmetic. Every commit from the third onward lands through
`gh pr create --fill && gh pr merge --squash --auto`, and with the setting off that second
command fails outright with "Auto merge is not allowed for this repository" — leaving you to
babysit each merge through gates that get slower with every phase.

Confirm squash merges take their subject from the pull request title, since that title is what
the Conventional Commits check in `validate.yml` actually validated:

```bash
gh api /repos/<owner>/<repo> --jq '{squash_merge_commit_title, squash_merge_commit_message}'
# expect: PR_TITLE / PR_BODY
```

## 8. A token for the scheduled provider-lock refresh *(needed from build-plan commit 25)*

Not required to bootstrap; required before the provider-lock refresh workflow is any use, and
it belongs here with the rest of the platform setup.

That workflow opens a pull request, and it **must not** use the default `GITHUB_TOKEN`. GitHub
raises no workflow events for actions taken with that token, so a pull request opened with it
gets no `validate.yml` run and no `plan-gate` run — it reports on none of the checks `main`
requires and is therefore blocked permanently, in a way that reads like the ruleset
misbehaving rather than like the token it is.

Create a fine-grained PAT or a GitHub App installation token scoped to this repository with
`contents: write` and `pull-requests: write`, and store it as a repository secret:

```bash
gh secret set PROVIDER_LOCK_TOKEN
```

Dependabot's own pull requests do not have this problem — they do trigger workflows — but they
carry a read-only token with no access to repository secrets, which is the constraint that
keeps the required check set credential-free.

## 9. Operations

### 9.1 A stranded state lock

This applies to the **environment** roots, not to this one: `bootstrap/` has no backend and
takes a local lock. The environments use native S3 locking, which writes `<key>.tflock` beside
the state object and deletes it when the run finishes. A Terraform process killed mid-flight —
a cancelled workflow, a closed laptop — leaves the object behind, and every subsequent run on
that environment blocks on it.

**Confirm no run is actually in flight first.** A `force-unlock` against a live apply is how
two processes end up writing the same state. Check the Actions tab, then read the lock rather
than assuming who owns it:

```bash
BUCKET="$(terraform -chdir=bootstrap output -raw state_bucket_name)"

aws s3api get-object --bucket "$BUCKET" \
  --key "<env>/terraform.tfstate.tflock" /dev/stdout
```

It names the operation, the user, the creation time and the lock id. Terraform prints the same
id in the error that sent you here. Then, from the environment root:

```bash
terraform -chdir=envs/<env> force-unlock <lock-id>
```

### 9.2 Everything else

Environment teardown, the destroy order across repositories, the measured CloudFront teardown
duration and the post-destroy orphan checklist live in `docs/TEARDOWN.md`. This file covers the
bootstrap layer only.

## 10. Tearing down the bootstrap

The state bucket and the OIDC provider are the only things in this design that outlive a cycle.
Removing them is a two-phase procedure, and the first phase is a hand edit that is never
committed.

**Phase 1 — empty the bucket.** A versioned bucket refuses to delete while any version or
delete marker remains, and `aws s3 rm --recursive` removes neither.

```bash
BUCKET="$(terraform -chdir=bootstrap output -raw state_bucket_name)"

# Object versions first, then the delete markers left over them. Each API call
# handles at most 1000 keys, so both loop until the bucket reports none left.
while [ "$(aws s3api list-object-versions --bucket "$BUCKET" \
            --query 'length(Versions || `[]`)' --output text)" != "0" ]; do
  aws s3api delete-objects --bucket "$BUCKET" --delete "$(
    aws s3api list-object-versions --bucket "$BUCKET" \
      --query '{Objects: Versions[].{Key: Key, VersionId: VersionId}}' \
      --output json)" > /dev/null
done

while [ "$(aws s3api list-object-versions --bucket "$BUCKET" \
            --query 'length(DeleteMarkers || `[]`)' --output text)" != "0" ]; do
  aws s3api delete-objects --bucket "$BUCKET" --delete "$(
    aws s3api list-object-versions --bucket "$BUCKET" \
      --query '{Objects: DeleteMarkers[].{Key: Key, VersionId: VersionId}}' \
      --output json)" > /dev/null
done
```

Destroy every environment before you do this. Emptying the state bucket while an environment
still stands strands its infrastructure with nothing left that knows how to remove it.

**Phase 2 — remove the guard, destroy, put the guard back.** `bootstrap/state.tf` carries
`lifecycle { prevent_destroy = true }` on the bucket, and `lifecycle` meta-arguments accept no
variables and no expressions — so this cannot be a flag, a `-var` or an environment switch. It
is a hand edit, in the working tree, reverted immediately afterwards:

```bash
# 1. Edit bootstrap/state.tf and delete the `prevent_destroy = true` line.
terraform -chdir=bootstrap destroy

# 2. Immediately, and without staging anything in between:
git checkout -- bootstrap/state.tf
```

**That edit is never committed.** A repository whose history contains "remove the state
bucket's guard" is a repository where a revert, a cherry-pick or a copy-paste removes it again
on a day nobody intended to. The friction is the guard: it is what stops an accidental
`destroy` from taking the state with it.

If you imported a pre-existing OIDC provider in section 3, run
`terraform -chdir=bootstrap state rm aws_iam_openid_connect_provider.github` before the destroy
so it survives.

---

## What a cloner needs to know

**Your GitHub ids are not the ones in `bootstrap/terraform.tfvars`.** Regenerate both and
re-apply, or `AssumeRoleWithWebIdentity` fails on the very first CI run with an error that
gives no hint why. Repositories created after 2026-07-15 mint tokens carrying the numeric owner
and repository ids in the subject, in this immutable form:

```
repo:<owner>@<owner-id>/<repo>@<repo-id>:pull_request
repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>
```

Those are the two subjects the plan role and the apply role trust. Both were read out of real
tokens rather than assembled from documentation.

**The `environment:` claim replaces the ref claim; it does not appear alongside it.** This was
measured on a `push` run and a `pull_request` run whose `ref` claims differed while their `sub`
claims were byte-identical. Two consequences a cloner will otherwise trip on:

- the apply role is scoped by **environment name**, never by branch, so a job that fails to
  declare `environment:` cannot assume it at all — which is exactly what makes the prod
  reviewer gate real rather than decorative;
- the branch restriction therefore cannot live in IAM at the same time. It lives in each
  GitHub Environment's **deployment branch policy** instead, configured at build-plan step 4.2,
  before any workflow names an environment. GitHub creates an environment implicitly the first
  time a job references one, with no protection rules at all.

**Adding an environment is an edit here, not just in `envs/`.** Append the name to
`environments` in `bootstrap/terraform.tfvars` and re-apply this root. The apply role cannot be
assumed from an environment its trust policy does not name, and the failure surfaces as an
`AssumeRoleWithWebIdentity` refusal in a workflow that looks correct.

**Site buckets must be named under `site_bucket_name_prefix`.** That is a contract, not a
convention. The apply role's S3 grant is a name pattern — a site bucket's name is unknowable in
advance, since it carries a random suffix that is re-minted every cycle — and the prefix is
what keeps that pattern disjoint from the state bucket's own name. A site bucket created
outside it cannot be managed by CI; a naming scheme that collapsed the two would hand the apply
role bucket-level control over the one bucket the whole design depends on surviving.

**No long-lived AWS access key exists anywhere in either repository.** If you find yourself
creating one to make something work, that is the bug.

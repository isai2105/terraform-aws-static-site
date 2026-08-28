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

Placeholders below are written in `<angle brackets>` — `<owner>`, `<repo>`, `<account-id>`,
`<env>` and the rest — and every one of them is yours to substitute.

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
to walk the bootstrap teardown in `docs/TEARDOWN.md`.

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
Environments you create in section 7.4.

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

Protection here is a reproducible API call, not something someone once clicked — the ruleset on
`main` from the first push onward, and the deployment gates the apply workflow authenticates
through.

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
          { "context": "pr-title" },
          { "context": "terraform-docs" },
          { "context": "terraform-test" },
          { "context": "plan-gate" }
        ]
      }
    }
  ]
}
JSON
```

**Those eight are the current set, and cloners should paste all eight.** Every one of them is
reported by a workflow in this repository today, so a ruleset carrying fewer is a gate that
silently is not there — drop `plan-gate` in particular and pull requests merge with no Terraform
plan gate at all, which is the omission that costs something rather than the one that shows up
as a missing badge.

**It is not a frozen final answer either.** The list grew one context per gate through Phases 2
to 4: the first five above are the set that exists when this runbook first runs in plan order,
and `terraform-docs`, `terraform-test` and `plan-gate` each arrive with the step that introduces
the check, which re-issues this call with its own context added. Anyone building the repository in
that order adds them as they land rather than up front, and the next gate does the same. A check
that is not added to the ruleset when it lands is a check that stays advisory until somebody
notices. Update the ruleset in place with `--method PUT /repos/<owner>/<repo>/rulesets/<id>`
rather than creating a second one.

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

### 7.4 The two GitHub Environments

`stage` and `prod` are not decoration on the apply jobs. The apply role is trusted on the
`environment:<env>` subject and on no ref at all — the claim, and why it *replaces* the ref
rather than joining it, are in "What a cloner needs to know" below — so a job that does not name
an environment cannot assume the role at all. What that does **not** buy is any assurance the
environment was ever configured, and the failure runs the wrong way round:

**Create both before any workflow names one.** GitHub creates an environment implicitly the
first time a job references it, with **no protection rules at all**. Reach a `prod` dispatch
first and the environment is auto-created unprotected: no reviewer, no branch restriction, the
apply runs ungated — and the Actions UI then shows a `prod` environment that looks configured
because it exists.

One limit before the calls, because it is not recoverable by editing the payload: environments
are configurable on a public repository under every plan, but on a **private** one only under
GitHub Pro, Team or Enterprise. A private clone on Free gets no reviewer and no branch policy,
and the apply role's `environment:` trust then gates nothing on its own.

`stage` is deliberately self-service. A reviewer requirement whose only reviewer is the person
dispatching records an approval that means nothing — which is section 7.2's conclusion about
required pull request approvals, reached from the opposite direction: there the single maintainer
*cannot* approve their own work, here they always can.

```bash
gh api --method PUT /repos/<owner>/<repo>/environments/stage --input - <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  },
  "can_admins_bypass": false
}
JSON
```

`prevent_self_review` does nothing on an environment with no reviewer, and `wait_timer` is inert
here because it is `0` rather than because there is no reviewer — it delays any job that names
the environment. Both are sent anyway, because a five-field body is the only shape that stays
correct the next time one of these is edited: see the full-replace note below.

`prod` adds a required reviewer. The array takes numeric ids, not logins, and `<reviewer-id>` is
the account that will do the approving — `gh api /users/<login> --jq .id`. Under a personal
account that is the same id section 2 read for the OIDC subject; under an organisation it is not,
and a team can be named instead with `"type": "Team"` and the team's id.

```bash
gh api --method PUT /repos/<owner>/<repo>/environments/prod --input - <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": <reviewer-id> } ],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  },
  "can_admins_bypass": false
}
JSON
```

`prevent_self_review` is `false` on `prod`, and that is the correct value here rather than a
compromise. With one maintainer — who is also the person dispatching `apply.yml` — `true` means
the only account that can approve a deployment is the account forbidden from approving it, and
prod becomes permanently unapprovable. It is the sibling of section 7.2's review count and flips
at the same moment: the day a second maintainer exists, set it `true` and raise the count
together.

`can_admins_bypass` is `false` on both. Left at its default of `true`, a repository
administrator can push a pending deployment past the reviewer gate at run time, and this
repository has exactly one administrator — the same person who dispatches the workflow. The
gate would then record an approval its approver could always skip.

**The named branch policy is a second call.** The PUT above only declares that this environment
*uses* custom branch policies — it declares the mode, not the list, and creates no policy at
all. Until the POST below runs, both environments carry a policy list that matches nothing:

```bash
for env in stage prod; do
  gh api --method POST \
    /repos/<owner>/<repo>/environments/"$env"/deployment-branch-policies \
    -f name=main -f type=branch
done
```

**`protected_branches: true` is the wrong mechanism here, and it is the trap in this
subsection.** It looks like the simpler option — restrict deployments to protected branches, done
— but the REST reference defines it as "whether only branches with **branch protection rules**
can deploy to this environment", and section 7.1 protects `main` with a **ruleset**, which is a
different system. The two disagree in the API, and this is worth seeing once:

```bash
gh api /repos/<owner>/<repo>/branches/main --jq '{protected}'
# {"protected":true}

gh api /repos/<owner>/<repo>/branches/main/protection
# {"message":"Branch not protected", ...} on stdout, then
# gh: Branch not protected (HTTP 404) on stderr, and a non-zero exit
```

Both answers are correct about their own system. Which of them the deployment gate consults is
not a question this repository can settle from outside, and a wrong answer is silent — the
policy exists, the UI shows a restriction, and every branch deploys. The named `main` policy
does not depend on the answer, so use it and leave `protected_branches` at `false`.

**Treat the PUT as a full replace, and resend all five fields on every later edit.** A PUT that
replaces the resource drops what it omits, so a four-field body — the natural one to send, since
four fields is the documented schema — would take `can_admins_bypass` back to its `true` default,
and a body without `deployment_branch_policy` would take the branch restriction with it. Both
would return HTTP 200 and leave an environment that still exists and still looks configured.

**That reading is inferred rather than measured, and the doubt is worth stating.** The REST
reference lists exactly `wait_timer`, `prevent_self_review`, `reviewers` and
`deployment_branch_policy` — `can_admins_bypass` is not in the PUT body schema at all (checked
against docs.github.com's environments reference, 2026-08-28) — and it says nothing either way
about what happens to a field left out. No partial PUT has been tried here to settle it. What
*is* observed is that the undocumented field is accepted and takes effect on the way in: both
environments read back `false` after exactly the payloads above. So resend all five, which costs
nothing, and let the check below be the thing you trust.

Verify after creating them, and after any later edit:

```bash
for env in stage prod; do
  echo "$env"
  gh api /repos/<owner>/<repo>/environments/"$env" \
    --jq '{can_admins_bypass, rules: [.protection_rules[].type]}'
  gh api /repos/<owner>/<repo>/environments/"$env"/deployment-branch-policies \
    --jq '[.branch_policies[].name]'
done
```

which prints, on a repository configured as above:

```
stage
{"can_admins_bypass":false,"rules":["branch_policy"]}
["main"]
prod
{"can_admins_bypass":false,"rules":["required_reviewers","branch_policy"]}
["main"]
```

Two ways this can disagree, both fixable in place. A `can_admins_bypass` of `true` means the
undocumented field did not take: clear it from the environment's settings page — **Allow
administrators to bypass configured protection rules** — and re-run the check. An empty `[]`
means the named policy was never created or did not survive an edit: re-run the POST above. It
cannot duplicate one — the reference documents a 303 for a branch name pattern that already
exists — though what `gh` prints for that response has not been checked here.

**Expect a prod dispatch to cost two approvals, not one.** Both jobs in `apply.yml` name the
environment — the plan job has to, because from a dispatch the apply role is the only credential
that reaches prod state, and it is trusted on the `environment:` subject alone — and every job
that names an environment creates its own deployment against it. Two deployments per dispatch is
measured: a `stage` destroy produced one per job, and the header comment in
`.github/workflows/apply.yml` names that run and both deployment ids. That prod therefore asks
the reviewer twice — once to take the plan, once to apply it, and only the second request has a
plan to read — follows from each of those two deployments having to clear prod's gate, and has
not been watched happen: nothing has been dispatched against `prod` yet. Worth knowing before the
second prompt arrives looking like a stuck run.

**The environment names are a verbatim contract.** The same two strings are `environments` in
`bootstrap/terraform.tfvars`, the `:environment:<env>` subjects in the apply role's trust policy,
and the `<env>/terraform.tfstate` state keys. The two halves break in opposite directions, which
is the reason to spell it out: change the name in `bootstrap/terraform.tfvars` alone and the next
dispatch is refused at `AssumeRoleWithWebIdentity`, loudly, from a workflow that reads as
correct. Rename or delete the GitHub Environment alone and nothing is refused at all —
`apply.yml` still names the old string, GitHub re-creates it on reference with no protection
rules, the OIDC subject is unchanged, and the apply runs ungated. The loud failure is the safe
one.

**A default-branch rename breaks both environments.** The ruleset in section 7.1 survives one,
because it matches `~DEFAULT_BRANCH` rather than a name; these policies do not, because `main` is
written into each of them literally. Every dispatch is then refused until both are replaced. The
check above reads the listing endpoint that carries each policy's id but projects only the names,
so read it again without the `--jq` to get the ids, `DELETE` each policy, and POST the new name.

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
id in the error that sent you here. **`Operation` reads `OperationTypeApply` even for a
destroy** — a destroy is an apply of a destroy plan — so it tells you a run was in progress and
not which direction it was going. Then, from the environment root:

```bash
terraform -chdir=envs/<env> init -input=false -backend-config=backend.hcl
terraform -chdir=envs/<env> force-unlock <lock-id>
```

The `init` is not optional and not first-time-only. `force-unlock` reaches the lock through the
backend, and `make validate` removes the backend record from these roots on every run — which
is what keeps the checks runnable without AWS credentials — so an environment root is routinely
uninitialised when you arrive here.

`docs/TEARDOWN.md` section 5 walks this end to end against a real killed destroy, including why
the state file cannot be trusted to say what that run removed.

### 9.2 Everything else

Teardown lives in `docs/TEARDOWN.md` — the destroy order across the three layers, the measured
CloudFront teardown duration, the post-destroy orphan checklist, and the two-phase removal of
this root's own `prevent_destroy` guard. This file covers standing the platform up.

## 10. Tearing down the bootstrap

The state bucket and the OIDC provider are the only things in this design that outlive a cycle,
and removing them is the last step of a teardown rather than an operation of its own. The full
procedure — every environment destroyed and swept first, the versioned bucket emptied, then the
uncommitted `prevent_destroy` hand edit and the `git checkout -- bootstrap/state.tf` that
reverts it — is `docs/TEARDOWN.md` section 8, where it sits in the order it has to run in.

One caveat belongs here too, because it is a consequence of section 3: if you imported a
pre-existing OIDC provider rather than creating one, it has to be removed from state before that
destroy or it goes with the rest, taking GitHub OIDC away from everything else in the account
that uses it. `docs/TEARDOWN.md` section 8 carries the command at the point it is needed.

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
  GitHub Environment's **deployment branch policy** instead, configured in section 7.4,
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

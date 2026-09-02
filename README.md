# terraform-aws-static-site

**Nothing here stays deployed, and there is no live URL to go and look at.** This is a reference
implementation of a static-site stack on AWS — a private S3 bucket served through CloudFront —
and its operating model is that every environment is applied, verified and destroyed inside the
same hour. There is no long-running demo environment, no drift detection and nothing on call.
What is on offer instead is a lifecycle you can run yourself, in your own AWS account, from a
fresh clone: `stage` and `prod` both stand up from zero, serve real traffic, and come down again
leaving nothing behind — and a weekly CI job runs that whole lifecycle against `stage`, proving
it still holds against whatever AWS and the pinned provider have become since the last run.
`prod` runs the same code and is exercised by hand, for a reason the tradeoffs section gives.

That constraint is what the rest of this repository is arranged around. Reproducibility from zero
and complete, verifiable teardown are the goals; uptime and cost optimisation of running
infrastructure are not. Anything that blocks or survives `terraform destroy` is treated as a
defect here, which is why `docs/TEARDOWN.md` is a 39KB runbook rather than a paragraph.

This repository builds infrastructure only. It never uploads an application. A second repository
— `react-cloudfront-app` — builds and deploys the site, through an identity this repository
creates for it and destroys with the environment; `docs/DEPLOY_CONTRACT.md` is the whole of that
interface.

---

## What it builds

One `static-site` module, called once per environment. Twenty-three resources per environment on
the default path (no custom domain), of which the CloudFront distribution is
essentially the whole wall clock — 93% of a measured destroy, and the same shape on apply.
Everything else costs seconds.

```
  viewer ──HTTPS──▶ CloudFront distribution ──OAC / SigV4──▶ S3 bucket (private)
                     │                                       no website config,
                     │                                       no public read, no ACLs
                     ├─ 2 cache + 2 response headers policies, one pair per behaviour.
                     │  BOTH carry CSP + HSTS + nosniff; only Cache-Control differs:
                     │    /assets/*         public, max-age=31536000, immutable
                     │    everything else   no-cache
                     │
                     ├─ viewer-request function: a URI naming no file → /index.html
                     │
                     └─ standard logging (v2) ──▶ CloudWatch Logs, always in us-east-1

  beside them, created and destroyed with the environment:

    SSM parameters      /static-site/<env>/{bucket_name, cloudfront_distribution_id, site_url}
    IAM role            the app repository's deploy identity, trusted on its OIDC subject
                        and carrying a permissions boundary the bootstrap owns
```

The bucket's only grant names the CloudFront service principal and is conditioned on this
distribution's ARN, so it is unreachable except through the distribution. The three SSM
parameters exist because the bucket name carries a `random_id` suffix that is re-minted on every
apply — the app repository reads them at deploy time rather than remembering anything.

The control plane, which is where most of the design actually lives:

```
  bootstrap/            applied ONCE, by hand, on local state, with an elevated identity
    ├── S3 state bucket (versioned, SSE, prevent_destroy)
    ├── GitHub Actions OIDC provider
    ├── <prefix>-ci-plan            trusted on  repo:<owner>@<id>/<repo>@<id>:pull_request
    ├── <prefix>-ci-apply-<env>     one per environment, trusted on
    │                                   repo:<owner>@<id>/<repo>@<id>:environment:<env>
    └── app-deploy permissions boundary (a managed policy, outlives every environment)
                    │
                    ▼
  envs/stage  envs/prod        applied through those roles, from a workflow,
                               with no long-lived AWS access key anywhere
```

That lower half is **workload identity federation**: the CI roles trust no AWS principal at all,
only `sts:AssumeRoleWithWebIdentity` from that provider, conditioned on `aud` and on exactly the
subjects above. `bootstrap/` itself is a human at a terminal with an exported session, and
deliberately not that.

There is no VPC, no NAT gateway, no EC2 instance and no ALB in this repository. That stack lives
in its own repository; see the tradeoffs section for why it is not a third environment here.

## Repository map

| Path | What it is |
|---|---|
| `bootstrap/` | The chicken-and-egg layer: state bucket, OIDC provider, one plan role, one apply role per environment, and the app-deploy permissions boundary. Applied by hand on local state, because it creates the bucket remote state lives in. `state.tf`, `oidc.tf`, `outputs.tf`. |
| `modules/static-site/` | The only module. `s3.tf`, `cloudfront.tf`, `policies.tf` (cache + response headers), `logging.tf` (vended logs to CloudWatch in us-east-1), `ssm.tf`, `iam.tf` (the app repository's deploy role), `certificate.tf` (the optional custom-domain path), `tags.tf`. Its `README.md` carries the interface, with the inputs and outputs tables generated by terraform-docs. |
| `modules/static-site/tests/` | `plan.tftest.hcl`. Every run block is `command = plan` and the providers are configured with fake credentials, so the suite needs no AWS account and can be a required check on a pull request from a fork. |
| `modules/static-site/examples/default/` | A caller that exists so `terraform validate` has a root through which to type-check a module declaring `configuration_aliases`. Deliberately excluded from terraform-docs. |
| `envs/stage/`, `envs/prod/` | One module call each and nothing else — no resources, no conditionals. Three data sources are the one carve-out, and `main.tf` says why. `backend.hcl.example` is tracked; `backend.hcl` is gitignored because the state bucket name is per-account. |
| `docs/BOOTSTRAP.md` | Standing the platform up: prerequisites, `terraform.tfvars`, the apply, the repository variables, the branch ruleset, the two GitHub Environments, the provider-lock token. |
| `docs/TEARDOWN.md` | Taking it down: destroy order across the three layers, the measured CloudFront teardown, recovering an interrupted destroy, the eleven-row post-destroy orphan sweep, and the two-phase removal of the bootstrap's own `prevent_destroy` guard. |
| `docs/DEPLOY_CONTRACT.md` | The interface `react-cloudfront-app` is written against: the deploy role and its trust subject, the SSM parameter names, the four-command upload sequence, and the CSP both repositories have to agree on. |
| `Makefile` | Every check and every environment verb. `make help` lists them. CI invokes these targets rather than reimplementing them, so a local run and a green check are the same command. |
| `.github/workflows/` | `validate.yml` (nine AWS-free jobs), `plan.yml` (a plan per environment a pull request changes), `apply.yml` (dispatch-only apply *or* destroy, gated on a GitHub Environment), `e2e.yml` (weekly full lifecycle against real AWS), `provider-lock-refresh.yml`. |

---

## Quickstart, from an empty AWS account

Written for someone who has cloned this and has nothing else. It is the short path; the three
runbooks in `docs/` carry the failure modes, and each step below names the one it points at.

### Before you start

| Tool | Version | Why this floor |
|---|---|---|
| Terraform | exactly what `.terraform-version` pins (1.15.9 today) | Native S3 state locking is GA from 1.11 and every root declares that floor. Homebrew's `hashicorp/tap` currently serves a patch *below* the pin, so install through `tfenv`/`tenv` or take the binary from `releases.hashicorp.com`. |
| AWS CLI | v2 (2.13+ if your profile uses MFA) | `aws configure export-credentials` is the only way to hand an MFA-backed session to the provider — the SDK never prompts and cannot read the CLI's cached session. |
| `gh` | recent, authenticated as a repository admin | The ruleset, the two GitHub Environments and the repository variables are API calls, not clicks. |
| `make` | any | Optional but assumed below. |
| `tflint`, `trivy`, `terraform-docs`, `zizmor` | exactly what the `Makefile` pins | Only for `make lint scan docs-check audit`; nothing in the quickstart needs them. Each target checks the binary's version, refuses to run on a different one, and the error names the pin and how to install it. |

You also need a GitHub repository you administer — a fork or your own clone — because the OIDC
trust policies embed **your** numeric owner and repository ids. Leaving someone else's in place
fails at the first CI run with an `AssumeRoleWithWebIdentity` error that gives no hint why.

**Use an AWS account that holds nothing you are unwilling to lose.** The AWS account, not the
GitHub one: GitHub appears here only as the OIDC issuer that mints the token, and no role this
repository creates has any access to your repositories. Inside AWS, `bootstrap/oidc.tf` grants the
CI apply roles `cloudfront:DeleteDistribution` and `cloudfront:UpdateDistribution` on
`Resource: "*"`, and `acm:DeleteCertificate` on every certificate in the AWS account, because a
distribution's id is not knowable in advance. That is defensible in a dedicated AWS account and
only there. A pre-existing distribution in that same AWS account is inside the blast radius of a
bad merge.

### 1. Bootstrap — once, by hand

```bash
gh api repos/<owner>/<repo> --jq '{owner: .owner.id, repo: .id}'   # your two numeric ids
$EDITOR bootstrap/terraform.tfvars                                 # region, name_prefix, project,
                                                                   # owner/repo names, both ids,
                                                                   # environments = ["stage","prod"]
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
```

`name_prefix` becomes part of a globally unique S3 bucket name, so pick something a stranger is
unlikely to have taken.

Then three things that are easy to skip and expensive to skip. Only the first is needed to apply
an environment from your own terminal; the other two are what make CI work, and skipping them
leaves a repository whose workflows all fail at `role-to-assume`:

- **Back up `bootstrap/terraform.tfstate`.** It is local and gitignored on purpose — this is the
  root that creates the bucket remote state lives in, so there is nowhere to put remote state
  until it has run. It is also the only place the state bucket's `random_id` suffix is
  remembered. Lose it and every resource has to be adopted back one `terraform import` at a time,
  against a bucket name you can only recover by listing the account.
- **Set the repository variables and configure GitHub** — `docs/BOOTSTRAP.md` sections 6 and 7.
  `terraform -chdir=bootstrap output -raw repository_variable_commands` prints the `gh variable
  set` lines ready to paste. Without them `plan.yml`, `apply.yml` and `e2e.yml` have no
  `role-to-assume` and no backend configuration, and a fresh clone is unrunnable.
- **Create both GitHub Environments before any workflow names one** (section 7.4). GitHub creates
  an environment implicitly the first time a job references it, *with no protection rules at
  all* — no reviewer, no branch restriction — and the Actions UI then shows a `prod` that looks
  configured because it exists.

Full runbook, including the MFA-profile trap and what to do if the account already has a GitHub
OIDC provider: **`docs/BOOTSTRAP.md`**.

### 2. Point an environment at your state bucket

```bash
cp envs/stage/backend.hcl.example envs/stage/backend.hcl
terraform -chdir=bootstrap output backend_init_command   # the bucket and region to paste in
$EDITOR envs/stage/backend.hcl                           # bucket + region only; leave `key` alone
$EDITOR envs/stage/terraform.tfvars                      # all nine values: aws_region, name_prefix,
                                                         # project, github_owner, github_repository,
                                                         # the three app_github_* values, and the
                                                         # boundary policy name
```

`backend.hcl` is gitignored because the bucket name is per-account. Do not change `key`: the plan
and apply roles scope their state grants to exactly `<env>/terraform.tfstate`, so a different key
is a key no role can read, failing at `init` with an `AccessDenied` that says nothing about the
line that caused it.

**All nine of those values, not just the ones that look account-specific.** The file is committed
pre-filled with the author's, so anything left unedited is silently inherited rather than left
blank, and `project` is the one that bites quietly: it is the tag the teardown assertion queries,
so a wrong value makes that query "match nothing, therefore clean" and report success over a
leak. `envs/stage/terraform.tfvars` argues each of the nine and what its wrong value costs.

`envs/prod` is the same two edits with `prod` substituted. The two roots are deliberately near
identical — one module call each, different values — and everything that distinguishes them is a
value rather than a structure.

One friction point worth knowing before you hit a validation error: the four `app_*` values in
`terraform.tfvars` describe the *application* repository's deploy identity, and none of them has
a default, because the module cannot resolve an identity in a repository it cannot see.
`app_deploy_boundary_policy_name` is the one of the four your own bootstrap produced — take it
from `terraform -chdir=bootstrap output -raw app_deploy_boundary_policy_name` rather than typing
it, since IAM will not create the role at all if the boundary it names does not exist. If you
have forked `react-cloudfront-app`, read the two numeric ids from it with
`gh api repos/<owner>/react-cloudfront-app --jq '{owner: .owner.id, repo: .id}'`. If you have
not, put your own GitHub owner id and any numeric repository id in and carry on: the environment
still applies, and what you get is a deploy role whose trust subject no token will ever match —
harmless, and destroyed with the environment. The role's *name* is not configurable at all, since
the bootstrap scopes both apply roles to the pattern `role/react-cloudfront-app-deploy-*`.

### 3. Apply

```bash
make apply-stage      # init -backend-config=backend.hcl, then apply, with a confirmation prompt
```

`make plan-stage` first if you want to read it. Neither target passes `-auto-approve` or
`-input=false` *to the verb itself* — the `init` these targets run first does get `-input=false`,
where there is nothing to confirm. The interactive confirmation on apply and destroy is the only
thing standing between a mistyped target and a real environment, which also makes these targets
unusable from a script — CI applies a reviewed plan artefact instead, which is a stronger control
than a prompt.

### 4. Verify

```bash
SITE_URL="$(terraform -chdir=envs/stage output -raw site_url)"

curl -sS -D- -o /dev/null "$SITE_URL/"            # 200; cache-control: no-cache;
                                                  # content-security-policy; x-content-type-options
curl -sS -o /dev/null -w '%{http_code}\n' "$SITE_URL/projects/x"   # 200 — a deep link naming no
                                                  # file, rewritten to /index.html at the edge
```

The environment serves a seeded placeholder `index.html` from the first apply, so this works
before anything has ever been deployed into it. `e2e.yml` asserts these weekly and more: the CSP
read back from Terraform's own value, HSTS by shape, that the rewritten deep link still comes
back `no-cache` under the *document's* policies, that an object under `/assets/` comes back
`public, max-age=31536000, immutable`, and — the assertion the viewer-request function exists for
— that `GET /assets/does-not-exist.js` returns the origin's own 403 rather than the application
document under a 200. No wait-for-`Deployed` step is needed:
the module sets `wait_for_deployment = true`, so `terraform apply` has already waited.

### 5. Destroy, and prove it

```bash
make destroy-stage
```

Run it in the foreground, somewhere a hangup or a closed laptop cannot reach it. A destroy is
about three minutes of a process doing nothing but polling CloudFront, and one of the three
destroys measured on 2026-08-27 was killed 90 seconds in, which cost a stranded state lock and a
recovery — `docs/TEARDOWN.md` section 5 is that recovery, written from the real event.

**A destroy exiting 0 is a claim, not evidence.** `docs/TEARDOWN.md` section 6 is an eleven-row
sweep against AWS rather than against Terraform, and four of its rows exist because nothing else
can see them. Cache policies, response headers policies, origin access controls and CloudFront
functions all expose no tags at all — the CloudFront API has nowhere to put them — so a leak in
any of the four is invisible to a tag query, and no amount of tagging harder fixes it. Two of
them each burn one of two quotas of **20 per account**: the custom cache policies and the custom
response headers policies. The other two are named with the bucket's random suffix, so a leak
collides with nothing on the next apply and a name-stable check cannot see it either. The quota
failure surfaces later, at *apply* time, on an unrelated environment, naming nothing about the
leak that caused it.

To return the account to empty, tear down the bootstrap too — `docs/TEARDOWN.md` section 8. Three
phases, and the order does not survive being rearranged: confirm nothing still carries the
app-deploy boundary (IAM refuses `DeletePolicy` while anything does, and the only remedy is to
destroy the environment holding it — which becomes impossible once its state bucket is empty);
empty the versioned state bucket, versions *and* delete markers, because `aws s3 rm --recursive`
removes neither; then hand-edit `prevent_destroy` out of `bootstrap/state.tf`, destroy, and
`git checkout -- bootstrap/state.tf` to put the guard back. Emptying the state bucket while an environment is
still standing strands that environment's infrastructure with nothing left that knows how to
remove it, and there is no undo and no detector for it afterwards.

### How long one cycle takes

Measured, dated, and on one account, one region pair, one provider version. It is a measurement,
not a service level.

| Step | Wall clock | Source |
|---|---|---|
| `terraform -chdir=bootstrap apply` | **not timed** | Creates only S3 and IAM resources, none of which has a propagation wait — but no run of it has been stopwatched, so no figure is quoted. |
| GitHub configuration (`docs/BOOTSTRAP.md` §6–7) | **not timed** | Roughly a dozen `gh` calls, done once. |
| `make apply-stage` | **~3 min** | A 17-resource environment applied in **2m53s** / **2m54s** on 2026-08-27, of which the distribution alone was 2m43s (`docs/TEARDOWN.md` §3). Distribution creation was **3m14s** on 2026-09-01 — **single run**, see below. |
| Verify with `curl` | seconds | — |
| `make destroy-stage` | **~3 min** | A 17-resource environment destroyed in **3m01s** on 2026-08-27, of which the distribution was **2m48s** — the ~93% above. Within that distribution phase, **2m32s** (~98% of it, timed against AWS rather than against Terraform) is propagating `Enabled=false` to every edge, and the `DeleteDistribution` call itself is ~3s (`docs/TEARDOWN.md` §3.1). |
| One full `prod` cycle: `init` + `plan` + `apply` + verify + `destroy` | **8m50s** | 2026-09-01, 22:08:40Z → 22:17:30Z, 23 resources, us-east-2 — **single run**, see below. |
| Post-destroy sweep (`docs/TEARDOWN.md` §6) | **not timed** | Eleven read-only AWS CLI checks. |
| Bootstrap teardown (`docs/TEARDOWN.md` §8) | **never walked end to end** | See below. |

**Two of those figures are marked *single run* because that is all they are.** The 3m14s
distribution create and the 8m50s `prod` cycle were each measured once, on 2026-09-01, while this
README was being written; neither was cross-checked against a second run, and neither is recorded
in any artefact in this repository. The 2026-08-27 numbers are a different class of thing: six
timed operations across three distributions, with their method and their limits written down in
`docs/TEARDOWN.md` §3. They describe the 17-resource shape the environment had that day; the
module has gained resources since — the viewer-request function among them — which is why those
rows count 17 and the `prod` cycle above counts 23. The distribution is the clock in both.

**The from-zero path has not been walked in one pass.** Empty account → fresh clone → bootstrap →
apply → verify → destroy → *bootstrap teardown* → empty account again is the one goal in this
repository's operating model that nothing in CI asserts, because `e2e.yml` runs against an
account that is already bootstrapped. The environment half of it has been measured repeatedly and
the figures above are real; the bootstrap and its teardown have not been timed, and the two-phase
`prevent_destroy` removal in particular is a documented procedure that has been reasoned about
and never executed. This line stays here, undated, until someone walks it and dates it. An
undated quickstart is a claim rather than a measurement, and saying so is cheaper than being
found out.

### What one cycle costs

**Cents, and most plausibly less than one.** Derived from the resource set and public AWS pricing
rather than from a bill, and it assumes what this operating model actually does: an environment
that exists for minutes, verification traffic measured in dozens of requests, no custom domain,
and a placeholder `index.html` of a few hundred bytes.

| Line item | Why it rounds to nothing here |
|---|---|
| CloudFront distribution | No hourly or per-distribution charge. Billing is per request and per GB out; the free tier alone covers 1 TB and 10M requests a month. A verification run is dozens of requests. |
| CloudFront Function | One invocation per viewer request, against a free tier of 2M invocations a month — a verification run of dozens of requests never reaches the $0.10-per-million rate at all. |
| S3 (site bucket) | A few hundred bytes for a few minutes, plus a handful of PUT/GET calls. |
| S3 (state bucket) | State objects are kilobytes, and this one *outlives* the cycle — it is the only standing cost, and it is still kilobytes. |
| CloudWatch Logs (vended, us-east-1) | Charged on ingestion per GB plus storage per GB-month, both against access-log volume for a distribution that served dozens of requests. Retention defaults to 30 days, but the log group is destroyed with the environment. |
| SSM Parameter Store | Standard parameters are not charged. |
| IAM roles and policies | Not charged. |
| ACM certificate | Not created on the default path; public certificates are free in any case. |

The honest summary is that a full cycle is too small to see on a bill, and the reason to destroy
promptly is **not** money. Leaving an environment standing costs approximately nothing per hour —
what it costs is the two 20-per-account CloudFront policy quotas, which is a failure that arrives
later and elsewhere. If you want a real figure for a change rather than an estimate for a cycle,
the per-line-item numbers above are the shape to reason from; nothing in this repository measures
its own bill.

---

## Working on it

```bash
make help          # every target, with what it does
make fmt-check validate lint scan docs-check test audit
```

That line covers six of `validate.yml`'s nine jobs — `terraform`, `tflint`, `trivy`,
`terraform-docs`, `terraform-test` and `zizmor` — invoked identically, so for those a local run
and a green check really are the same command, and each Makefile target pins the tool version it
needs and refuses to run on a different one rather than producing a diff nobody asked for.

**Two required checks have no Makefile target, and cannot honestly be given one.** `actionlint`
runs a pinned Docker image rather than a binary on `$PATH`, and `pr-title` greps a title that
exists only in the pull request event payload, which no local command can read. So editing a
workflow, running the line above and pushing can still produce a red required check: that is the
one place the "same command" property does not reach, and it is worth knowing before it happens
rather than after.

No job in `validate.yml` needs an AWS account, a role or a state bucket, which is what lets eight
of its nine be required status checks. The ninth, `audit-online`, needs a GitHub token and reports
on an advisory database rather than on this tree, so it can go red on a Tuesday without this
repository having changed — which is why it runs and is deliberately not required.

`make docs` regenerates the inputs and outputs tables inside `modules/static-site/README.md`,
between its `BEGIN_TF_DOCS`/`END_TF_DOCS` markers. **This file is not generated and carries no
markers** — terraform-docs is pointed only at directories under `modules/`.

Applying and destroying in CI is `apply.yml`, dispatched by hand with an environment and an
action (`apply` or `destroy`). Nothing deploys on merge: a merge trigger would leave a CloudFront
distribution running for every pull request that touched a comment. The workflow plans to an
artefact in one job and applies *that artefact* in a second, so on `prod` the required reviewer
approves a plan that already exists rather than authorising one that has not been computed yet.

---

## Tradeoffs

Specific ones, with what each buys and what it would cost to choose differently.

- **`stage` and `prod` share one AWS account, isolated by naming rather than by account
  boundary.** Nearly every resource is named `<name_prefix>-site-<env>-…`, each environment keeps
  state under its own `<env>/terraform.tfstate` key, and each has its own apply role, trusted on
  its own `environment:<env>` OIDC subject and granted nothing on the other's state. That is real
  isolation of the identity and the state, and it is not a blast-radius boundary: the
  account-wide CloudFront grants above are shared between them, and the two CloudFront policy
  quotas are per account, so two environments hold 4 of 20 in each. Separate accounts are the
  correct answer for anything durable, and are a different project.

  **"Nearly" is load-bearing: a cleanup sweep written from the pattern alone would miss five of
  the twenty-three outright and stumble on a sixth.** The three SSM parameters are
  `/static-site/<env>/<key>`, carrying no `name_prefix` at all — a consumer that had to know the
  bucket's random suffix to find the parameter holding the suffix would be back where it started.
  The app deploy role is `react-cloudfront-app-deploy-<env>`, deliberately outside the convention
  because the bootstrap scopes both apply roles to `role/react-cloudfront-app-deploy-*` and
  following the convention would fail at `CreateRole` — `modules/static-site/iam.tf` says so at
  the line. Its inline policy is named just `deploy`. And the sixth: the log group carries the
  pattern only as a suffix, under `/aws/vendedlogs/cloudfront/`, which is why `docs/TEARDOWN.md`
  §6 queries it by the full path rather than by a bare prefix glob.

- **`force_destroy = true` on prod, because *this* prod is ephemeral.** The module defaults it to
  `false` and refuses to default it to `true`, for good reason: `true` turns "destroy declined to
  remove a bucket holding data" — a safe, loud, recoverable failure — into silent deletion of
  every object. It is set in each environment root, where a reviewer reads it, because it is a
  property of this operating model rather than of the module. A durable prod would leave it
  `false`, enable bucket versioning, and empty the bucket through a documented runbook step
  instead. The cost of getting that
  backwards here is concrete: the bucket is destroyed *after* the distribution, so a
  `BucketNotEmpty` would arrive only after the full three-minute distribution wait had been spent,
  on every retry, until someone emptied it by hand.

- **The apply roles' branch restriction lives in each GitHub Environment's deployment branch
  policy, not in IAM.** Naming an environment *replaces* the ref component of the OIDC subject
  with `environment:<name>` rather than adding to it — measured on real tokens, not read from
  documentation — so there is no ref left for a trust policy to condition on. IAM holds "which
  environment", GitHub holds "which branch". A job that forgets to declare an environment cannot
  assume an *apply* role at all — each one trusts the `environment:<env>` subject and nothing else
  — which is what makes the prod reviewer gate real rather than decorative. The plan role is the
  deliberate other half: `plan.yml`'s plan job declares no environment on purpose, because that
  role is trusted on the bare `:pull_request` subject and an `environment:` there would break
  every run in the workflow.

- **No review is required on `main` — neither code-owner enforcement nor a plain approving
  review.** A single maintainer cannot approve their own pull request, so a required approval
  would mean bypassing the ruleset on every commit, and a rule bypassed on every use is an off
  switch with extra steps. What actually gates merges is the nine required status checks and push
  protection. `docs/BOOTSTRAP.md` section 7.2 carries the stricter `pull_request` parameters as a
  standalone JSON block beside the ruleset payload rather than as comments inside it — JSON has no
  comment syntax, and a payload you cannot paste is not a runbook step — ready for the day a
  second maintainer exists.

- **`prod` is verified by hand and is deliberately outside the weekly end-to-end run.** Its
  required-reviewer gate is incompatible with an unattended 04:17 Monday run, which would sit
  waiting for an approval nobody is awake to give. `e2e.yml` therefore exercises `stage` only, and
  takes no environment input at all so that the exclusion cannot be argued away one dispatch at a
  time.

- **This repository provisions S3 and CloudFront only.** The VPC/ALB/EC2 architecture the original
  prototype demonstrated lives in its own repository rather than as a `sandbox` environment here.
  An environment exists to be applied; one kept only to justify inherited code is dead code with a
  directory name.

- **The custom-domain path is plan-verified only and has never been applied, in CI or by hand.**
  `certificate.tf` and the ACM grants in `bootstrap/oidc.tf` are the least exercised code in the
  repository, and the module's README says so at the point a reader would use them. It is kept
  rather than deleted because a module that cannot take a domain is not a reference for anything
  — but it is labelled, because the alternative is a path that reads as tested and is not.

- **The site bucket has no lifecycle rule expiring old hashed assets, and no versioning.** Nothing
  here lives long enough to accumulate either a bill or a rollback need: rollback is redeploying
  the app repository's build artefact by run id, which restores a whole coherent build rather than
  one object of it. Versioning would also add a second class of thing to empty before a bucket can
  be destroyed, which is exactly the corner where a `force_destroy` teardown quietly fails. A
  durable deployment wants both, and would document the emptying step to match.

- **Terraform CLI (BSL 1.1) rather than OpenTofu (MPL 2.0).** The BSL restricts offering a
  competing hosted Terraform service, which is not the use this repository makes of it. Native S3
  state locking and everything else here exists in both, so this choice would flip on a consumer
  needing an OSI-approved licence and on nothing else.

`docs/BOOTSTRAP.md` and `docs/TEARDOWN.md` each close with a "what a cloner needs to know"
section, and `docs/DEPLOY_CONTRACT.md` with "what the app repository has to get right". Between
them they carry the rest — the traps that are specific enough to belong beside a procedure rather
than in a list here.

---

## Licence

Apache-2.0. See [`LICENSE`](LICENSE).

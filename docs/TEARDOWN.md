# Teardown runbook

Destroy is a feature here, not an afterthought. Nothing in this repository stays deployed:
every environment is applied, verified and destroyed inside an hour, and anything that blocks
or survives `terraform destroy` is treated as a defect. That claim is only worth making if it
can be checked, which is what this document is for — the order things come down in, how long
the slow part actually takes, what to do when a destroy is interrupted, and how to prove
afterwards that nothing was left behind.

It is written for a stranger with an empty AWS account, and it assumes `docs/BOOTSTRAP.md` has
already been followed. Follow it top to bottom.

> **This procedure was walked end to end on 2026-08-27, against a real AWS account.** Both
> environments were applied from zero (17 resources each), verified against live HTTP responses,
> and destroyed; one of those destroys was killed mid-flight and recovered, which is why
> section 5 exists in the shape it does. **Every duration below is a wall-clock measurement from
> that day, not a figure quoted from somewhere else** — and section 3 records what happened to
> the figure this repository used to quote. Where something was never exercised, it says so
> rather than reading as though it was.
>
> Measured on Terraform 1.15.9 and AWS provider 6.61.0, with the environments in one region and
> the us-east-1 resources CloudFront forces, in a single AWS account, on a single day.

## Why there are no values in this runbook

The same reason `docs/BOOTSTRAP.md` gives: bucket names carry a `random_id` suffix that is
re-minted on every cycle, distribution ids and account ids differ for every cloner, and this
file is committed to a public repository. Placeholders — `<env>`, `<name_prefix>`, `<lock-id>`,
`<distribution-id>` — are yours to substitute, and the transcripts below are redacted the same
way. The commands that print the real values are named where they are needed.

---

## 1. Destroy order

Three layers, and they come down in this order:

| # | Layer | Why it is here |
|---|---|---|
| 1 | **Every environment** — `envs/stage`, `envs/prod` | They hold everything that costs money and everything that can be orphaned |
| 2 | **Anything the app repository owns** | It must not be re-creating what step 1 just removed, and from build-plan commits 27–28 it holds identities and parameters pointing at the environment |
| 3 | **The bootstrap** — state bucket and OIDC provider | It is the only thing that knows how to remove the other two |

**The environments are independent of each other.** Stage and prod have separate state keys and
were confirmed on 2026-08-27 to have distinct Terraform state lineages, so destroying one has no
effect on the other and the order between them does not matter. Destroy them in either order, or
at the same time.

**Layer 2 is almost empty at this commit, and it is stated anyway.** The `static-site` module
creates no artefacts owned by the app repository yet — that arrives with the SSM parameters and
the scoped deploy role in build-plan commits 27 and 28, and both are module resources that will
be destroyed with the environment that holds them. What already crosses the repository boundary
today is the content the app deploys into the site bucket, and that is handled by
`force_destroy = true`: an object Terraform did not manage was planted deliberately during
verification and was removed by the destroy on both runs it was tried on. The rule that outlives
the detail is the one to remember: **nothing outside this repository may hold a reference to an
environment that outlives the environment.** Before destroying an environment, stop whatever
deploys into it.

**Layer 3 is last for a reason that is easy to get backwards.** Emptying the state bucket while
an environment still stands strands that environment's infrastructure with nothing left that
knows how to remove it — a CloudFront distribution whose id nobody has written down is the
orphan nothing in this repository can find. Section 8 repeats this warning at the point it
matters.

## 2. Destroying an environment

```bash
terraform -chdir=envs/<env> init -input=false -backend-config=backend.hcl
terraform -chdir=envs/<env> destroy
```

`-reconfigure` is **not** needed, and reaching for it is a mistake worth naming. It is the flag
for discarding a recorded backend association, and there is none to discard: `make validate`
writes no backend record, and since it began removing any it finds — so that the checks stay
runnable without AWS credentials — there is usually none left to discard either. Both
environments were initialised against the S3 backend on 2026-08-27 with the line above and
neither prompted.

That is also why the `init` line is not a first-time-only step. Any `make validate`, and so any
commit touching a `.tf` file with the pre-commit hook installed, leaves these roots
uninitialised; the next direct `terraform` command in one stops with `Error: Backend
initialization required` before it reaches AWS. Every snippet below that drives terraform at an
environment root therefore carries the line, and the `make` targets run it themselves on every
invocation.

### 2.1 `make destroy-<env>` cannot run unattended, by design

The Makefile has `destroy-stage` and `destroy-prod`, and they are the right thing for a human at
a terminal. They pass neither `-auto-approve` nor `-input=false` to the verb, deliberately: the
interactive confirmation is the only thing standing between a mistyped target and a real
environment. That makes them unusable from a script, a CI job or any process with no terminal
attached. For the unattended case use the direct form and accept that you have removed the
guard:

```bash
terraform -chdir=envs/<env> init -input=false -backend-config=backend.hcl
terraform -chdir=envs/<env> destroy -auto-approve -input=false
```

The applies and destroys measured on 2026-08-27 ran with `-auto-approve` rather than through the
`make` targets.

### 2.2 Run it where it will not be killed

One of the three destroys measured was killed about 90 seconds in by something outside Terraform
that was never identified. It had been started as a detached background task, which is the
exposure; the cause is recorded as unknown rather than guessed at. It cost a stranded state lock
and a recovery — section 5 — and it is the only failure this step produced. A destroy is about
three minutes of a process doing nothing but polling; run it somewhere a hangup, a closed laptop
or a job timeout cannot reach it, and prefer the foreground.

### 2.3 Credentials have to outlive the run

A session expiring mid-destroy is the same event as the kill above: a half-removed distribution
and a lock nobody holds. Re-assume the role immediately before each destroy rather than relying
on a session assumed some time earlier.

One measured constraint that surprises people, because it contradicts the role's own
configuration: **a role assumed from another session — an MFA `sts:GetSessionToken` session, for
example — is capped by AWS at 60 minutes regardless of the role's `max_session_duration`.**
Asking for more returns `ValidationError: The requested DurationSeconds exceeds the 1 hour
session limit for roles assumed by role chaining`, even when the source is an IAM user session
rather than another role. A two-hour ceiling on the role does not give a local operator two
hours. Sixty minutes is ample for a destroy that takes three; the point is to know which number
is real before planning a long sequence around the other one.

## 3. How long it takes — measured, and the figure this corrects

**The 15–20 minute CloudFront teardown figure this repository used to quote is wrong.** It was
asserted as "an AWS-side limit" in the build plan, and from there in two committed files —
`bootstrap/oidc.tf`, where it justified the apply role's session ceiling, and
`envs/prod/main.tf`, where it sized the cost of a `BucketNotEmpty`. It was never measured. It is
wrong by roughly a factor of five, and it is wrong about *what* is being measured. Both comments
are corrected in the commit that adds this file. Six timed distribution operations — three
creates and three destroys, across three distributions — on 2026-08-27:

| Event | Environment | Wall clock |
|---|---|---|
| create | stage (partial, 15 resources) | **3m01s** |
| destroy | stage (partial, 15 resources) | **3m10s** |
| create | stage (complete, 17 resources) | **2m43s** |
| destroy | stage — killed at 1m30s, then retried | **3m35s** end to end |
| create | prod (complete, 17 resources) | **2m43s** |
| destroy | prod (complete, 17 resources) | **2m48s** |

**A CloudFront distribution takes about three minutes to create and about three minutes to
destroy.** The whole 17-resource environment destroys in **3m01s** and applies in **2m53s** /
**2m54s**, because everything that is not the distribution costs seconds.

Two things that might have been expected to make teardown slower do not. A complete environment
with the log-delivery chain fully attached tore down **faster** (2m48s) than a partial one with
no delivery source (3m10s), so the delivery chain costs nothing. And the distribution that had
served real viewer traffic through a full verification run was the fastest of the three, so
neither age nor edge state shows any effect.

### 3.1 Where the three minutes actually goes

Terraform deletes a distribution in three steps: `UpdateDistribution(Enabled=false)`, then poll
until `Status` reaches `Deployed`, then `DeleteDistribution`. For prod's teardown the
distribution was polled every two seconds from an independent process, so the AWS-side state
machine was observed while Terraform ran:

```
TERRAFORM                                   CLOUDFRONT (independent 2s polling)
19:19:09  Destroying... <distribution-id>
                                            19:19:33  Status=InProgress  Enabled=False
                                            19:21:41  Status=Deployed    Enabled=False
                                            19:21:44  NoSuchDistribution
19:21:58  Destruction complete after 2m48s
19:22:00  Destroy complete! 17 destroyed
```

| Phase | Duration | Share |
|---|---|---|
| Disable propagation — `Enabled=false` until `Status: Deployed` | **2m32s** | **~98%** |
| Delete — `DeleteDistribution` until the distribution is gone | **~3s** | ~2% |

Three things follow, and none of them survive the old figure:

- **The delete call is essentially instantaneous.** Charging "disable + delete" with 15–20
  minutes attributes to the delete a cost that belongs entirely to the disable.
- **`Status` reaches `Deployed` before the delete is issued.** This is one propagation followed
  by a near-instant delete, not two propagations in series. That is what makes three minutes
  both the floor and the ceiling: there is no second wait hiding behind the first.
- **Terraform's own number overstates the AWS event by about 14 seconds** — its poll interval.
  AWS showed the distribution gone at 19:21:44; Terraform reported `2m48s` and noticed at
  19:21:58. Immaterial at this scale, and worth knowing before anyone tunes a timeout against
  Terraform's figure and thinks they are measuring AWS.

> **The rule.** A CloudFront distribution takes about three minutes to tear down, and
> essentially all of it is AWS propagating `Enabled=false` to every edge. That propagation clock
> runs whether or not Terraform is watching it.

### 3.2 What the figure is, and is not, evidence of

All of it is one account, one day, one region pair, one provider version and one Terraform
version. It is a measurement, not a service level. Anyone re-measuring should date their number
the way this section dates its own — the failure being corrected here is not that 15–20 minutes
went stale, it is that nobody could tell, because it arrived without a date or a method
attached.

## 4. What comes down, and in what order

Read off the timestamped log of the complete 17-resource prod destroy, not off the graph:

| Wave | Elapsed | Resources |
|---|---|---|
| **1 — everything the distribution does not hold** | **≤2s** | the log delivery, then the delivery source and destination, then the log group; the placeholder object, the bucket policy, ownership controls, encryption configuration, public access block |
| **2 — the distribution** | **2m48s** | the CloudFront distribution |
| **3 — everything the distribution held** | **≤2s** | the origin access control, both cache policies, both response headers policies, the bucket, and the `random_id` that named it |

**The distribution is about 93% of the wall clock; all sixteen other resources together are
about four seconds.** If a destroy is taking materially longer than three minutes, it is not the
resource count.

Three ordering facts are load-bearing rather than trivia:

- **The bucket policy is destroyed before the distribution and the bucket after it.** The policy
  names the distribution's ARN and the distribution names the bucket's regional domain, so
  Terraform can only sequence them this way. The consequence is the one `envs/prod/main.tf`
  argues about at length: with `force_destroy = false`, a `BucketNotEmpty` failure would arrive
  only *after* the entire three-minute distribution wait had been spent, on every subsequent
  attempt, until someone emptied the bucket by hand. The argument is now confirmed as
  structurally correct — the bucket genuinely is last.
- **The log-delivery chain unwinds first and in dependency order**, all inside one second. The
  chain that could not be *created* without a CloudFront-side permission grant is trivial to
  *destroy*.
- **The four quota-bearing policies and the origin access control are reclaimed in wave 3**,
  after the distribution releases them. They are the resources no tag-based assertion can see
  (section 6.2), so this is the moment that matters for the 20-per-account quota. It completed in
  under two seconds on all three destroys.

## 5. When a destroy is interrupted

This happened for real on 2026-08-27, unplanned: a `terraform destroy` of a fully applied
environment was killed about 90 seconds into the distribution deletion, with 9 of 17 resources
gone. The cause was not a Terraform error and not a timeout — the process was killed from
outside and no Terraform process survived. It is recorded as unknown rather than guessed at.
Session expiry was ruled out on two independent grounds: the destroy began 12 minutes into a
60-minute session, and an expired session leaves an `ExpiredToken` API error in the log, while
this log's last line is an ordinary progress line with no error of any kind.

### 5.1 What an interruption costs: nothing, and it saves nothing

```
19:01:31  Destroying...            (disable issued)
19:03:01  Still destroying... 01m30s elapsed   <-- last line before the kill
   ~1m48s with no terraform process running at all
19:04:49  Destroying...            (retry; distribution found Enabled=false, Status=InProgress)
19:05:06  Destruction complete after 16s
```

End to end that is **3m35s**, against 3m10s and 2m48s for the two destroys that ran
uninterrupted. Propagation continued for 1m48s while no Terraform process existed, which is the
direct evidence for section 3.1's rule.

**The retry is not cheap because retrying is cheap.** It is cheap because most of the
propagation had already elapsed unattended. Re-running `destroy` immediately after an
interruption still waits out whatever remains — waiting a couple of minutes first makes the
re-run near-instant, re-running at once simply resumes the wait. Neither is wrong; expecting the
16 seconds without the 1m48s is.

### 5.2 The stranded lock, and the one thing that will mislead you

The environments use native S3 locking, which writes `<key>.tflock` beside the state object and
deletes it when the run finishes. A killed process leaves it behind, and every subsequent run on
that environment blocks on it. Read it rather than assuming who owns it — and **confirm no run
is actually in flight first**, because a `force-unlock` against a live apply is how two processes
end up writing the same state:

```bash
BUCKET="$(terraform -chdir=bootstrap output -raw state_bucket_name)"

aws s3api get-object --bucket "$BUCKET" \
  --key "<env>/terraform.tfstate.tflock" /dev/stdout
```

The object from the incident, verbatim apart from the identifiers:

```json
{ "ID": "<lock-id>",
  "Operation": "OperationTypeApply",
  "Who": "<user>@<host>",
  "Version": "1.15.9",
  "Created": "2026-08-27T19:01:23Z",
  "Path": "<bucket>/<env>/terraform.tfstate" }
```

Two things in there are traps.

**`Operation` reads `OperationTypeApply` for a destroy.** A destroy is an apply of a destroy
plan, so that is the name Terraform records. Anyone diagnosing a stuck teardown by matching on
the operation looks straight past the lock that is blocking them. The field tells you a run was
in progress; it does not tell you which direction it was going.

**The state file was never written back.** After the kill, the state object still carried its
apply timestamp and still claimed 17 resources while 9 were already gone. **A state file is not a
record of what happened** — it is reconciled by the refresh at the start of the next run. Anyone
reading state to work out what a killed run destroyed will be misled about exactly the resources
they are trying to account for. The distribution itself was left `Enabled: false,
Status: InProgress`: the disable had propagated, the delete had not.

### 5.3 The recovery, which is three commands

```bash
terraform -chdir=envs/<env> init -input=false -backend-config=backend.hcl
terraform -chdir=envs/<env> force-unlock <lock-id>
terraform -chdir=envs/<env> destroy
```

Terraform prints the lock id in the error that sent you here, and it matches the `ID` in the
object above. The `init` is the ordinary one from section 2, not a recovery step: `force-unlock`
reaches the lock through the backend, so an uninitialised root fails on the backend before it
ever looks at the lock. Past it the re-run takes **no special flags** — no `-refresh=false`, no
`state rm`, no manual surgery. On 2026-08-27 the refresh reconciled the stale state, found the
9 remaining resources, and removed them; the whole recovery run took **26 seconds**, of which
16 were the remainder of the distribution's propagation.

No orphan was left by either pass. The post-destroy sweep in section 6 was run against this
two-pass teardown precisely because a killed process and a `force-unlock` are when things get
left behind, and it came back identical to the sweep after the clean run.

## 6. The post-destroy checklist

A destroy exiting 0 is a claim, not evidence. Terraform reports on what was in its state file,
and the resources most worth worrying about are the ones that leave state without leaving AWS.
Run these after the last environment is destroyed and before tearing down the bootstrap.

The "Found" column is what this checklist returned on 2026-08-27, run twice — after the two-pass
teardown across a `force-unlock`, and after the clean prod destroy. **Identical both times.**

| # | Check | Why it is on the list | Found |
|---|---|---|---|
| 1 | CloudFront distributions matching the module | The orphan nothing can find once its state is gone | **none** |
| 2 | Custom **cache policies** | Quota **20 per account**, account-wide; the module creates 2 per environment | **0** |
| 3 | Custom **response headers policies** | Quota **20 per account**, account-wide; 2 per environment; invisible to any tag query | **0** |
| 4 | **Origin access controls** | Quota 100 per account; the name carries the bucket's random suffix, so a leak is invisible to a name-stable check *and* to tags | **none** |
| 5 | Log groups under `/aws/vendedlogs/cloudfront/<name_prefix>-site-*`, **in us-east-1** | Accrues cost after the environment is gone; retention bounds it, it does not remove it | **none** |
| 6 | Delivery **sources**, **destinations** and **deliveries**, us-east-1 | Four resources that are permanently in us-east-1 whatever region the environment uses | **`[]` / `[]` / `[]`** |
| 7 | ACM certificates in us-east-1 left `PENDING_VALIDATION`, and the validation record in your hosted zone | Section 7 — reachable only on the custom-domain path, which nothing here has applied | **none from this repository** |
| 8 | Site buckets, by name | — | **404 on all three** |
| 9 | Tag inventory for `Project` and `Env`, **in both regions** | The assertion the end-to-end workflow will make | **empty, all four queries** |
| 10 | A stranded `.tflock` in the state bucket | Section 5.2 | **none** |

Every distribution this step created was confirmed individually as `NoSuchDistribution` rather
than inferred from an exit code. That is the standard the checklist is written to: **checked and
clean**, not "no known issues".

### 6.1 The two commands the checklist cannot be written without

```bash
aws cloudfront list-cache-policies            --type custom \
  --query 'length(CachePolicyList.Items || `[]`)' --output text
aws cloudfront list-response-headers-policies --type custom \
  --query 'length(ResponseHeadersPolicyList.Items || `[]`)' --output text
```

Both must read `0` on an account whose environments are all destroyed. This is the only
automatic detector for the tightest quota in the repository: 20 custom policies of each type per
account, account-wide rather than per distribution, and this module creates two of each per
environment — `<name_prefix>-site-<env>-default-*` and `<name_prefix>-site-<env>-assets-*`. Two
environments therefore hold 4 of 20 in each quota at any time. A handful of leaked destroys
reaches the ceiling, and the failure then surfaces at **apply** time on an unrelated environment,
as a quota error naming nothing about the leak that caused it. The policy names are stable and
carry the environment for exactly this reason: a leak that survives becomes a loud name collision
on the next apply of that environment rather than silent accumulation.

`--type custom` is not optional. Without it the call returns AWS's managed policies as well and
the count is never zero.

### 6.2 What a tag-based assertion can and cannot see

Tags are the obvious way to assert a clean teardown, and on this module they cover **6 of 17
resources**. Measured, per environment:

| Query | Resources returned |
|---|---|
| Tag inventory in the environment's own region | **1** — the S3 bucket |
| Tag inventory in us-east-1 | **5** — the distribution, the log group, the delivery source, the delivery destination, the delivery |

Two consequences, both of which the module's own comments predicted and this measurement
confirms:

- **A single-region tag query reports success over surviving resources.** Querying only the
  environment's region returns one resource; five live us-east-1 resources are outside it,
  because CloudFront's logging API must be called in us-east-1 whatever region the environment
  uses. Any teardown assertion has to query both regions.
- **The four quota-bearing policies and the origin access control are invisible in both
  regions.** `aws_cloudfront_cache_policy`, `aws_cloudfront_response_headers_policy` and
  `aws_cloudfront_origin_access_control` expose no tags — the CloudFront API has nowhere to put
  them — and the resource groups tagging API returns only taggable resources. This is not
  fixable by tagging harder. It is why section 6.1 exists.

### 6.3 The account may not be only yours

`aws cloudfront list-distributions` returns everything in the account, and on the account this
was measured in it returned one distribution belonging to an unrelated project. **Match against
the module's naming before deleting anything by hand.** The same caution applies in the other
direction and is worth stating plainly: the CI apply role's CloudFront grants cannot be scoped
by resource, because CloudFront's create operations accept no resource-level conditions, so in a
shared account that role can update and delete distributions this repository did not create. In
an account that hosts anything else, treat a hand-run destroy with a `-target` as the highest-risk
command in this document.

### 6.4 One thing this checklist cannot tell you

No identity in this repository can read log **contents**: `logs:DescribeLogStreams` and
`logs:GetLogEvents` are deliberately absent from the apply role, and that denial was confirmed
directly on 2026-08-27. It is correct least-privilege behaviour and it has a consequence worth
knowing before you destroy an environment — you can confirm the log group, the delivery source,
the destination and the delivery all exist and are wired to the right distribution, and you
cannot confirm that any log line ever arrived in it. Delivery lag is minutes and the environment
lives for about an hour, so a destroy routinely removes a log group whose arrival was never
proven.

## 7. The custom-domain path, which was never exercised

Everything above was measured against environments using the default CloudFront certificate.
**Neither `envs/stage` nor `envs/prod` creates an ACM certificate**, so nothing in the module's
`certificate.tf` was exercised by any of it. Three teardowns produced no `ResourceInUseException`,
no ACM lag and no retry of any kind. That is not evidence that ACM behaves; it is evidence that
ACM was never asked to.

The advice below therefore applies **only** if you supplied `domain_name`, and it is carried
because it is cheap to carry and expensive to rediscover — not because it has been seen here:

- **A certificate deletion can fail with `ResourceInUseException` after its distribution is
  already gone.** The CloudFront association lingers cross-service for a while after the
  distribution disappears. The AWS provider retries, and when it gives up, **re-running
  `terraform destroy` is the fix** — by then the association has expired and the delete
  succeeds. Nothing needs removing from state.
- **This module creates no Route 53 hosted zone.** `hosted_zone_id` is an input: you bring the
  zone, and this module writes exactly one validation record into it, which is destroyed with the
  environment. The orphan to check for on this path is that record and a certificate left in
  `PENDING_VALIDATION`, not a zone. A hosted zone this repository did not create is not this
  repository's to delete.

Kept rather than dropped, and marked unverified rather than presented as routine. Presenting an
inherited assertion as a thing that happens on the paths this repository actually runs is the
same category of error as the 15–20 minute figure in section 3.

## 8. Tearing down the bootstrap

The state bucket and the OIDC provider are the only things in this design that outlive a cycle.
This repository treats anything that survives a destroy as a defect; the bootstrap is the honest
exception, and an exception is only honest if its removal path is written down.

**Destroy every environment and run section 6's sweep before touching anything here.** Emptying
the state bucket while an environment still stands strands its infrastructure with nothing left
that knows how to remove it. There is no undo for this and no automated detector for it
afterwards.

**Phase 1 — empty the bucket.** A versioned bucket refuses to delete while any version or delete
marker remains, and `aws s3 rm --recursive` removes neither. Note that the state objects persist
after a destroy: they are emptied, not deleted, so the bucket is never empty just because every
environment is gone.

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

**Phase 2 — remove the guard, destroy, put the guard back.** `bootstrap/state.tf` carries
`lifecycle { prevent_destroy = true }` on the bucket. `lifecycle` meta-arguments accept no
variables and no expressions, so this cannot be a flag, a `-var` or an environment switch. It is
a hand edit, in the working tree, reverted immediately afterwards. The literal edit is one line:

```diff
   lifecycle {
-    prevent_destroy = true
   }
```

Delete the line and leave the block; an empty `lifecycle` block is valid and `terraform validate`
accepts it, so there is nothing else to tidy and nothing else to put back. Then, in this order
and with nothing staged in between:

```bash
terraform -chdir=bootstrap destroy
git checkout -- bootstrap/state.tf
```

**That edit is never committed, and `git checkout -- bootstrap/state.tf` is the last line of the
procedure.** A repository whose history contains "remove the state bucket's guard" is a
repository where a revert, a cherry-pick or a copy-paste removes it again on a day nobody
intended to. The friction is the guard: it is what stops an accidental `destroy` from taking the
state with it. Run `git status` afterwards and confirm the working tree is clean.

The bootstrap runs on local state, so `bootstrap/terraform.tfstate` is what this destroy reads.
If it is missing, the bucket, the provider and every role have to be adopted back in one
`terraform import` at a time first — the plan role plus one apply role per name in
`environments`, which is three at the two environments this repository ships and grows with the
list, not the two the older shape had. `docs/BOOTSTRAP.md` section 4 explains why that file is
worth keeping.

If you imported a pre-existing OIDC provider rather than creating one — `docs/BOOTSTRAP.md`
section 3 — remove it from state before the destroy so it survives:

```bash
terraform -chdir=bootstrap state rm aws_iam_openid_connect_provider.github
```

An account holds exactly one provider per issuer URL, so destroying one you did not create takes
GitHub OIDC away from everything else in the account that uses it.

## 9. Things that look like failures and are not

**The state object is still there after a destroy.** `<env>/terraform.tfstate` persists and
reports `resources: 0`; it is emptied, not deleted. Nothing is left behind in AWS, and the next
apply is a genuine from-zero create.

**The next apply produces a different bucket name.** The bucket's `random_id` is destroyed with
the environment and re-minted on the next apply, so every cycle gets a new suffix. Nothing
downstream may cache the old name — which is why `docs/BOOTSTRAP.md` records commands rather than
values.

**`make validate` prints `InvalidClientTokenId` after a real `init`.** Once an environment has
been initialised against the S3 backend, `make validate` — which runs `init -backend=false` —
prints that error once per environment and then reports `Success!` and exits 0. It is an
artefact of having initialised the same working directory both ways; CI never sees it, because
CI starts from a fresh checkout with no `.terraform/`. Nothing to chase.

**The destroy log's elapsed time is a little longer than AWS's.** Section 3.1: about 14 seconds
of Terraform's figure is its own poll interval.

---

## What a cloner needs to know

**Three minutes, not fifteen.** A CloudFront teardown is about three minutes, essentially all of
it AWS propagating `Enabled=false` to the edges, and the delete itself is about three seconds.
That number was measured on 2026-08-27 across three distributions, and it is dated for the same
reason the figure it replaces should have been: so the next person can tell a stale number from
a wrong one.

**An exit code is not evidence.** Run section 6, both regions, and run section 6.1 in
particular — the two quota-bearing policy types are invisible to every tag-based assertion in
this repository and are the tightest limit in it.

**An interrupted destroy is recoverable and costs nothing.** `force-unlock` with the id from the
error, then re-run `destroy` with no special flags. Do not read the state file to work out what
the killed run removed, and do not expect `Operation` in the lock object to say `Destroy` — it
says `OperationTypeApply`.

**The guard edit is never committed.** `git checkout -- bootstrap/state.tf` is the last line of
the bootstrap teardown, and `git status` afterwards is how you know it ran.

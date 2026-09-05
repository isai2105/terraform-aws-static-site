# Deployment contract

This repository builds the infrastructure a single-page application is served from. It does not
build the application, and it never uploads one. A second repository —
`react-cloudfront-app` — does that, from its own pipeline, with an identity this repository
creates for it.

This document is the whole of the interface between the two. It is written so that someone
building that pipeline needs no other source: every identity, every name, every command and
every constraint the app repository has to honour is here, with the reason it is what it is and
the failure it prevents. Where a rule exists only because of something in this repository the
other one cannot see, that is said explicitly rather than left as a rule to obey.

The direction of authority matters. Everything below is **this repository's** to change and the
app repository's to satisfy. Nothing in the app repository can widen a permission, relax a
header or rename a role; when one of those has to change, the change lands here first, or in the
same window, and section 6 and section 7 explain what that costs.

---

## Why there are no account values in this document

`docs/BOOTSTRAP.md` and `docs/TEARDOWN.md` both open with a version of this paragraph and the
reasons are the same three: a cloner's account id, bucket name and role ARNs differ from anyone
else's in every character that matters; the values this repository produces are re-minted on
every teardown cycle, so a recorded literal is stale within the hour; and this file is committed
to a public repository, where a pasted account id is the likeliest leak in the whole project.

Placeholders are written in `<angle brackets>` — `<account_id>`, `<env>`, `<bucket>` — and every
one of them is yours to substitute.

That leaves a tension worth resolving out loud, because a deploy pipeline cannot run on
placeholders. The answer is that the app repository does not read its values from this document
at all:

- the three values that change every cycle — bucket name, distribution id, site URL — are read
  from SSM **at deploy time**, by the names in section 2. This is the whole reason those
  parameters exist;
- the values that are stable for a deployment — the account id, the region — are set once as
  GitHub variables in the app repository, from `bootstrap/outputs.tf` and
  `envs/<env>/terraform.tfvars`, and are read from there rather than from prose.

Two classes of value **are** written out concretely below, and both are deliberate. The numeric
GitHub owner and repository ids in the trust subject (section 1.3) and the boundary policy name
(section 7) are already committed, in `bootstrap/terraform.tfvars` and
`envs/*/terraform.tfvars`, for the reason that file gives: nothing in it is sensitive, which is
why it is committed at all. Neither is a credential, neither is account-specific, and the trust
subject in particular is worth nothing to a reader who cannot compare it byte for byte against
the one their tokens carry. A cloner regenerates both — `docs/BOOTSTRAP.md` section 2 has the
`gh api` call — and re-applies.

---

## 1. Identity

### 1.1 The role

```
arn:aws:iam::<account_id>:role/react-cloudfront-app-deploy-<env>
```

One role per environment, created and destroyed **with** that environment by
`modules/static-site/iam.tf`. `<env>` is `stage` or `prod`.

Three things about that ARN are contract rather than convention, and each fails somewhere other
than where it was written:

- **The name.** `react-cloudfront-app-deploy-<env>`, not `<name_prefix>-…`, which is the naming
  convention every other resource in the module follows. `bootstrap/oidc.tf` grants CI
  `iam:CreateRole` only on the exact ARN `role/react-cloudfront-app-deploy-<env>`, so a role
  named anything else cannot be created at all. Because the role is destroyed and recreated on
  every cycle, its ARN is stable only because its *name* is — which makes the name part of this
  contract. Renaming it is a breaking change in the app repository, not a refactor in this one.

  The `<env>` suffix is enforced by IAM, not merely by convention, and reading it as a prefix
  grant with a free-form tail is the mistake to avoid. `ManageAppDeployRoleBounded` and
  `ManageAppDeployRoleUnbounded` are rendered once per environment against one exact ARN each, so
  the whole name is enforced: an `<env>` the infrastructure repository's bootstrap does not list
  is refused at `iam:CreateRole` during that repository's own apply, before this contract is
  reachable at all. The failure lands on the side that can fix it — but it also means the set of
  valid `<env>` values is fixed by the bootstrap's `environments` list rather than by whatever
  the module was applied with.
- **The path.** There is none: the ARN is `role/react-cloudfront-app-deploy-<env>`, never
  `role/app/react-cloudfront-app-deploy-<env>`. A path segment would put the ARN outside the ARN
  the bootstrap's `iam:CreateRole` grant names — simulation returns `implicitDeny` for a pathed
  role, and the exact per-environment ARN refuses it for the same reason and more narrowly.
- **The permissions boundary.** Mandatory. CI's `iam:CreateRole` is conditioned on it. What that
  means for the app repository is section 7.

The app repository composes the ARN from one variable holding the account id and the `<env>` it
was dispatched with; there is nothing else varying in it. That variable is a **variable, not a
secret**, for the reason `bootstrap/outputs.tf` gives about the ARNs it publishes: a role ARN is
an identifier, not a credential, it is useless without a trust policy naming the one repository
allowed to assume it, and masking it turns the single most common OIDC failure — an
`AssumeRoleWithWebIdentity` refusal, diagnosed by reading the ARN the job actually tried — into
an unreadable one.

**Region: `us-east-2`**, which is `aws_region` in `envs/<env>/terraform.tfvars`. Set it on the
credentials step. The three SSM parameters are regional and exist in that region only; a deploy
pointed at any other region fails at discovery with `ParameterNotFound`, which reads like a
missing environment rather than a wrong region. CloudFront is global and its API answers on a
global endpoint, so the invalidation calls are unaffected by which region is configured.

**Session length is capped at one hour.** `max_session_duration` on the role is 3600 seconds.
`aws-actions/configure-aws-credentials` requests one hour by default, so the default works; a
`role-duration-seconds` above 3600 is refused by STS with a `ValidationError` naming the role's
maximum, not the value you asked for.

### 1.2 The trust policy, and what it does not trust

The trust policy has **exactly one statement**, allowing **exactly one action**:

```
sts:AssumeRoleWithWebIdentity
```

Its only principal is `Federated`, naming the GitHub OIDC provider. **No AWS principal is
trusted** — not the account root, not this repository's plan or apply roles, not a local
operator.

That has a consequence the app repository should know before it starts debugging: this role
cannot be assumed by hand. There is no `aws sts assume-role` that reaches it, so there is no way
to rehearse a deploy from a laptop and no way for anyone in *this* repository to exercise the
inline policy on the app repository's behalf. The first real exercise of these five permissions
is the app repository's first deploy, with a real token. That is the enforcement, and section 7
explains why nothing cheaper was built.

There is one condition operator, `StringEquals`, over two condition keys. Both are required and
neither is padding:

| Key | Value |
|---|---|
| `token.actions.githubusercontent.com:aud` | `sts.amazonaws.com` |
| `token.actions.githubusercontent.com:sub` | the subject below |

`aud` is `sts.amazonaws.com`, which is what `configure-aws-credentials` requests by default.
**Do not set the action's `audience:` input.** Omitting the `aud` condition is the first of the
two classic GitHub-OIDC trust mistakes — the role would then trust any token this issuer minted
for this subject, whoever it was minted for — and this policy does not make it.

### 1.3 The subject, byte for byte

Identical for `stage` and `prod`, 74 characters, no wildcard anywhere in it:

```
repo:isai2105@22457760/react-cloudfront-app@1353875150:ref:refs/heads/main
```

Composed by `modules/static-site/iam.tf` as:

```
repo:<app_github_owner>@<app_github_owner_id>/react-cloudfront-app@<app_github_repository_id>:ref:refs/heads/main
```

This is GitHub's immutable subject format, with the numeric owner and repository ids embedded
alongside the names. Repositories created after 2026-07-15 mint tokens in this form only, and
`react-cloudfront-app` is one of them — a trust policy written in the older `repo:owner/name:…`
shape fails on the very first deploy with an error that gives no hint why. The shape was not
read from documentation: every subject in this design was decoded out of a real token minted on
a throwaway branch.

Four properties follow from it, and each of them is a way a correct-looking workflow fails.

**`StringEquals`, so the match is byte-exact.** The execution plan called for `StringLike` and
both `bootstrap/oidc.tf` and the module substituted `StringEquals` for it: with no wildcard in
the value the two behave identically, but under `StringLike` adding a `*` is a one-character
change that silently widens the trust, while under `StringEquals` it does not work until someone
also changes the operator — a second, visible edit a reviewer has to look at.

**`:ref:refs/heads/main`, so only `main` deploys.** A push-built token from a branch, a tag or a
pull request carries a different `sub` and is refused at the credential exchange, before any AWS
call is made. This is not a policy the app repository can relax from its side.

**The subject is identical for `stage` and `prod`.** Nothing in IAM distinguishes the two
deploys — the same branch of the same repository holds credentials for both, and the separation
is the role *name* and the environment's own parameters, not the trust. A dispatch that passes
`prod` where `stage` was meant is a valid credential exchange and a real deploy. If that ever
needs to be a gate, it is a gate in the app repository (a GitHub Environment with a reviewer, on
a job that does not itself assume the role — see 1.4) or a change to these trust policies here.
It is not one today.

**There is no `Environment` claim in this subject, and that is a clause the app repository must
honour.** See 1.4.

### 1.4 The deploy job must declare no GitHub Environment

GitHub's `environment:` claim **replaces** the ref claim in `sub` rather than appearing beside
it. That was measured, not assumed — on a `push` run and a `pull_request` run whose `ref` claims
differed while their `sub` claims were byte-identical — and it is the same fact
`docs/BOOTSTRAP.md` records for this repository's own roles.

So a deploy job that declares `environment:` gets

```
repo:…/react-cloudfront-app@…:environment:<name>
```

which this trust policy does not match, and the deploy fails at
`AssumeRoleWithWebIdentity` — before the workflow has done anything an error message would
explain. **The job that assumes this role declares no `environment:`.** If the app repository
wants an environment gate, either put it on a separate job that only waits and does not assume
the role, or change this line here; the two repositories change together, and this document
changes with them.

### 1.5 Workflow permissions

On the job that assumes the role:

```yaml
permissions:
  id-token: write
  contents: read
  actions: read
```

Three scopes, three reasons, and the third is the one that is easy to omit:

- **`id-token: write`** mints the OIDC token. Without it there is no token to exchange and
  `configure-aws-credentials` fails before reaching AWS.
- **`contents: read`** checks out the repository, which the verification step of section 4.2
  needs.
- **`actions: read`** reads a **different workflow run's** artefacts. The deploy downloads the
  build rather than rebuilding it (section 3), and a cross-run artefact download is an Actions
  API read, not a workflow-local one. Without this scope the download 404s or 403s — and a
  document that prescribes the cross-run download and omits the scope it needs sends the reader
  to debug the trust policy, which will be correct.

---

## 2. Discovery

Three parameters, `String` type, at exactly these names:

```
/static-site/<env>/bucket_name
/static-site/<env>/cloudfront_distribution_id
/static-site/<env>/site_url
```

Read all three, on every deploy, by these exact names. **Do not hardcode a bucket name, a
distribution id or a hostname, and do not derive one from another.** None of the three is
knowable in advance and none of them survives a cycle: the bucket name carries a `random_id`
suffix minted on every apply, the distribution id is assigned by AWS, and the distribution's
hostname is reissued every time the environment is torn down and re-applied. A value cached in a
repository variable is a value that is wrong after the next teardown, and it fails as an upload
into a bucket that no longer exists rather than as anything that names the cache.

`site_url` is published **scheme-qualified and whole** — `https://` plus the alias when a custom
domain is configured, plus the distribution's own `*.cloudfront.net` domain when it is not. The
module owns that conditional; the consumer never re-derives it and so never gets the
custom-domain case wrong. Nothing composes a URL out of `bucket_name`.

**One API call per parameter.** The role holds `ssm:GetParameter`, singular, and nothing else in
SSM:

```bash
BUCKET="$(aws ssm get-parameter --name "/static-site/${ENV}/bucket_name" \
  --query Parameter.Value --output text)"
```

`aws ssm get-parameters` (plural) and `aws ssm get-parameters-by-path` call `GetParameters` and
`GetParametersByPath`, which are different IAM actions and are **not** granted. Either one comes
back `AccessDenied` from a command that looks like an obvious optimisation of three calls into
one. The permissions boundary would permit them — it grants `ssm:Get*` — so this is a limit of
the inline policy alone, and section 7 is where that distinction stops being trivia.

**No `--with-decryption`, and no KMS grant exists.** The parameters are `String`, not
`SecureString`, because none of the three is a secret: the bucket name is visible to anyone who
can list the account's buckets, the distribution id appears in the console URL of the
distribution it names, and the site URL is the public address of a deliberately public website.
Reading a `SecureString` would need `kms:Decrypt` on top of `ssm:GetParameter`, on the
account-wide `alias/aws/ssm` key, bought in exchange for encrypting three public facts. The
role is written without one and the module's test suite asserts the parameter type, which is
what keeps that omission safe.

**The parameters are the interface; the state file is not.** The alternative was a
`terraform_remote_state` data source in the app repository, and it was rejected because it grants
that pipeline `s3:GetObject` on the state file — read access to every attribute of every resource
this module creates, sensitive ones included — in order to learn a bucket name. It also couples
the two repositories to a state layout rather than to an interface, so a resource rename here
becomes a broken deploy there. The app repository needs to know its environment name, which it
already does, and nothing else about this one.

---

## 3. The artefact: build once, promote unchanged

The app repository's CI publishes `dist/` as a workflow artefact named **`dist`**, from `main`
only, with the commit SHA stamped **inside** it as `build-info.json` rather than carried in the
artefact name. The deploy workflow takes a **`run_id`** input and downloads that exact artefact
rather than rebuilding.

**No per-environment build.** There is no per-environment configuration in this application, and
if one is ever needed it will be a runtime `config.json` written at deploy time, not a rebuild.
The alternative — baking `VITE_*` values in at build time — makes stage and prod different
binaries and turns every promotion into a fresh build with a fresh set of ways to differ. What
this buys concretely: stage → prod is byte-identical, so a prod deploy carries no risk that its
build differs from the one that was tested.

**The artefact name is a constant.** `run_id` is the deploy's only artefact input, and a name
carrying the SHA would need a second input that nobody has to hand during a rollback. Rollback
is therefore a redeploy of an older artefact by `run_id` — not a rebuild, which only works if
the build is reproducible and which nobody wants to discover it is not during an incident.

**`build-info.json` is uploaded and invalidated like the document, not like an asset.** It has no
content hash in its name, so it is mutable, so section 4 treats it as mutable. It is what lets a
verification step assert *which* build is live rather than only that something is.

---

## 4. The deploy sequence

`BUCKET` and `DIST` come from section 2.

**Nothing here passes `--cache-control` or `--metadata`.** The browser-facing `Cache-Control` is
set by the distribution's response headers policies with `override = true` — so an origin header
would be overridden anyway — and the edge TTLs come from the cache policies. Uploading header
metadata would be writing a value that has no effect and reads as if it does.

**Nothing here passes `--acl` either, and that one fails rather than being ignored.** The bucket
is `BucketOwnerEnforced`, so S3 rejects any request carrying an ACL outright, and the permissions
boundary explicitly denies `s3:PutObjectAcl` on top of that. An `--acl public-read` copied from a
pre-OAC tutorial is refused twice over — which is the intended outcome, since the bucket is
private and CloudFront reaches it through an origin access control rather than through object
permissions.

### 4.1 The four commands, in this order

```bash
# 1. Hashed assets first.
aws s3 sync dist/assets "s3://${BUCKET}/assets"

# 2. The remaining root files, including the build-info.json stamp.
aws s3 sync dist "s3://${BUCKET}" --exclude "assets/*" --exclude "index.html"

# 3. The pointer, last.
aws s3 cp dist/index.html "s3://${BUCKET}/index.html"

# 4. Invalidate the mutable objects, and only those.
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "${DIST}" \
  --paths / /index.html /build-info.json \
  --query Invalidation.Id --output text)"
```

**The order is the deploy's only concurrency control.** Every asset the new `index.html`
references exists in the bucket before anything serves that `index.html`. Reverse steps 1 and 3
and there is a window — as long as the asset upload takes — in which a viewer receives a
document referencing chunks that are not there yet, and gets the origin's `403` for each of them.

**No `--delete` on either sync.** That is section 5, and it is a decision rather than an
omission.

**The invalidation names the mutable objects and no others.** `/assets/*` filenames are
content-hashed, so a given asset URL never changes content — invalidating them is waste, and at
scale it is waste that is billed once the first 1,000 paths per month are used. `/` is listed
alongside `/index.html` even though the viewer-request function makes them the same cache key:
a request for `/` has its URI rewritten to `/index.html` **before** the cache lookup, so
invalidating `/index.html` already covers it. `/` is listed anyway because a path inside the free
allowance costs nothing, and because the equivalence is a property of a CloudFront Function in
this repository rather than something the app repository can see.

**Wait for the invalidation before verifying.**

```bash
aws cloudfront wait invalidation-completed \
  --distribution-id "${DIST}" \
  --id "${INVALIDATION_ID}"
```

The waiter polls `GetInvalidation`, which is the reason the role holds that action alongside
`CreateInvalidation`. Skipping the wait does not make the deploy faster; it makes section 4.2
assert against whatever the edge happens to be holding, which for a document with
`default_ttl = 0` is usually but not always the new one.

### 4.2 Verification, before the job is allowed to pass

An upload that exits 0 is not a deploy. Invalidations are asynchronous, a sync can land in the
wrong prefix, and an HTML file can reference hashes that were never uploaded — all three exit 0.
The minimum this contract requires, against the published `site_url`:

1. `GET /` returns **200**;
2. extract the `/assets/*` filenames the returned HTML references, and assert **each of them**
   returns 200.

Those two together are what actually falsifies "the sync landed somewhere else" and "the
document references a chunk that is not there". The app repository runs a wider set than this —
deep links, a missing asset, the response headers, and the `build-info.json` stamp — and **its**
plan is the authority on that list. Four facts about this distribution decide what those wider
assertions may expect, and every one of them is measured rather than predicted:

- **A deep link returns 200 and is served under the document's policies.** `GET /projects/x`
  names no file, so a viewer-request function rewrites it to `/index.html`. The rewrite does not
  change which cache behaviour serves the response, so it comes back with
  `cache-control: no-cache`, not the assets policy's value.
- **A missing asset returns `403`, not `404`.** This is the one most likely to be asserted
  wrongly, and it is deliberate on both counts. The bucket policy grants `s3:GetObject` without
  `s3:ListBucket`, so S3 withholds key-existence information from a caller that may not
  enumerate and answers a missing key with `403`; nothing maps that to anything else, so
  CloudFront hands it to the viewer unchanged. **A `404` here would be a failure**, not a
  cosmetic difference: it would mean the origin has started disclosing key existence. This
  repository's end-to-end workflow asserts `403` exactly and fails on `404` with that reasoning
  attached.
  - It matters more than it looks. The older, more widely published SPA pattern maps the
    origin's 403 and 404 to `/index.html` with a `200`, and that mapping is defined once per
    distribution and cannot be scoped to one behaviour — so a missing hashed chunk came back as
    `200` carrying `text/html` where the browser expects JavaScript. Parse error in the console,
    healthy 200 in monitoring, and a failure that is close to undiagnosable. It was observed
    live on 2026-08-31 and that is why the mechanism was replaced. An app-side assertion that
    accepts a `200` for a missing asset would be blind to its return.
- **A hashed asset carries `cache-control: public, max-age=31536000, immutable`**, and the
  document carries `cache-control: no-cache`. These come from the response headers policies, not
  from anything the deploy uploads.
- **Whether the response headers survive the forwarded 403 is an open question**, recorded in
  `modules/static-site/README.md` and printed but never asserted by this repository's end-to-end
  workflow. Do not build an assertion on it in either direction: one observation is not a
  contract.

One residual belongs in the app repository's own tests rather than here: **a route whose last
path segment contains a dot is not rewritten.** `/users/jane.doe` is read as a request for a
file, is not rewritten, and reaches the viewer as the origin's `403` rather than as the
application. Nothing at the edge can distinguish that route from a request for a file of that
name. The application must avoid dots in the final segment of a route.

### 4.3 The bucket is not empty before your first deploy

The module seeds `index.html` with a placeholder document, so a freshly applied environment
serves a real page at `/` before anything has been deployed to it. That exists so an applied
environment is independently servable — without it, every route fails at once with the origin's
`403`, and the first instinct on reading that is to go looking for a bug in the distribution
that is in fact correct.

Two consequences for the app repository:

- **`GET / → 200` does not prove your build is live.** It proves the bucket, the distribution
  and the origin access control are working. Asserting *which* build is live is what
  `build-info.json` is for, and it is why the SHA is stamped inside the artefact rather than
  carried in its name.
- **Step 3 of section 4.1 overwrites that exact key**, which is intended. The module declares
  `ignore_changes = [content, etag]` on the object precisely so a later `terraform apply` does
  not see the real build, call it drift, and silently revert a deployed site to a placeholder.
  Nothing in this repository puts the placeholder back.

The placeholder is also written with no `Cache-Control` of its own, for the same reason the
deploy sets none: the header the browser sees comes from the response headers policy with
`override = true`, and an origin header would be read back as drift the moment the app
repository overwrote the key without setting one.

---

## 5. No `--delete` on the sync

Both defaults are wrong and this is the less wrong one.

`aws s3 sync --delete` removes the previous build's hashed files as soon as the new build lands.
Viewers whose browsers still hold the **old** `index.html` — which is every viewer with the page
already open, and every viewer who loaded it in the last few seconds — then request chunks that
have just been deleted and get the origin's `403`. That is the classic
`ChunkLoadError`-after-deploy: an application that was working a moment ago breaks in place, for
people who did nothing.

Old assets must outlive cached copies of the HTML that references them. Since nothing knows how
long that is, nothing deletes them.

**The cost is real and is not paid here.** The bucket grows by one build's worth of assets on
every deploy, forever. A durable deployment closes that with an **S3 lifecycle rule expiring
objects under `assets/`** at some multiple of the longest plausible session — and this
repository does not have one yet. It is named as a gap in `modules/static-site/README.md` rather
than left for someone to find in a bill.

The role's permissions make the rule enforceable rather than advisory: **`s3:DeleteObject` is not
granted.** A deploy that adds `--delete` does not quietly strip the bucket; it fails on the first
delete with an `AccessDenied`. A permission for a call the pipeline does not make is a permission
an attacker makes it with.

Note where that refusal comes from, because it is the shape section 7 describes: the permissions
boundary **does** permit `s3:DeleteObject` — it grants `s3:*Object*` as a class ceiling — and the
inline policy withholds it as a verb. The two controls answer different questions, and this is
the one they answer differently.

---

## 6. Content-Security-Policy constraints

The distribution serves a strict, hash-free CSP, attached to **both** response headers policies —
the document behaviour and `/assets/*` — from a single `local` in
`modules/static-site/policies.tf`:

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
```

175 characters. It is published as the module's `content_security_policy` output and re-exported
by the environment roots, so a consumer asserts against the value the policies were built from
rather than against a second copy of the string.

### 6.1 What the application may not do

- **No `@vitejs/plugin-legacy`.** It requires inline scripts and per-version `cspHashes`, and
  `script-src 'self'` admits neither.
- **No runtime CSS-in-JS.** Anything that injects a `<style>` element at runtime — a CSS-in-JS
  library, Tailwind's Play CDN, Tailwind's dev-server mode — violates `style-src 'self'`.
  Vite's production build extracts all CSS to files and loads even async-chunk CSS through a
  JS-created `<link rel="stylesheet">`, never a `<style>` element, so a hash-free policy is not a
  compromise: it is what the build already emits. The constraint is the bundler and the absence
  of a style runtime, **not** the CSS framework.
- **No network call to any other origin.** `connect-src 'self'` means `fetch`, `XMLHttpRequest`,
  `WebSocket` and `EventSource` may reach this distribution and nowhere else. A third-party
  analytics beacon, an error reporter or an external API is blocked by the browser. Adding one
  is a change here.
- **No remote fonts, images or frames.** `font-src 'self'`, `img-src 'self' data:` and
  `default-src 'none'` between them close everything not named. `data:` is granted to `img-src`
  alone, and it is required rather than lax: Vite inlines assets below `assetsInlineLimit` as
  data URIs.

Each of these needs a corresponding change to the response headers policy in **this**
repository, and this repository's end-to-end smoke test asserts the current header on every run.

### 6.2 A `<meta http-equiv>` tag is not an escape hatch

Multiple CSPs **intersect; they never override** (CSP3 §8.1). An application served by this
distribution can only ever tighten what is set here, never relax it. That decides which side may
fix a CSP problem, and the answer is always this repository. A `<meta>` policy also silently
ignores `frame-ancestors`, so a policy that works as a header stops protecting against framing
the moment it is moved into the document, with no error anywhere.

### 6.3 The app repository holds this string and refuses to deploy when it drifts

This is the half of the coupling that is invisible from inside this repository, and it is a
requirement on the app pipeline rather than a description of one.

The app repository holds this same policy in a single file, and **its deploy refuses to upload
anything until the live `content-security-policy` header matches that file.** Compared after
normalising both per CSP3 §2.2.1 — directive names lowercased, whitespace collapsed, duplicate
directives dropped first-wins, directives and source lists sorted — so a reordering is not a
failure and a changed source expression is.

Editing the `local` here is therefore a **contract change, not a local one**: until the same
change lands in the app repository, its next deploy is refused.

**No ordering avoids the window.** Apply here and the app is red until it updates; update there
first and it is red until this applies. The window is the point — the app is built to satisfy
this policy, and a build that has not been tested against the new one should not reach a
distribution serving it.

One structural fact keeps that check honest, and it is worth knowing because its failure is
silent. Both response headers policies are generated from one map, so a single assertion against
`/` describes `/assets/*` as well. If that ever stops being true — two literal blocks, one
edited — the app's check goes blind to half the distribution **without failing**.

---

## 7. Effective permissions are an intersection the app repository cannot see

The deploy role's inline policy is not the whole answer to "what may this role do". The role also
carries a **permissions boundary**, and a boundary is a ceiling rather than a grant: an action is
permitted only if the inline policy allows it *and* the boundary allows it.

```
effective = intersect( inline policy "deploy", permissions boundary )
```

Both halves live in **this** repository, in two different roots, and the app repository can see
neither:

| Half | Where | Shape |
|---|---|---|
| Inline policy `deploy` | `modules/static-site/iam.tf` | Inline `aws_iam_role_policy`, 4 statements, exact ARNs from the module's own graph |
| Boundary `<name_prefix>-app-deploy-boundary` (`isai2105-app-deploy-boundary` here) | `bootstrap/oidc.tf` | Managed policy, verb families over name patterns, plus two `Deny` statements |

The boundary's name reaches the module as an input — `app_deploy_boundary_policy_name`, published
by the bootstrap as the output of the same name — and the module composes the ARN from it. **The
module never reads the policy body.** It cannot: `iam:GetPolicy` and `iam:ListPolicies` are
granted to no role in `bootstrap/oidc.tf`, deliberately, so a lookup would fail on the first
pull-request plan.

So an `AccessDenied` in the app repository has two possible causes, in two files, in a repository
that pipeline has no visibility into. Which is why the answer is written down here rather than
inferred there.

### 7.1 Five actions, and that is the complete set

```
s3:PutObject                    on this environment's bucket, all keys
s3:ListBucket                   on this environment's bucket
cloudfront:CreateInvalidation   on this environment's distribution
cloudfront:GetInvalidation      on this environment's distribution
ssm:GetParameter                on this environment's three parameters
```

Not a summary, not the interesting ones — the complete set. There is no `Resource: "*"` anywhere
in the inline policy and no `Deny` statement in it. Every resource ARN is read from a resource in
the module's own graph rather than composed as a string, which is why none of them can be stale
after a teardown cycle.

**Anything outside those five requires a change in this repository, not in the app repository.**
There is no configuration, no variable and no workflow input on the app side that widens it. In
particular:

- `s3:DeleteObject` — withheld on purpose (section 5).
- `s3:GetObject` — not needed. `aws s3 sync` decides what to upload by *listing* the destination,
  not by reading objects back.
- `ssm:GetParameters`, `ssm:GetParametersByPath` — not granted (section 2). Permitted by the
  boundary, refused by the inline policy.
- `cloudfront:ListInvalidations`, `cloudfront:GetDistribution` — permitted by the boundary,
  refused by the inline policy.
- `kms:Decrypt` — granted by neither, and the parameters are `String` so nothing needs it.

Four of those five bullets are refused by the inline policy alone — the boundary would have
allowed every one of them, and only `kms:Decrypt` is refused by both. That is the shape to
expect rather than a discrepancy: the boundary is deliberately a **superset**. Making the two
identical looks tighter and is worse — the boundary can only be widened by a hand-applied change
to the bootstrap, landed before the change that needs it, so an exact copy turns every ordinary
permission adjustment into a two-repository lockstep with a privileged apply in the middle.

### 7.2 The intersection as it stands

It holds, action by action, and this is a statement about the current code rather than a hope
about it:

| Action needed | Inline policy | Boundary | Covered by |
|---|---|---|---|
| `s3:PutObject` | explicit | `s3:*Object*` | glob |
| `s3:ListBucket` | explicit | `s3:ListBucket` | explicit |
| `cloudfront:CreateInvalidation` | explicit | `cloudfront:CreateInvalidation` | explicit |
| `cloudfront:GetInvalidation` | explicit | `cloudfront:Get*` | glob |
| `ssm:GetParameter` | explicit | `ssm:Get*` on `parameter/static-site/*` | glob |

The boundary's two `Deny` statements — `DenyContentAccessControl` (object-lock, ACL and retention
writes) and `DenyStateBucket` (all of S3 on the state bucket) — intersect none of the five.

### 7.3 What is not checked, and why nothing was built to check it

**Nothing compares these two documents.** Not `terraform plan`, not `tflint`, not `trivy`, not
the module's test suite, not a required check, and not a reviewer looking at one diff. The module
receives the boundary by name and composes an ARN from it; the ARN is asserted, the *body* is
never seen. Two edits are silent in both repositories and loud only in the third place:

- **narrowing a verb family in `bootstrap/oidc.tf`** — say `s3:*Object*` to `s3:PutObject` —
  plans clean, applies clean, and is a new policy *version* applied in place with no role
  touched;
- **adding a sixth action to `modules/static-site/iam.tf`** that the boundary does not permit —
  plans clean, applies clean, and produces a role whose inline policy names an action it does not
  effectively hold.

Either one surfaces as a runtime `AccessDenied` in the app repository's deploy job, naming an
action whose grant is visible in the role's own policy, from a ceiling that is not.

A static subset-checker was considered and deliberately not built. Implementing IAM's wildcard
semantics correctly — `*Object*` matching mid-token, `Get*` as a prefix, resource wildcards
spanning `/` — is fiddly, and a half-correct checker gives false confidence, which is worse than
none: it would pass on the day it mattered. The app repository's first deploy exercises all five
actions end-to-end with a real token, against a live environment, and **that is the enforcement**.
It is also the only thing that can be, for the reason section 1.2 gives: no AWS principal can
assume this role, so there is no way to rehearse it from here.

The practical consequence for whoever changes either file: the deploy role's permissions are one
decision spread across two roots, and the first deploy after such a change is the test. Run it on
`stage`.

---

## 8. The environment is ephemeral, so the deploy is `workflow_dispatch`

This repository's normal operating mode is destroying infrastructure. Environments are applied,
verified and torn down; `prod` is deliberately left un-applied between the runs that exercise
it, and `stage` stands only while something needs it. **The deploy target exists only while the
infrastructure is applied.**

So the app repository's deploy workflow is **`workflow_dispatch`, not push-triggered.** A
push-triggered deploy against this design is red more often than it is green, and the redness
carries no information: it means nobody had applied an environment, which is the expected state.
A dispatch is a person saying an environment is standing.

Two consequences worth stating rather than deriving:

- **Discovery runs on every deploy** (section 2), because a re-applied environment has a new
  bucket name, a new distribution id and a new hostname. Nothing is cached between runs.
- **Against a torn-down environment, the deploy fails at discovery** with `ParameterNotFound` on
  `/static-site/<env>/bucket_name` — before it has uploaded anything, and with an error that
  names the environment. That is the correct failure and it is worth not swallowing: a deploy
  that treats a missing parameter as "use the last known value" is a deploy that uploads into
  someone else's bucket.

The role has the same lifetime. It is created and destroyed with the environment, so
`AssumeRoleWithWebIdentity` against a torn-down environment fails on a role that does not exist —
which reads as a trust problem and is not one. Check whether the environment is applied before
reading anything else.

---

## 9. Evidence

> **Not yet verified.** The line this section will carry, once it can:
>
> *Verified on YYYY-MM-DD by assuming `react-cloudfront-app-deploy-stage` from
> `react-cloudfront-app` run #N and reading all three parameters.*

That is a placeholder on purpose, and it stays one until the app repository has deployed.

The evidence it will carry can only be produced by that repository's deploy job, and that job is
written against *this document*. Filling the line in now would mean either fabricating a run link
or blocking this document on a repository that cannot be built until the document exists. The
chain runs app 0.1 → infra 28 → infra 29 → app 20–21 → infra 31, and it closes in this
repository's step 6.2, which replaces the line above with the run link, the date, and the three
parameter values that run actually read.

Until then, treat everything above as reviewed and unexercised. The five permissions in
particular have never been used by the identity that will use them, for the reason section 7.3
gives.

---

## What the app repository has to get right

**The deploy job declares no GitHub Environment.** The `environment:` claim replaces the ref
claim in the OIDC subject; a job that names one gets a subject this trust does not match and
fails at the credential exchange, before any error message can be about deployment.

**`actions: read` is not optional.** The deploy downloads its artefact from a different workflow
run. Omit the scope and the failure looks like an artefact problem or a trust problem; it is
neither.

**Three `get-parameter` calls, never one `get-parameters`.** The role holds the singular action
only. The obvious optimisation is an `AccessDenied`.

**Assets first, `index.html` last, and no `--delete`.** The order is the only thing keeping a
viewer from receiving a document that references chunks which are not there, and `--delete`
strips chunks out from under viewers who are already holding the previous document. Neither is a
style preference; `s3:DeleteObject` is not granted, so the second one fails rather than
succeeding quietly.

**A missing asset is a `403`, not a `404`.** Assert it exactly. A `200` for a missing asset is the
undiagnosable failure this design was rebuilt to remove.

**Five permissions, and widening them is a change in the infrastructure repository.** Both halves
of the ceiling — the inline policy and the permissions boundary — live in files the app
repository cannot see, in two different roots. Nothing compares them; the first deploy after a
change to either one is the test.

**The CSP is this repository's to set and the app's to satisfy.** No legacy plugin, no runtime
CSS-in-JS, no third-party network call. Changing it is a two-repository change with an
unavoidable window in which the app's deploy is refused, and that window is the point.

**Nothing here is cached between deploys.** The environment is ephemeral by design: read the
three parameters every time, and expect `ParameterNotFound` to mean "nobody has applied that
environment" rather than "something is broken".

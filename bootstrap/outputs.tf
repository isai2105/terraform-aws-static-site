# What the bootstrap hands back to the person who ran it.
#
# The bucket name carries a random suffix, so it is discoverable in exactly one
# place: here. An output that made the cloner assemble the backend
# configuration themselves would be publishing a fact and withholding the use
# of it, so the init line is emitted whole and ready to paste.

output "state_bucket_name" {
  description = "Name of the S3 bucket holding remote state for every other root in this repository."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_region" {
  description = "Region the state bucket was created in. Backend configuration needs it explicitly; S3 will not infer it."
  value       = aws_s3_bucket.state.region
}

output "backend_init_command" {
  description = "The literal command that points an environment root at this state bucket. Substitute the environment name for <env> in both places."

  # The flag form rather than a `backend.hcl` file, because it is complete on
  # its own — the file form needs the same values written into a file first,
  # and the file is gitignored precisely because these values are per-account.
  #
  # `use_lockfile=true` is native S3 state locking, which is why this
  # repository's CLI floor is 1.11 (versions.tf).
  value = <<-EOT
    terraform -chdir=envs/<env> init \
      -backend-config="bucket=${aws_s3_bucket.state.bucket}" \
      -backend-config="key=<env>/terraform.tfstate" \
      -backend-config="region=${aws_s3_bucket.state.region}" \
      -backend-config="use_lockfile=true"
  EOT
}

# The CI identities, and the platform configuration that points the workflows
# at them.

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider. The static-site module takes it as an input when it creates the app repository's deploy role."

  # Nothing in this phase consumes it. It is published here anyway because the
  # alternative is reopening and re-applying the bootstrap in the middle of the
  # phase that needs it, and a three-line output is cheaper than that.
  value = aws_iam_openid_connect_provider.github.arn
}

output "ci_plan_role_arn" {
  description = "ARN of the read-only role pull-request CI assumes to run terraform plan."
  value       = aws_iam_role.plan.arn
}

output "ci_apply_role_arns" {
  description = "ARNs of the roles environment-gated CI assumes to apply and destroy an environment, keyed by environment name. One role per environment, each able to write only that environment's state."

  # A map rather than a single ARN, because there is no longer a single answer:
  # `oidc.tf` mints one apply role per environment so that a job applying stage
  # cannot write prod's state file. The consequence for anyone reading outputs
  # is that `terraform output -raw` does not apply to this one — see section 5
  # of docs/BOOTSTRAP.md for the `-json` form that reads a single entry out.
  value = { for environment, role in aws_iam_role.apply : environment => role.arn }
}

output "site_bucket_name_prefix" {
  description = "Required name prefix for site buckets. The apply roles share one S3 grant and it is scoped to this pattern, deliberately disjoint from the state bucket's name, so a bucket named outside it cannot be created by CI."
  value       = local.site_bucket_prefix
}

output "repository_variable_commands" {
  description = "The commands that turn a fresh clone into a repository whose workflows can authenticate. Run them once, after this root has been applied. The apply role ARN is set per GitHub Environment; the rest are repository-wide."

  # Variables, not secrets, and the distinction is operational rather than
  # pedantic. None of these values is confidential: a role ARN is an identifier,
  # not a credential, and it is useless without a trust policy that already
  # names the one repository allowed to assume it. Storing them as secrets would
  # mask them in logs, and the single most common OIDC failure —
  # AssumeRoleWithWebIdentity refusing a role — is diagnosed by reading the ARN
  # the job actually tried to assume. Masking it turns a two-minute fix into an
  # afternoon.
  #
  # `AWS_APPLY_ROLE_ARN` is the one set with `--env`, and that is what makes the
  # per-environment split in `oidc.tf` reach the workflows without any workflow
  # naming a role. GitHub resolves a variable at the lowest level it is defined
  # at, so a job declaring `environment: stage` reads stage's value from the
  # same `vars.AWS_APPLY_ROLE_ARN` expression that a prod job reads prod's from
  # — and every job in `apply.yml` declares one, because the trust policies
  # accept no other subject. The name must therefore NOT also exist as a
  # repository variable: nothing would shadow it, but it would sit there as a
  # second, unscoped answer to the same question, surviving every re-apply of
  # this root and going stale the first time a role ARN changes. Section 6 of
  # docs/BOOTSTRAP.md carries the check.
  #
  # The apply lines are generated rather than written out, so adding an
  # environment to `var.environments` produces its `gh variable set` line here
  # instead of leaving it to be remembered.
  value = join("\n", concat([
    format("gh variable set TF_STATE_BUCKET   --body %q", aws_s3_bucket.state.bucket),
    format("gh variable set AWS_REGION        --body %q", aws_s3_bucket.state.region),
    format("gh variable set AWS_PLAN_ROLE_ARN --body %q", aws_iam_role.plan.arn),
    ], [
    for environment, role in aws_iam_role.apply :
    format("gh variable set AWS_APPLY_ROLE_ARN --env %s --body %q", environment, role.arn)
  ]))
}

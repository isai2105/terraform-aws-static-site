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

output "ci_apply_role_arn" {
  description = "ARN of the role environment-gated CI assumes to apply and destroy an environment."
  value       = aws_iam_role.apply.arn
}

output "site_bucket_name_prefix" {
  description = "Required name prefix for site buckets. The apply role's S3 grant is scoped to this pattern, deliberately disjoint from the state bucket's name, so a bucket named outside it cannot be created by CI."
  value       = local.site_bucket_prefix
}

output "repository_variable_commands" {
  description = "The commands that turn a fresh clone into a repository whose workflows can authenticate. Run them once, after this root has been applied."

  # Repository variables, not secrets, and the distinction is operational rather
  # than pedantic. None of these four values is confidential: a role ARN is an
  # identifier, not a credential, and it is useless without a trust policy that
  # already names the one repository allowed to assume it. Storing them as
  # secrets would mask them in logs, and the single most common OIDC failure —
  # AssumeRoleWithWebIdentity refusing a role — is diagnosed by reading the ARN
  # the job actually tried to assume. Masking it turns a two-minute fix into an
  # afternoon.
  value = <<-EOT
    gh variable set TF_STATE_BUCKET    --body "${aws_s3_bucket.state.bucket}"
    gh variable set AWS_REGION         --body "${aws_s3_bucket.state.region}"
    gh variable set AWS_PLAN_ROLE_ARN  --body "${aws_iam_role.plan.arn}"
    gh variable set AWS_APPLY_ROLE_ARN --body "${aws_iam_role.apply.arn}"
  EOT
}

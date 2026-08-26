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

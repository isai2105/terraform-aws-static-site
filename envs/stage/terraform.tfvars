# Values for the account this repository is developed in.
#
# Committed on purpose, and what makes that safe is that nothing here is
# sensitive: no account id, no ARN, no key, no token. Everything AWS-specific
# that this environment produces comes back as an output rather than going in as
# an input, and everything sensitive arrives through OIDC at runtime.
#
# `.gitignore` deliberately carries no blanket `*.tfvars` rule — it would
# silently drop this file from `git add envs/stage/terraform.tfvars`, and CI
# would get an environment root with no variable values.
#
# All five values must match the ones `bootstrap/terraform.tfvars` was applied
# with. They are repeated rather than shared because a root cannot read another
# root's variables, and the failures they cause are not symmetrical:
#
#   - a wrong `aws_region` points this root at a state bucket that is not there
#   - a wrong `name_prefix` produces a bucket name outside the pattern the CI
#     apply role is scoped to, failing at apply with an AccessDenied that names
#     the bucket rather than this file
#   - a wrong `project` makes the teardown assertion query a tag nothing carries,
#     so it reports success over a leak
#
# A cloner edits these five and nothing else in this directory.

aws_region  = "us-east-2"
name_prefix = "Isai_2105"

project           = "terraform-aws-static-site"
github_owner      = "isai2105"
github_repository = "terraform-aws-static-site"

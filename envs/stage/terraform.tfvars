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
# The first five values must match the ones `bootstrap/terraform.tfvars` was
# applied with, and the last four describe things outside this root entirely.
# They are repeated rather than shared because a root cannot read another root's
# variables, and the failures they cause are not symmetrical:
#
#   - a wrong `aws_region` points this root at a state bucket that is not there
#   - a wrong `name_prefix` produces a bucket name outside the pattern the CI
#     apply role is scoped to, failing at apply with an AccessDenied that names
#     the bucket rather than this file
#   - a wrong `project` makes the teardown assertion query a tag nothing carries,
#     so it reports success over a leak
#   - a wrong `app_github_owner`, `app_github_owner_id` or
#     `app_github_repository_id` produces a trust policy that no token GitHub
#     mints will ever match, and the failure lands in the *app* repository's
#     deploy job as a bare AssumeRoleWithWebIdentity refusal that names neither
#     this file nor the value
#   - a wrong `app_deploy_boundary_policy_name` fails at apply with an
#     AccessDenied on CreateRole, quoting an ARN that appears nowhere in the plan
#
# A cloner edits these nine and nothing else in this directory.

aws_region  = "us-east-2"
name_prefix = "isai2105"

project           = "terraform-aws-static-site"
github_owner      = "isai2105"
github_repository = "terraform-aws-static-site"

# The app repository's identity, and the boundary the bootstrap published.
#
# The first three come from one command, so that a login and the two ids it
# belongs to can never be read at three different times and disagree:
#
#   gh api repos/isai2105/react-cloudfront-app \
#     --jq '{owner: .owner.login, owner_id: .owner.id, repo_id: .id}'
#
# and the fourth from the root that owns the policy, run from the repository
# root:
#
#   terraform -chdir=bootstrap output -raw app_deploy_boundary_policy_name
#
# `app_github_owner` repeats `github_owner` above and is deliberately not the
# same variable. That one is this repository's owner, tagged onto every resource;
# this one is the owner half of an OIDC subject in a different repository. They
# are equal today because one person owns both, which is a fact about this
# account rather than a property of the design.
app_github_owner         = "isai2105"
app_github_owner_id      = "22457760"
app_github_repository_id = "1353875150"

app_deploy_boundary_policy_name = "isai2105-app-deploy-boundary"

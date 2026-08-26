# Values for the account this repository is developed in.
#
# Committed on purpose, and the reason it can be is that nothing here is
# sensitive: no account id, no ARN, no key, no token. Everything AWS-specific
# that the bootstrap produces comes back as an output rather than going in as
# an input. A cloner edits the five values below and nothing else.
#
# `.gitignore` carries no blanket `*.tfvars` rule, which is what allows this
# file to be staged by name — see the commit that added it.

aws_region  = "us-east-2"
name_prefix = "isai2105"

project           = "terraform-aws-static-site"
github_owner      = "isai2105"
github_repository = "terraform-aws-static-site"

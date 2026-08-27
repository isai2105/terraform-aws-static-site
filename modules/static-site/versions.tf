# Version policy for the static-site module.
#
# The CLI floor matches the bootstrap's and every consuming root's: 1.11, for
# the native S3 locking that the environments' backends are built on. A module
# does not configure a backend, so it never sets `use_lockfile` itself, but a
# module that would load under a CLI too old for the roots that call it is a
# module whose constraint says nothing.
#
# The floor also has to cover what this file itself uses: cross-variable
# references inside `validation` blocks (variables.tf) arrived in 1.9, so 1.11
# already admits them.
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"

      # CloudFront is a global service, and its standard logging (v2) control
      # plane is not: the CloudWatch Logs delivery source, delivery destination
      # and delivery that logging.tf creates must be called for in us-east-1,
      # whatever region the rest of the environment lives in. AWS states this
      # without qualification — "you must specify the US East (N. Virginia)
      # Region, even if you want to enable cross Region delivery to another
      # destination" — and the ARNs those APIs return are us-east-1 ARNs even
      # when the destination is a bucket in Ireland.
      #
      # So this alias is not optional and it is not a convenience. A module that
      # declared only the default provider would place those three resources in
      # the environment's own region, where the API does not answer, and the
      # failure would arrive at apply time on a resource whose configuration
      # looks entirely correct.
      #
      # The certificate for the optional custom domain has the same
      # us-east-1-only constraint and reuses this alias when it arrives; that it
      # is declared here rather than there is a consequence of logging shipping
      # with the distribution, not of the domain work being started early.
      configuration_aliases = [aws.us_east_1]
    }

    # Sole use is the site bucket's uniqueness suffix (s3.tf).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

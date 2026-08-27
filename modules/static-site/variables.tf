# Inputs to the static-site module.
#
# Nothing here carries a default that encodes an environment-specific choice. A
# default is a decision made silently, and a silent decision is how stage
# configuration reaches prod. The one variable that does carry a default is
# `force_destroy`, and its default is the refusing one — see below.
#
# The module deliberately exposes no knob for anything it can decide correctly
# on its own. A variable is an interface: every one of them is a value some
# caller can get wrong, has to be documented, and has to keep working. Region,
# price class, protocol policy and the cache behaviour are properties of "a
# static site served from S3 through CloudFront", not properties of a
# particular deployment of one.

variable "name_prefix" {
  description = <<-EOT
    Prefix for the globally unique site bucket name, which is composed as
    "<name_prefix>-site-<environment>-<8 hex characters>". This must be the same
    value the bootstrap root was applied with: the CI apply role's S3 grant is
    scoped to "<name_prefix>-site-*", so a bucket named outside that pattern
    cannot be created by CI.
  EOT
  type        = string

  # Two validations rather than one, because they fail for unrelated reasons and
  # a reader fixing the second should not have to re-read the first. Both mirror
  # the bootstrap's own checks on the same value; they are repeated rather than
  # shared because a module cannot see the root that called it, and the failure
  # this catches is a plan-time error rather than an InvalidBucketName that names
  # no variable.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "The name_prefix must be lower case letters, digits and hyphens, and must start and end with a letter or digit. Dots are excluded deliberately: they break virtual-hosted-style TLS against the bucket."
  }

  validation {
    condition     = length(var.name_prefix) >= 3 && length(var.name_prefix) <= 40
    error_message = "The name_prefix must be between 3 and 40 characters. The composed bucket name adds \"-site-\", the environment name and a 9-character suffix on top of it, and S3 caps a bucket name at 63."
  }
}

variable "environment" {
  description = "Name of the environment this instance of the module belongs to, for example \"stage\" or \"prod\". It appears in the bucket name, in the delivery and log group names, and in the SSM parameter path the app repository reads."
  type        = string

  # The same character class the bootstrap requires of its `environments` list,
  # for the same reason: this value appears verbatim in an S3 bucket name, a
  # CloudWatch Logs delivery name and an OIDC subject, and restricting it to the
  # intersection of what all three accept removes a class of mismatch that only
  # shows up at apply.
  # The optional tail is what keeps this accepting a one-character name. The
  # bootstrap's `environments` list admits one, so a module that rejected it
  # would let an environment be declared in the bootstrap and then refuse to
  # deploy it — two files disagreeing about the same value.
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", var.environment))
    error_message = "The environment must be lower case letters, digits and hyphens, must start with a letter, and must not end with a hyphen."
  }

  # The composed length, checked once here rather than left to S3. The bucket
  # name is "<name_prefix>-site-<environment>-<8 hex>", so the two variables
  # share a 63-character budget and neither can be validated against it alone.
  # Catching this at plan time costs nothing; catching it at apply costs a round
  # trip to an InvalidBucketName that names neither variable.
  validation {
    condition     = length(var.name_prefix) + length(var.environment) <= 48
    error_message = "The name_prefix and environment are too long together: their combined length must be 48 characters or fewer, so that \"<name_prefix>-site-<environment>-<8 hex>\" stays within the 63-character S3 bucket name limit."
  }
}

variable "force_destroy" {
  description = <<-EOT
    Whether `terraform destroy` may delete the site bucket while it still holds
    objects. Defaults to false, which is the correct value for any environment
    whose contents are worth more than the convenience of tearing it down.

    Every environment in this repository sets it to true, because every
    environment here is ephemeral and a bucket the app repository has deployed
    into refuses to delete otherwise. That is a property of this operating model,
    not of the module, which is exactly why it is a variable.
  EOT
  type        = bool

  # The one default in this file, and it defaults to refusing.
  #
  # `force_destroy = true` is a real production footgun: it converts "terraform
  # destroy declined to remove a bucket holding data" — a safe, recoverable,
  # loud failure — into silent, unrecoverable deletion of every object in it. A
  # module that hardcodes it, or defaults it to true, has made that decision on
  # behalf of every future caller including the one running against something
  # that matters. Defaulting to false means an environment that wants the
  # dangerous behaviour has to say so in a file a reviewer reads.
  default = false
}

variable "log_retention_days" {
  description = "How long CloudFront access logs are retained in CloudWatch Logs. Applies to the log group this module creates; the log group is destroyed with the environment, so this bounds a window that in practice closes far sooner."
  type        = number

  # A default is legitimate here in a way it is not for the values above,
  # because this is not an environment-specific choice: it is a statement about
  # how long access logs are worth keeping, and the answer is the same for every
  # environment this module serves. Thirty days is the shortest retention that
  # still spans a monthly review cycle.
  default = 30

  # CloudWatch Logs accepts only this set. Anything else is rejected at apply
  # with an InvalidParameterException that quotes the list back rather than
  # naming the variable.
  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "The log_retention_days must be one of the retention periods CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

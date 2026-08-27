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

variable "seed_placeholder" {
  description = <<-EOT
    Whether to seed the bucket with a placeholder `index.html` so the site is
    servable before any application build is deployed to it. Defaults to true.

    Set it to false only where something else is guaranteed to have written that
    key first. An empty bucket behind these custom error responses does not
    serve an empty page — it serves the origin's 403, because the error response
    cannot fetch the error page it is pointed at either.
  EOT
  type        = bool

  # A default is legitimate here for the same reason as `log_retention_days` and
  # unlike the values above: it is not an environment-specific choice. "Should a
  # freshly applied environment be servable?" has the same answer everywhere,
  # and the answer is yes. The object is created once and its contents are
  # ignored from then on, so seeding costs a deployed site nothing.
  default = true
}

# The optional custom domain.
#
# All three default to null, and null here is not the kind of default the note at
# the top of this file rules out. A default that carries a *value* decides
# something on the caller's behalf silently; null decides nothing — it is how
# "the caller did not ask for this" is spelled, and it is the only way an
# argument can be genuinely optional in Terraform. The behaviour it selects, the
# default CloudFront certificate, is the one that works in every account rather
# than the one that works in the author's.
#
# Which of the two companion variables is set decides which of the two modes in
# certificate.tf is used, and exactly one of them must be set when domain_name is.
# That rule is checked on domain_name below rather than on either of them, so
# that a caller who has set none of this gets one error naming the whole
# interface instead of two errors describing halves of it.

variable "domain_name" {
  description = <<-EOT
    Fully qualified domain name to serve the site from, for example
    "app.example.com". Leave null — the default — to serve from the
    distribution's own *.cloudfront.net hostname on the default CloudFront
    certificate, which requires no domain and works in any account.

    When set, exactly one of hosted_zone_id or acm_certificate_arn must be set
    too: the first has this module request and validate a certificate through
    Route 53, the second attaches a certificate the caller has already issued.

    One exact name, never a wildcard. "*.example.com" is rejected deliberately:
    a wildcard certificate covers the subdomains and not the apex, so making it
    useful means adding example.com as a subject alternative name — and this
    module has no SANs by design, which is what lets the validation record be
    resolved with one() rather than a for_each over a set that is not known
    until the certificate exists (see certificate.tf). Accepting a wildcard here
    would advertise half a feature the rest of the file cannot complete. A
    caller who needs one issues the certificate themselves and attaches it
    through acm_certificate_arn, which is exactly what that mode is for.
  EOT
  type        = string
  default     = null

  validation {
    # Deliberately not a full RFC 1035 hostname grammar. What this catches is the
    # class of mistake that produces a confusing failure much later: a scheme, a
    # path, a trailing dot, an underscore, a bare label with no dot in it, or a
    # wildcard — the last of those being a deliberate scope decision rather than
    # a malformed input, which is why the message below says so rather than
    # leaving the caller to infer it from a grammar.
    condition = var.domain_name == null || can(regex(
      "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$",
      var.domain_name
    ))
    error_message = "The domain_name must be a bare fully qualified domain name in lower case — \"app.example.com\", not \"https://app.example.com\", not \"app.example.com.\" and not a single label. A wildcard such as \"*.example.com\" is rejected on purpose: this module issues no subject alternative names, so it cannot also cover the apex. Issue a wildcard certificate yourself and attach it with acm_certificate_arn."
  }

  # ACM caps a certificate's common name at 64 characters, and this value becomes
  # one. Caught here because the apply-time failure quotes the limit without
  # naming the variable that broke it.
  validation {
    condition     = var.domain_name == null || length(var.domain_name) <= 64
    error_message = "The domain_name must be 64 characters or fewer, which is the limit ACM places on a certificate's common name."
  }

  # The mode rule. Written as an exclusive-or rather than as two separate
  # presence checks because both failure directions are real: neither set leaves
  # the distribution with no certificate to attach, and both set leaves it
  # ambiguous which one the module was meant to honour.
  validation {
    condition = var.domain_name == null || (
      (var.hosted_zone_id != null) != (var.acm_certificate_arn != null)
    )
    error_message = "With domain_name set, set exactly one of hosted_zone_id (this module requests and validates the certificate through Route 53) or acm_certificate_arn (the certificate already exists, which is the path for a domain whose DNS is not in Route 53 in this account)."
  }

  # The inverse, which catches the quieter mistake: supplying a zone or a
  # certificate and forgetting the domain they were meant to serve. Without this
  # both are simply ignored, the site comes up on its cloudfront.net hostname,
  # and nothing anywhere says why.
  validation {
    condition     = var.domain_name != null || (var.hosted_zone_id == null && var.acm_certificate_arn == null)
    error_message = "The hosted_zone_id and acm_certificate_arn are only meaningful alongside domain_name. Set domain_name, or unset both."
  }
}

variable "hosted_zone_id" {
  description = <<-EOT
    Id of the Route 53 public hosted zone holding domain_name, when this module
    should request and validate the certificate itself. Requires that the zone
    lives in the same AWS account.

    Leave null and set acm_certificate_arn instead when the domain's DNS is
    anywhere else — a registrar's nameservers, another provider, another account.
  EOT
  type        = string
  default     = null

  # An id, never a zone name. The alternative — resolving the zone from
  # domain_name through a data source — reads as friendlier and is not: a name
  # lookup cannot tell a public zone from a private one in a split-horizon
  # account and errors on the ambiguity, and the zone name is not derivable from
  # the domain in the first place, since "app.example.com" may be a record in
  # "example.com" or a zone of its own. An id is unambiguous, and it is one
  # `gh`-style lookup for the caller rather than a guess for the module.
  validation {
    condition     = var.hosted_zone_id == null || can(regex("^Z[A-Z0-9]{4,31}$", var.hosted_zone_id))
    error_message = "The hosted_zone_id must be a Route 53 hosted zone id — a leading \"Z\" followed by upper case letters and digits, for example \"Z1D633PJN98FT9\". It is not the zone's name, and it is not the zone ARN."
  }
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an existing, already-issued ACM certificate covering domain_name, for
    the case where this module cannot validate one itself because the domain's
    DNS is not in Route 53 in this account.

    It must live in us-east-1 whatever region the environment deploys to, because
    that is the only region CloudFront reads viewer certificates from. This
    module does not manage its lifecycle: it is not created, renewed, tagged or
    destroyed here, and it survives `terraform destroy`.
  EOT
  type        = string
  default     = null

  # The region is pinned in the pattern rather than merely documented, because it
  # is the mistake this variable exists to invite. A certificate in the
  # environment's own region is a perfectly valid certificate that CloudFront
  # refuses, and the refusal arrives at apply as InvalidViewerCertificate — a
  # message about the distribution that says nothing about the region of the ARN
  # it was handed.
  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:us-east-1:[0-9]{12}:certificate/[0-9a-f-]+$", var.acm_certificate_arn))
    error_message = "The acm_certificate_arn must be an ACM certificate ARN in us-east-1, for example \"arn:aws:acm:us-east-1:123456789012:certificate/abcd1234-...\". CloudFront reads viewer certificates from us-east-1 only, whatever region the rest of the environment is in."
  }
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

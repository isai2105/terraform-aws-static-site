# The optional custom domain: the viewer certificate, and the DNS that validates
# it.
#
# Everything in this file is gated on `var.domain_name`. Left null — the default,
# and the only configuration any environment in this repository uses — none of it
# is created, the distribution keeps the default CloudFront certificate, and the
# site is served from its own `*.cloudfront.net` hostname.
#
# That fallback is not a convenience, it is what makes the repository runnable by
# someone other than its author. ACM and Route 53 both require a domain the
# cloner may not own; a module that required one would be a module a stranger
# with an empty AWS account cannot apply, which defeats the purpose of publishing
# it.
#
# ---------------------------------------------------------------------------
# Why there are two ways to supply a certificate
# ---------------------------------------------------------------------------
#
# Requesting the certificate is easy; *validating* it is the part that depends on
# where the domain's DNS actually lives. ACM issues a DNS-validated certificate
# only once a CNAME it nominates resolves, and this module can create that record
# for the caller in exactly one case: the zone is a Route 53 hosted zone in the
# same account. Any other DNS provider — a registrar's own nameservers, Cloudflare,
# a zone in a different account — is somewhere Terraform cannot reach from here.
#
# Supporting only the Route 53 case would make `domain_name` narrower than it
# looks: it would read as "bring a domain" and mean "bring a domain hosted in
# Route 53 in this account". So there are two modes, and which one is in use is
# decided by which of the two companion variables the caller sets:
#
#   domain_name + hosted_zone_id       this module requests the certificate,
#                                      writes the validation record, and waits
#                                      for ACM to issue it
#
#   domain_name + acm_certificate_arn  the caller has already issued a
#                                      certificate by whatever means their DNS
#                                      requires; this module only attaches it
#
# Setting `domain_name` with neither is rejected at plan time rather than left to
# fail at apply, because the failure it produces otherwise is
# `InvalidViewerCertificate` on a distribution — an error naming neither variable.
# variables.tf carries that rule.
#
# The second mode is also the escape hatch for the ordering problem the first one
# does not have. With external DNS the validation record cannot exist before the
# certificate that nominates it, so an apply that requested and waited would block
# while an operator raced to read the record out of the ACM console. Issuing the
# certificate first and passing its ARN turns that into two ordinary steps.

locals {
  # Read as "the caller asked for a custom domain", and used in preference to
  # repeating the null check, so that the three resources below and the
  # distribution cannot drift into different ideas of when this path is active.
  custom_domain_enabled = var.domain_name != null

  # This module owns the certificate only when the caller did not bring one.
  # variables.tf guarantees `hosted_zone_id` is set exactly when this is true, so
  # nothing downstream has to check for the combination separately.
  manage_certificate = local.custom_domain_enabled && var.acm_certificate_arn == null

  # The ARN the distribution attaches, or null to keep the default CloudFront
  # certificate.
  #
  # In the managed case this deliberately reads through `aws_acm_certificate_
  # validation` rather than off the certificate itself. The validation resource
  # has no existence in AWS — it is a wait — and taking the ARN from it is what
  # puts that wait in the dependency graph. Referencing the certificate directly
  # would let Terraform attach a PENDING_VALIDATION certificate, which CloudFront
  # rejects outright with InvalidViewerCertificate.
  viewer_certificate_arn = (
    local.custom_domain_enabled
    ? (
      local.manage_certificate
      ? aws_acm_certificate_validation.site[0].certificate_arn
      : var.acm_certificate_arn
    )
    : null
  )
}

# The certificate, in us-east-1, always.
#
# A certificate used for CloudFront viewer HTTPS must live in us-east-1 whatever
# region the rest of the environment is in — CloudFront reads it from there and
# nowhere else. The module is otherwise region-agnostic, so this is pinned to the
# `aws.us_east_1` configuration alias the caller supplies.
#
# That alias already exists rather than arriving with this file: CloudFront's
# standard logging (v2) control plane has the identical us-east-1-only constraint
# and logging shipped with the distribution. Reusing it is the point — a second
# alias for the same region would be two names for one provider configuration and
# two places for a caller to get it wrong.
#
# A cloner deploying to eu-west-1 without the alias gets InvalidViewerCertificate
# at apply time, on a code path that is otherwise never exercised.
resource "aws_acm_certificate" "site" {
  count    = local.manage_certificate ? 1 : 0
  provider = aws.us_east_1

  domain_name = var.domain_name

  # DNS rather than EMAIL. Email validation sends to addresses at the domain that
  # a cloner may not receive, expires unrenewed after 72 hours, and cannot be
  # automated at all. DNS validation renews itself indefinitely for as long as the
  # record stays in place.
  validation_method = "DNS"

  # No subject_alternative_names, deliberately. One alias means exactly one
  # entry in domain_validation_options, which is what lets the validation record
  # below use `count` and `one()` rather than a for_each over a set whose keys
  # are not known until the certificate exists. Adding SANs is not a one-line
  # change: it requires converting that resource to for_each keyed on the domain
  # names — which are known at plan time — and never on anything read back off
  # the certificate.

  # A certificate that is attached to a distribution cannot be deleted, and
  # CloudFront cannot be updated to stop using one that no longer exists. Without
  # this, replacing the certificate — a domain change, or a key algorithm change —
  # deadlocks: Terraform tries to destroy the old one first and ACM refuses
  # because the distribution still references it.
  #
  # That is the *replacement* deadlock, and it is not the failure this path is
  # most likely to hand you. On destroy, deleting the certificate can fail with
  # ResourceInUseException after the distribution is already gone, because the
  # association lingers cross-service for longer than the distribution does. The
  # provider retries for 20 minutes and then gives up; re-running
  # `terraform destroy` is the documented recovery, and nothing here can prevent
  # it. It is a known teardown constraint of this repository rather than a defect
  # in this file — see the custom-domain section of README.md and, once it
  # exists, docs/TEARDOWN.md.
  lifecycle {
    create_before_destroy = true
  }

  # Certificates *are* taggable, unlike the CloudFront policies and the origin
  # access control (see the note in policies.tf), so the teardown assertion can
  # see one that leaks. That matters more here than the count suggests: a
  # certificate left in PENDING_VALIDATION is on the post-destroy checklist
  # precisely because it is the thing a failed validation strands.
  #
  # Project, Env, Owner, Repo and ManagedBy arrive from the `default_tags` on the
  # aws.us_east_1 configuration, which the module requires and checks for at plan
  # time. This adds the one thing default_tags cannot: a name a human recognises
  # in a console list.
  tags = {
    Name = "${local.bucket_name}-viewer"
  }
}

# The record ACM nominates, written into the caller's Route 53 zone.
#
# `count` rather than `for_each`, and that is a consequence of the no-SANs
# decision above rather than a shortcut: with exactly one domain there is exactly
# one validation option, and `one()` asserts that rather than assuming it — it
# raises an error if the certificate ever nominates more than one, instead of
# silently writing the first and leaving the certificate unissuable.
resource "aws_route53_record" "certificate_validation" {
  count = local.manage_certificate ? 1 : 0

  zone_id = var.hosted_zone_id

  name    = one(aws_acm_certificate.site[0].domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.site[0].domain_validation_options).resource_record_type
  records = [one(aws_acm_certificate.site[0].domain_validation_options).resource_record_value]

  # Sixty seconds. This record is read by ACM during issuance and then only for
  # renewal checks, so there is nothing to gain from caching it — and a long TTL
  # is actively costly on the one occasion the value changes, because a stale
  # answer holds up issuance for as long as it is cached.
  ttl = 60

  # Deliberately true, and it is this operating model that makes it correct
  # rather than lazy.
  #
  # Every environment here is applied and destroyed within the hour, so a cycle
  # that fails partway through — a cancelled workflow, a destroy that gave up
  # waiting on CloudFront — can leave this record behind with no state entry
  # pointing at it. Route 53 then refuses the next apply's CREATE outright, and
  # the environment cannot be rebuilt without someone deleting a DNS record by
  # hand. Overwriting is the recovery, and the record is one this module already
  # owns exclusively: its name is dictated by ACM and unique to this certificate.
  allow_overwrite = true
}

# Not a resource in AWS: a wait.
#
# It polls DescribeCertificate until the certificate is ISSUED and exists purely
# so that the distribution's dependency on the certificate is a dependency on the
# *validated* certificate. `validation_record_fqdns` is what ties the wait to the
# record above, so Terraform cannot start polling before the record it depends on
# has been written.
resource "aws_acm_certificate_validation" "site" {
  count    = local.manage_certificate ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [aws_route53_record.certificate_validation[0].fqdn]
}

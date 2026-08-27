# Version policy for the prod environment root.
#
# The CLI floor is 1.11 for the reason every other root in this repository
# carries it: this root's backend uses native S3 locking, which landed
# experimental in 1.10.0 and went GA in 1.11.0. Unlike the bootstrap and the
# module — neither of which configures a backend — this is a root where that
# floor is load-bearing rather than declarative. `use_lockfile` in
# backend.hcl.example is not understood by an older CLI, which falls back to no
# locking at all rather than failing: two applies could then write this
# environment's state at once, and nothing would say so.
#
# Only the aws provider is declared, because it is the only one this root
# configures. The module additionally requires `random` for its bucket suffix;
# a root does not redeclare a provider it never passes a configuration to, and
# the lock file below records both regardless.
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # Pinned at the minor rather than the major, matching the bootstrap, the
      # module and `envs/stage`. `~> 6.0` and `~> 6.61` share an upper bound of
      # `< 7.0.0`; the difference is that under `~> 6.0` every later 6.x release
      # already satisfies the constraint, so nothing automated ever proposes a
      # change here and the declared floor silently ages out of relevance.
      #
      # The constraint being identical to stage's is what makes the promotion
      # path mean anything: an environment that could resolve a different
      # provider version from the one it was promoted from is an environment
      # nobody has actually tested. The lock file beside this one holds the
      # exact versions, and it is byte-identical to stage's.
      version = "~> 6.61"
    }
  }
}

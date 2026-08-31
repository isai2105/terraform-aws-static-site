# Version policy for the stage environment root.
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

      # Pinned at the minor rather than the major, matching the bootstrap and
      # the module. `~> 6.0` and `~> 6.61` share an upper bound of `< 7.0.0` —
      # `~>` lets the rightmost component increment, so `~> 6.61` is
      # `>= 6.61.0, < 7.0.0` — and what separates them is the floor alone.
      # `~> 6.0` claims any 6.x will do, which nothing here has tested; this
      # claims at least the release the lock file beside it records.
      #
      # Neither constraint is what gets a bump reviewed, because 6.62.0
      # satisfies this one already.
      # .github/workflows/provider-lock-refresh.yml is what proposes the move,
      # and this is the range it may move inside.
      version = "~> 6.61"
    }
  }
}

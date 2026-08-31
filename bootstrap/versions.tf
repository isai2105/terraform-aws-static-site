# Version policy for the bootstrap root.
#
# The CLI floor is 1.11, not the 1.5 a generated skeleton would carry. Every
# consuming root in this repository locks its state with native S3 locking
# (`use_lockfile`), which landed in 1.10.0 marked experimental and went GA in
# 1.11.0 — the same release that deprecated the DynamoDB lock arguments. A
# floor of 1.10 would admit a version in which the mechanism this design is
# built on is still experimental, and `docs/BOOTSTRAP.md` documents
# `force-unlock` against the GA behaviour.
#
# This root has no backend of its own (see state.tf) so it never sets
# `use_lockfile` itself, but the floor is stated here anyway: the bootstrap is
# the first thing a cloner runs, and it is the right place to fail fast on a
# binary too old for the roots it exists to enable.
#
# Provider constraints are pinned at the minor rather than the major, and the
# reason is the floor, not the ceiling. `~> 6.0` and `~> 6.61` share an upper
# bound of `< 7.0.0`: `~>` allows the rightmost component of the version it is
# given to increment, so a two-part `~> 6.61` means `>= 6.61.0, < 7.0.0`.
#
# What separates them is the floor alone, and a floor is a claim about what has
# been tested. `~> 6.0` says any 6.x will do, which nothing in this repository
# has established. `~> 6.61` says at least the release this was written and
# locked against, which is a claim the lock file beside it can be checked
# against.
#
# It does not make a provider bump a reviewed commit, and an earlier version of
# this comment claimed it did. 6.62.0 satisfies `~> 6.61` already, so
# `terraform init -upgrade` moves the lock file with this file untouched —
# measured, against 6.62.0, on the tree that carries this comment. What makes
# the bump a reviewed change of its own is
# .github/workflows/provider-lock-refresh.yml, which re-resolves every
# committed lock file weekly and opens the result as a pull request. This
# constraint sets the range that refresh may move inside; it does not trigger
# it and does not gate it.
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }

    # Sole use is the state bucket's uniqueness suffix (state.tf).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

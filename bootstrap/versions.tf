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
# reason is the floor, not the ceiling — `~> 6.0` and `~> 6.61` share an upper
# bound of `< 7.0.0`. The difference is that under `~> 6.0` every later 6.x
# release already satisfies the constraint, so nothing automated ever proposes
# a change to this file and the declared floor silently ages out of relevance.
# Under `~> 6.61` the constraint itself goes stale the day 6.62 ships, which is
# what turns a provider bump into a reviewed commit instead of a lock-file diff
# nobody reads.
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

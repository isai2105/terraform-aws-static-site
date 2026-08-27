# Remote state for the prod environment.
#
# The block is empty on purpose. Every value it needs — the bucket name, the
# region, the state key — is per-account: the bucket carries a `random_id`
# suffix minted by the bootstrap, so no two clones of this repository share one.
# Committing them would make this file wrong for everybody except the account it
# was written in, which is the opposite of what a reference implementation owes
# a cloner.
#
# The values are supplied at `init` instead, from two places that never
# disagree because neither is a copy of the other:
#
#   - locally, `-backend-config=backend.hcl` — gitignored, created from
#     backend.hcl.example beside this file, which the bootstrap's
#     `backend_init_command` output fills in
#   - in CI, `-backend-config=` flags read from repository variables, which the
#     bootstrap's `repository_variable_commands` output sets
#
# Three of those four values are shared with stage; the state key is not, and it
# is the one that has to differ. Two roots sharing a key is not a collision
# Terraform reports — it is prod adopting stage's resources as its own and
# proposing to destroy or rename every one of them on the next plan. The key
# lives in backend.hcl.example next door, spelled out and flagged as the line
# that a file copied from stage gets wrong.
#
# Remote state is required even though nothing here stays deployed. State must
# outlive the machine that created it, or `destroy` cannot find what to remove —
# and an environment that cannot be destroyed is the one defect this operating
# model does not tolerate.
terraform {
  backend "s3" {}
}

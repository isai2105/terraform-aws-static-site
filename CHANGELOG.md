# Changelog

All notable changes to this repository are recorded here, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file carries **interface** changes — the things a consumer builds against and breaks on. The
app repository's deploy contract (`docs/DEPLOY_CONTRACT.md`), the module's variables and outputs,
and the grants the bootstrap makes on a consumer's behalf are all interface. Internal scoping,
workflow mechanics and comment accuracy are not, and are left to git history.

## [Unreleased]

### Changed

- **The apply roles now grant `iam:CreateRole` on one exact app-deploy-role ARN per environment
  instead of the wildcard `role/react-cloudfront-app-deploy-*`.** `ManageAppDeployRoleBounded` and
  `ManageAppDeployRoleUnbounded` are rendered once per entry in the bootstrap's `environments`
  list, each naming `role/react-cloudfront-app-deploy-<env>` exactly. The consequence is that the
  set of valid `<env>` values is now fixed by that list rather than by whatever an environment root
  was applied with: an `environment` a bootstrap was never given — a `-blue`, a `-canary`, a typo —
  is refused at `iam:CreateRole` on the first apply that introduces it, quoting an ARN that appears
  in neither repository. Previously only the prefix was enforced, so a wrong suffix applied
  successfully and surfaced across the boundary in the app repository, as a role its deploy job
  could not assume. The failure moved to the side that can fix it, and it moved earlier.

  **Upgrading:** hand-apply `bootstrap/` before applying an environment. The change is a
  `PutRolePolicy` on existing roles — no role is replaced and no credential changes — but an
  environment applied against the old bootstrap policy with an `<env>` outside `environments` was
  working by accident and will now fail. Add the environment to `environments` in
  `bootstrap/terraform.tfvars` and re-apply the bootstrap first.

  The plan role is deliberately unchanged: `ReadCiIdentity` still grants on the wildcard, because a
  pull request plans every environment and has to be able to read every environment's deploy role.

### Not recorded here

Three changes in the same batch are internal and are excluded on purpose, so that their absence
reads as a decision rather than an omission:

- Removing `cloudfront:CreateInvalidation`, `GetInvalidation` and `ListInvalidations` from the apply
  role, and splitting the CloudFront function and tag actions into ARN-scoped statements. Nothing
  outside this repository calls those with this role; the app deploy role's own
  `InvalidateDistribution` grant is written by the module and is untouched.
- The destroy-time session policy the workflows now attach when re-assuming the apply role. It
  narrows a credential this repository mints for itself and degrades to a warning when it cannot be
  built; no consumer can observe it.
- Documentation and comment corrections, including the count and scoping of the CloudFront actions
  the apply role holds. They change what the repository says, not what it grants.

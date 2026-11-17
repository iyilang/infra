# iyi infrastructure

Infrastructure configuration for the iyi module proxy, checksum service, and
probe. The configuration describes intended resources, not deployed services.

## Local checks

Terraform 1.10 or later is required. From the repository root:

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

These checks do not need cloud credentials or access to remote state. The init
step may need network access to download providers. [CONTRIBUTING.md](CONTRIBUTING.md)
also covers optional ShellCheck and actionlint checks and the pull request process.

## Maintainer operations

Cloud access and deployment are separate from local validation. Maintainers
review infrastructure changes and use CI for plans and applies. Do not commit
credentials, signing keys, Terraform state, or billing account identifiers.
The [cutover guide](docs/CUTOVER.md) describes the requirements for domains
and checksum identity.

`bootstrap/bootstrap.sh --check` reads the configured project's trust-anchor
metadata. The script's mutating mode is for an approved CI environment, not a
workstation. It creates separate workload-identity pools and service accounts
for pull-request plans and main-branch applies. Set the corresponding
`IYI_PLAN_WIF_PROVIDER`, `IYI_PLAN_SERVICE_ACCOUNT`, `IYI_WIF_PROVIDER`, and
`IYI_TERRAFORM_SERVICE_ACCOUNT` repository variables before using those jobs.
The billing account identifier is supplied as the `IYI_BILLING_ACCOUNT`
repository secret. `IYI_APPLY_ENABLED` defaults to off.

The plan identity can read Terraform state, which includes the staging signing
key. Pull-request plans use `-lock=false` and can become stale during an apply.
The apply job creates and checks a fresh plan. The service-level Cloud Run IAM
provisioning sequence and other privilege boundaries in [docs/COST.md](docs/COST.md)
must be resolved before enabling apply.

## Security and license

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
This repository is licensed under the [Apache License 2.0](LICENSE).

# iyi infrastructure

Infrastructure configuration for the iyi module proxy, checksum service, and
probe. The configuration describes intended resources, not deployed services.

## CI

The Terraform workflow validates every pull request. For a pull request from a
branch in this repository, the plan job authenticates with a read-only
Workload Identity principal, checks the plan, and posts a summary to the PR.
Fork pull requests run the credential-free validation job only.

The plan principal can read Terraform state. The configuration will record
project and resource identifiers, service-account metadata, image references,
public base URLs, bucket and secret names, and deployment settings. The budget
and private signing keys are outside Terraform. Do not put credentials or
private values in image references, URLs, resource labels, or other inputs.

On a push to `main`, the apply job builds and pushes the probe image, plans
and applies infrastructure, then deploys Firebase Hosting configuration. The
proxy and checksum Hosting configurations are deployed when their images are
configured. Neither deploys nor Terraform plans run from a workstation.

## One-time trust bootstrap

CI cannot authenticate until its Workload Identity provider and state bucket
exist. A maintainer reviews `bootstrap/bootstrap.sh --dry-run`, then runs the
script's `--apply` mode once using an authenticated gcloud CLI account. The
script does not use Application Default Credentials. It creates the fixed
trust resources and resource-scoped bindings printed by the dry run.

The script prints the project, provider, and deployer service-account values
for the repository variables. A maintainer can set them with the printed
`gh variable set` commands. The billing account ID is supplied to the script
at runtime. The script does not write it to local files or logs; Google Cloud
may retain billing resource names in its own audit logs.

The budget belongs to the human bootstrap rather than the CI identity because
it is administered through the billing account. Re-running the bootstrap
checks the existing budget and refuses an incompatible or ambiguous match.
To change a budget, review it in the Cloud Billing console or use the
`gcloud billing budgets update` command template printed on a mismatch.

The bootstrap and CI permissions are documented in [docs/COST.md](docs/COST.md).
The [cutover guide](docs/CUTOVER.md) covers domains and checksum identity.

## Security and license

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
This repository is licensed under the [Apache License 2.0](LICENSE).

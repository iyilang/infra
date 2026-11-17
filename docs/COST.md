# Cost controls

The infrastructure is proposed, not applied. Controls below refer to the checked-in configuration and are not claims about live billing.

- [Cloud Run service scaling](../terraform/resource.google_cloud_run_v2_service.services.tf): minimum instances are zero. Service-wide maxima are one for each probe and the newsletter, and two for the proxy and checksum service. All use the configured region, which defaults to `us-central1`.
- [Object storage](../terraform/resource.google_storage_bucket.objects.tf): buckets are private, have uniform access and retain object versions. Applications need create-only writes and generation preconditions to preserve existing objects. A privileged storage administrator can still change or delete objects; this is not a locked-retention policy.
- [Artifact Registry](../terraform/resource.google_artifact_registry_repository.iyi.tf): the policy keeps five recent image versions and deletes older versions after the configured age. Image retention is not Firebase Hosting release retention.
- [Request logs](../terraform/resource.google_logging_project_exclusion.iyi.tf): the proposed exclusion covers successful request logs for the named iyi services only; error-level logs remain. It cannot be applied by the CI identity until a safe permission boundary is resolved.
- [Monthly budget](../terraform/resource.google_billing_budget.iyi.tf): $200, filtered to the `stack=iyi` label in the configured project, with current and forecast alert thresholds. It sends notifications through billing's default IAM recipients. It does not stop spending or disable billing. Firebase Hosting usage, shared resources, and other costs without this label do not enter this budget; the budget is not a total-spend cap.
- Cache behavior is set by each application in its response headers. Immutable public responses require `Cache-Control: public, max-age=31536000, immutable, s-maxage=31536000`; the probe measures whether Hosting actually caches them. Mutable and sensitive responses must choose appropriate non-public or shorter caching. No CDN result is assumed before measurement.

[Hosting version retention](../scripts/set-hosting-retention.sh) requests a limit of 10 finalized versions for each of the four named sites after an approved apply. This updates site configuration, not Artifact Registry images. The API operation and actual retention have not been exercised. The default project quotas and free allowances are shared across Hosting sites.

## Database alternatives

The newsletter reads `DATABASE_URL` from configuration. No database or database credential is created by this root. Connecting a new role to an existing PostgreSQL instance is unsafe if unrelated databases grant `CONNECT` to `PUBLIC`; changing those grants is outside this repository's scope.

For a separate Cloud SQL instance, Google's [Cloud SQL price table](https://cloud.google.com/sql/pricing#instance-pricing-1) lists a single-zone `db-f1-micro` in `us-central1` at $0.0105 per instance-hour. At 730 hours that is $7.67 for compute. The same [price page](https://cloud.google.com/sql/pricing#storage-and-network-pricing-1) lists SSD at $0.000232877 per GiB-hour, or $1.70 for 10 GiB over 730 hours, for approximately $9.37 before backups, networking, taxes, and other usage. Shared-core machines have no Cloud SQL SLA. Actual usage and billing can differ.

SQLite has no separate database-server charge, but [Cloud Run's writable filesystem is in memory and does not persist when an instance stops](https://cloud.google.com/run/docs/container-contract#file_system_access). A persistent design needs separately priced, verified storage and backup/recovery; mounting an object bucket is not an equivalent transactional filesystem. SQLite's actual monthly cost is therefore not established here, and an ephemeral local file is not suitable for subscriber records.

## Privilege boundaries

The bootstrap identity is distinct from the Terraform and application identities. The Terraform identity must not receive project Owner, Editor, project IAM administration, service-account administration, service-account token creation, workload-identity-pool administration, or project-wide `setIamPolicy` permissions. It receives `actAs` only on the specific runtime accounts it must deploy, never an existing project service account.

Cloud Run and service-account names are not listed among Google's [resource-name attributes for IAM Conditions](https://cloud.google.com/iam/docs/conditions-resource-attributes). A project-wide conditional grant based on an `iyi-` name is not a proven boundary for these resources. In particular, `run.services.setIamPolicy` must be granted on an individual service, not project-wide. There is a creation-order gap: the service must exist before a service-level grant can be attached. The proposed `allUsers` invoker member will therefore not be applicable by a narrowly scoped fresh Terraform identity until that service-level permission is provisioned. Do not enable apply until the provisioning sequence is reviewed and proved.

Hosting permissions are project scoped, not isolated by site in this configuration. A release-capable identity has a wider blast radius than this stack. The generated plans and no-destroy checks reduce mistakes; they are not an IAM boundary. Project log-exclusion creation has a similar project-wide blast radius. These residual risks remain unresolved.

The secret-policy grant is conditional on an `iyi-` resource-name prefix supported by Secret Manager. It does not directly grant secret-version access, but its `setIamPolicy` permission can grant that access on matching secrets. Treat Terraform as able to read any secret under that prefix. The staging private key is also present in the versioned Terraform state bucket. The optional deny policy blocks several IAM escalation permissions but has not been applied or tested; an owner-account impersonation check must run after bootstrap.

# Cost controls

These controls describe proposed infrastructure, not observed production billing.

- [Cloud Run scaling](../terraform/resource.google_cloud_run_v2_service.services.tf) uses zero minimum instances and caps the proxy, checksum, and probe services.
- The [bootstrap](../bootstrap/bootstrap.sh) creates private object buckets with uniform access. Runtime writers receive object-creation permissions on their assigned bucket. A privileged storage administrator can still change or delete objects.
- The bootstrap's image repository policy keeps the five most recent versions per package and deletes older versions after 30 days. An active image outside the retained set can be deleted.
- [Request log exclusion](../terraform/resource.google_logging_project_exclusion.iyi.tf) is limited by filter to successful requests for the named iyi services. Error-level logs remain.
- The [bootstrap budget alert](../bootstrap/bootstrap.sh) tracks $200 per month for this project. It does not stop spending or disable billing, and alerts can lag actual spend.
  The human bootstrap needs billing-account budget-list and budget-create access. It leaves an incompatible existing budget unchanged for human review.
- Immutable public responses use `Cache-Control: public, max-age=31536000, immutable, s-maxage=31536000`. The probe measures whether Hosting caches them; no CDN result is assumed before measurement.
- [Hosting version retention](../scripts/set-hosting-retention.sh) requests a limit of 10 finalized versions per site after an approved deployment. The API operation and actual retention have not yet been exercised.

## Privilege boundaries

The deployer receives no Owner, Editor, project IAM administration, or service-account administration role. The human bootstrap grants `actAs` on each fixed runtime account individually. Pull-request plans use a separate read-only Workload Identity principal, not the deployer service account.

Google provider v8.11.0 supports `invoker_iam_disabled` for Cloud Run. [Google's public-access documentation](https://cloud.google.com/run/docs/authenticating/public) says changing that setting also requires `run.services.setIamPolicy`. The approved custom role grants that one permission project-wide. It can change invoker IAM on any Cloud Run service in this project.

[Firebase's permissions documentation](https://firebase.google.com/docs/projects/iam/permissions#firebase-hosting-permissions) says custom roles cannot control Hosting. The deployer therefore receives `roles/firebasehosting.admin` on the project. It can update or delete any Hosting site there, including the default site. A deleted Hosting site's ID cannot be reactivated. Terraform's `prevent_destroy` and plan gate stop Terraform deletion, not a direct API call by the deployer. The plan identity does not receive this role.

The deployer can create project log exclusions and enable project APIs. Those permissions have project-wide effect. Artifact Registry writer access is scoped to the one bootstrapped repository; state-object access is scoped to the state bucket. CI has no budget permissions. The deployment jobs and the plan gate are not substitutes for those IAM boundaries.

The existing Firebase admin service account holds project-wide token-creator permission. The deployer must not be able to impersonate it. Effective permission checks and the first CI plan remain unproven until the one-time bootstrap has run.

# Bootstrap owns the identity, billing budgets, Artifact Registry, Secret Manager,
# and Storage APIs. Cloud Run remains enabled on destroy.
resource "google_project_service" "iyi" {
  for_each = toset([
    "run.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

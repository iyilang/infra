data "google_artifact_registry_repository" "iyi" {
  project       = var.project_id
  location      = var.region
  repository_id = "iyi"
}

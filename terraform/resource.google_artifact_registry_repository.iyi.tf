resource "google_artifact_registry_repository" "iyi" {
  project       = var.project_id
  location      = var.region
  repository_id = "iyi"
  description   = "Container images for the iyi package stack"
  format        = "DOCKER"

  cleanup_policies {
    id     = "retain-recent-images"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
  cleanup_policies {
    id     = "remove-older-images"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
}

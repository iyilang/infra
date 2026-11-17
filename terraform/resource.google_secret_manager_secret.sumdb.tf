resource "google_secret_manager_secret" "sum_staging" {
  project   = var.project_id
  secret_id = "iyi-sum-staging-signing-key"
  replication {
    auto {}
  }
}

# Staging only. This key is stored in Terraform state as well as Secret
# Manager, so the state bucket is private and has restricted IAM.
resource "tls_private_key" "sum_staging" {
  algorithm = "ED25519"
}

resource "google_secret_manager_secret_version" "sum_staging" {
  secret      = google_secret_manager_secret.sum_staging.id
  secret_data = tls_private_key.sum_staging.private_key_pem
}

# This resource is only a container. No production key or key version exists
# unless the permanent key name has been chosen and this flag is enabled.
resource "google_secret_manager_secret" "sum_production" {
  count     = var.production_namespace_ready ? 1 : 0
  project   = var.project_id
  secret_id = "iyi-sum-production-signing-key"
  replication {
    auto {}
  }

  labels = {
    key_namespace_ready = "true"
  }
}

resource "google_secret_manager_secret_iam_member" "sum_staging" {
  secret_id = google_secret_manager_secret.sum_staging.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:iyi-sum@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "sum_production" {
  count     = var.production_namespace_ready ? 1 : 0
  secret_id = google_secret_manager_secret.sum_production[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:iyi-sum@${var.project_id}.iam.gserviceaccount.com"
}

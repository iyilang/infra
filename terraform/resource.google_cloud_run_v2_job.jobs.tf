resource "google_cloud_run_v2_job" "jobs" {
  for_each            = local.enabled_jobs
  project             = var.project_id
  name                = each.key
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = data.google_service_account.runtime[each.value].email

      containers {
        image = var.service_images[each.key]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          for_each = each.key == "iyi-ingest" ? [1] : []
          content {
            name  = "PROXY_BUCKET"
            value = data.google_storage_bucket.objects["proxy"].name
          }
        }

        dynamic "env" {
          for_each = each.key == "iyi-sum-sequencer" ? [1] : []
          content {
            name  = "SUMDB_BUCKET"
            value = data.google_storage_bucket.objects[var.production_namespace_ready ? "sum-production" : "sum-staging"].name
          }
        }

        dynamic "env" {
          for_each = each.key == "iyi-sum-sequencer" ? [1] : []
          content {
            name  = "SUMDB_KEY_NAME"
            value = var.production_namespace_ready ? var.production_sumdb_key_name : "sum-staging.iyi.dev"
          }
        }

        dynamic "env" {
          for_each = each.key == "iyi-sum-sequencer" ? [1] : []
          content {
            name  = "SUMDB_SIGNING_KEY_SECRET"
            value = var.production_namespace_ready ? data.google_secret_manager_secret.sum_production[0].secret_id : data.google_secret_manager_secret.sum_staging.secret_id
          }
        }
      }
    }
  }

  depends_on = [google_project_service.iyi["run.googleapis.com"]]
}
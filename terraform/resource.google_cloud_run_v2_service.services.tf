resource "google_cloud_run_v2_service" "services" {
  for_each            = local.enabled_services
  project             = var.project_id
  name                = each.key
  location            = var.region
  ingress             = each.value.ingress
  deletion_protection = false

  scaling {
    min_instance_count = 0
    max_instance_count = each.value.max_instances
  }

  template {
    service_account = "${each.value.account}@${var.project_id}.iam.gserviceaccount.com"
    timeout         = "60s"

    containers {
      image = var.service_images[each.key]

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "PUBLIC_BASE_URL"
        value = lookup(var.public_base_urls, each.value.site, google_firebase_hosting_site.sites[each.value.site].default_url)
      }

      dynamic "env" {
        for_each = each.key == "iyi-sum" ? [1] : []
        content {
          name  = "SUMDB_KEY_NAME"
          value = var.production_namespace_ready ? var.production_sumdb_key_name : "sum-staging.iyi.dev"
        }
      }

      dynamic "env" {
        for_each = each.key == "iyi-proxy" ? [1] : []
        content {
          name  = "PROXY_BUCKET"
          value = google_storage_bucket.objects["proxy"].name
        }
      }

      dynamic "env" {
        for_each = each.key == "iyi-sum" ? [1] : []
        content {
          name  = "SUMDB_BUCKET"
          value = google_storage_bucket.objects[var.production_namespace_ready ? "sum-production" : "sum-staging"].name
        }
      }

      dynamic "env" {
        for_each = each.key == "iyi-sum" ? [1] : []
        content {
          name  = "SUMDB_SIGNING_KEY_SECRET"
          value = var.production_namespace_ready ? google_secret_manager_secret.sum_production[0].secret_id : google_secret_manager_secret.sum_staging.secret_id
        }
      }
    }
  }

  depends_on = [
    google_storage_bucket_iam_member.read_objects,
    google_storage_bucket_iam_member.create_objects,
    google_secret_manager_secret_version.sum_staging,
    google_secret_manager_secret_iam_member.sum_staging,
    google_secret_manager_secret_iam_member.sum_production,
  ]
}

# Binding a service requires setIamPolicy on that service. The bootstrap must
# not grant that permission project-wide; see the privilege boundary in COST.
resource "google_cloud_run_v2_service_iam_member" "public_invocation" {
  for_each = google_cloud_run_v2_service.services
  project  = var.project_id
  location = var.region
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

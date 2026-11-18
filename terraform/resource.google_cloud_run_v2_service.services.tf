resource "google_cloud_run_v2_service" "services" {
  for_each             = local.enabled_services
  project              = var.project_id
  name                 = each.key
  location             = var.region
  ingress              = each.value.ingress
  invoker_iam_disabled = true
  deletion_protection  = false

  scaling {
    min_instance_count = 0
    max_instance_count = each.value.max_instances
  }

  template {
    service_account = data.google_service_account.runtime[each.value.account].email
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
          value = data.google_storage_bucket.objects["proxy"].name
        }
      }

      dynamic "env" {
        for_each = each.key == "iyi-sum" ? [1] : []
        content {
          name  = "SUMDB_BUCKET"
          value = data.google_storage_bucket.objects[var.production_namespace_ready ? "sum-production" : "sum-staging"].name
        }
      }
    }
  }

  depends_on = [google_project_service.iyi["run.googleapis.com"]]
}

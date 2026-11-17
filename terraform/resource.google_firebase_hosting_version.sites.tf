resource "google_firebase_hosting_version" "sites" {
  provider = google-beta
  for_each = google_firebase_hosting_site.sites
  site_id  = each.value.site_id

  config {
    headers {
      glob    = "/"
      headers = { "X-Robots-Tag" = "noindex, nofollow" }
    }
    headers {
      glob    = "**"
      headers = { "X-Robots-Tag" = "noindex, nofollow" }
    }

    dynamic "rewrites" {
      for_each = each.key != "iyi-probe" && contains(keys(google_cloud_run_v2_service.services), each.key) ? [each.key] : []
      content {
        glob = "**"
        run {
          service_id = google_cloud_run_v2_service.services[rewrites.value].name
          region     = var.region
        }
      }
    }

    dynamic "rewrites" {
      for_each = each.key == "iyi-probe" ? {
        for service, glob in { iyi-probe-public = "/public/**", iyi-probe-internal = "/internal/**" } : service => glob
        if contains(keys(google_cloud_run_v2_service.services), service)
      } : {}
      content {
        glob = rewrites.value
        run {
          service_id = google_cloud_run_v2_service.services[rewrites.key].name
          region     = var.region
        }
      }
    }
  }
}

resource "google_firebase_hosting_release" "sites" {
  provider     = google-beta
  for_each     = google_firebase_hosting_version.sites
  site_id      = google_firebase_hosting_site.sites[each.key].site_id
  version_name = each.value.name
  message      = "Configure temporary Hosting site"
}

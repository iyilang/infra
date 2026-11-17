resource "google_firebase_hosting_site" "sites" {
  provider        = google-beta
  for_each        = local.sites
  project         = var.project_id
  site_id         = each.value
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_firebase_hosting_custom_domain" "sites" {
  provider              = google-beta
  for_each              = var.custom_domains_enabled ? local.custom_domains : {}
  project               = var.project_id
  site_id               = google_firebase_hosting_site.sites[each.key].site_id
  custom_domain         = each.value
  wait_dns_verification = false
  deletion_policy       = "PREVENT"
}

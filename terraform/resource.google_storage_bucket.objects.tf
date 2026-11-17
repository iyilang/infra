resource "google_storage_bucket" "objects" {
  for_each                    = toset(concat(["proxy", "sum-staging"], var.production_namespace_ready ? ["sum-production"] : []))
  project                     = var.project_id
  name                        = "iyi-${var.project_id}-${each.key}-objects"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning { enabled = true }
  lifecycle { prevent_destroy = true }
}

resource "google_storage_bucket_iam_member" "read_objects" {
  for_each = google_storage_bucket.objects
  bucket   = each.value.name
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:iyi-${each.key == "proxy" ? "proxy" : "sum"}@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "create_objects" {
  for_each = google_storage_bucket.objects
  bucket   = each.value.name
  role     = "roles/storage.objectCreator"
  member   = "serviceAccount:iyi-${each.key == "proxy" ? "proxy" : "sum"}@${var.project_id}.iam.gserviceaccount.com"
}

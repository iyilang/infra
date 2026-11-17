data "google_storage_bucket" "objects" {
  for_each = toset(concat(["proxy", "sum-staging"], var.production_namespace_ready ? ["sum-production"] : []))
  project  = var.project_id
  name     = "iyi-${var.project_id}-${each.key}-objects"
}

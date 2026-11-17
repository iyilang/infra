data "google_secret_manager_secret" "sum_staging" {
  project   = var.project_id
  secret_id = "iyi-sum-staging-signing-key"
}

data "google_secret_manager_secret" "sum_production" {
  count     = var.production_namespace_ready ? 1 : 0
  project   = var.project_id
  secret_id = "iyi-sum-production-signing-key"
}

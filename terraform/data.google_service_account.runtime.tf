data "google_service_account" "runtime" {
  for_each = toset([
    "iyi-proxy",
    "iyi-sum-reader",
    "iyi-sum-sequencer",
    "iyi-ingest",
    "iyi-probe",
  ])

  project    = var.project_id
  account_id = each.value
}

# This exclusion affects only the named iyi Cloud Run services, never other services.
# Project-wide exclusion permissions are deliberately not granted to CI until
# the privilege boundary has been resolved and reviewed.
resource "google_logging_project_exclusion" "request_logs" {
  project     = var.project_id
  name        = "iyi-successful-request-logs"
  description = "Exclude successful request logs for the iyi stack"
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=~\"^iyi-(proxy|sum|probe-public|probe-internal)$\" AND log_id(\"run.googleapis.com/requests\") AND severity<ERROR"
}

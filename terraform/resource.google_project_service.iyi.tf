# The Firebase and Hosting APIs already exist in this project and stay outside
# this state. Bootstrap enables the services it needs before CI can authenticate;
# these declarations keep the required APIs enabled without disabling them on
# destroy or removing the existing Firebase project.
resource "google_project_service" "iyi" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
    "sts.googleapis.com",
    "cloudbilling.googleapis.com",
    "billingbudgets.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

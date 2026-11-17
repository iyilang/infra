data "google_project" "current" {
  project_id = var.project_id
}

resource "google_billing_budget" "iyi" {
  billing_account = var.billing_account
  display_name    = "iyi stack monthly alert"
  deletion_policy = "PREVENT"

  budget_filter {
    projects        = ["projects/${data.google_project.current.number}"]
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "200"
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
}

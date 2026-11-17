locals {
  sites = toset(["iyi-proxy", "iyi-sum", "iyi-newsletter", "iyi-probe"])

  # Only explicitly supplied, nonempty images are deployed. The newsletter also
  # needs a separately provisioned DATABASE_URL secret before it can start.
  service_definitions = {
    iyi-proxy          = { site = "iyi-proxy", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 2, account = "iyi-proxy" }
    iyi-sum            = { site = "iyi-sum", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 2, account = "iyi-sum" }
    iyi-newsletter     = { site = "iyi-newsletter", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 1, account = "iyi-newsletter" }
    iyi-probe-public   = { site = "iyi-probe", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 1, account = "iyi-probe" }
    iyi-probe-internal = { site = "iyi-probe", ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER", max_instances = 1, account = "iyi-probe" }
  }

  enabled_services = {
    for name, service in local.service_definitions : name => service
    if try(length(trimspace(var.service_images[name])) > 0, false) && (name != "iyi-newsletter" || var.newsletter_database_secret_id != "")
  }

  custom_domains = {
    iyi-proxy      = "proxy.iyi.dev"
    iyi-sum        = "sum.iyi.dev"
    iyi-newsletter = "newsletter.iyi.dev"
  }
}

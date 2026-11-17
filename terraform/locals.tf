locals {
  sites = toset(["iyi-proxy", "iyi-sum", "iyi-probe"])

  # Only explicitly supplied, nonempty images are deployed.
  service_definitions = {
    iyi-proxy          = { site = "iyi-proxy", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 2, account = "iyi-proxy" }
    iyi-sum            = { site = "iyi-sum", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 2, account = "iyi-sum" }
    iyi-probe-public   = { site = "iyi-probe", ingress = "INGRESS_TRAFFIC_ALL", max_instances = 1, account = "iyi-probe" }
    iyi-probe-internal = { site = "iyi-probe", ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER", max_instances = 1, account = "iyi-probe" }
  }

  enabled_services = {
    for name, service in local.service_definitions : name => service
    if try(length(trimspace(var.service_images[name])) > 0, false)
  }

  custom_domains = {
    iyi-proxy = "proxy.iyi.dev"
    iyi-sum   = "sum.iyi.dev"
  }
}

output "hosting_urls" {
  description = "The two temporary Firebase hostnames for each Hosting site."
  value = {
    for id, site in google_firebase_hosting_site.sites : id => {
      web_app     = site.default_url
      firebaseapp = "https://${site.site_id}.firebaseapp.com"
    }
  }
}

output "custom_domain_dns_updates" {
  description = "Firebase-provided DNS changes for custom domains after cutover is enabled."
  value       = { for site, domain in google_firebase_hosting_custom_domain.sites : site => domain.required_dns_updates }
}

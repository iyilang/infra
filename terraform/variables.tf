variable "project_id" {
  description = "Existing Google Cloud project."
  type        = string
  nullable    = false
  default     = "iyi-lang"
  validation {
    condition     = var.project_id == "iyi-lang"
    error_message = "This root only manages the iyi-lang project."
  }
}

variable "region" {
  description = "Region for Cloud Run services and the image repository."
  type        = string
  nullable    = false
  default     = "us-central1"
}

variable "billing_account" {
  description = "Cloud Billing account ID, supplied by the maintainers rather than committed."
  type        = string
  sensitive   = true
  nullable    = false
}

variable "service_images" {
  description = "Published container image for each enabled Cloud Run service. No bootstrap image is assumed."
  type        = map(string)
  nullable    = false
  default     = {}
}

variable "public_base_urls" {
  description = "Overrides of externally visible base URLs, keyed by site ID. Omitted entries use their Hosting URL."
  type        = map(string)
  nullable    = false
  default     = {}
}

variable "custom_domains_enabled" {
  description = "Create the custom Hosting domain associations for the namespace cutover."
  type        = bool
  default     = false
}

variable "production_namespace_ready" {
  description = "Permit a production checksum signing-key secret after the permanent key name has been chosen."
  type        = bool
  default     = false
}

variable "production_sumdb_key_name" {
  description = "Permanent checksum signing-key name, selected before any production checkpoint is signed."
  type        = string
  default     = ""
  validation {
    condition     = !var.production_namespace_ready || var.production_sumdb_key_name != ""
    error_message = "Choose the permanent production sumdb key name before enabling the production namespace."
  }
}

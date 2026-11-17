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

variable "service_images" {
  description = "Published container images keyed by Cloud Run service or job name. Omitted or empty entries are not deployed."
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
    condition     = !var.production_namespace_ready || length(trimspace(var.production_sumdb_key_name)) > 0
    error_message = "Choose the permanent production sumdb key name before enabling the production namespace."
  }
}

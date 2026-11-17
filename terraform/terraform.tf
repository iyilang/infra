terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  backend "gcs" {
    bucket = "iyi-lang-tfstate"
    prefix = "iyi"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.11"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.11"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
  }
}

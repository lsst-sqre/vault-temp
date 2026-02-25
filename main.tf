terraform {
  required_version = "~> 1.14.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.21"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.21"
    }
  }
}

variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "service_account" {
  type = string
}

variable "vault_domain" {
  type = string
}

variable "storage_bucket" {
  type = string
}

variable "vault_image_tag" {
  type = string
}

provider "google" {
  project = var.project
  region  = var.region
}

provider "google-beta" {
  project = var.project
  region  = var.region
}

locals {
  service_name = "vault-temp"
  description  = "For the temporary Vault instance"
}

resource "google_cloud_run_v2_service" "vault_temp" {
  name                 = local.service_name
  description          = "A temporary vault instance to use while the real vault instance is down for maintenance"
  location             = var.region
  deletion_protection  = false
  invoker_iam_disabled = true

  scaling {
    min_instance_count = 1
    max_instance_count = 1
  }

  template {
    service_account = var.service_account

    containers {
      image = "hashicorp/vault:${var.vault_image_tag}"
      command = [
        "/usr/local/bin/docker-entrypoint.sh",
        "server"
      ]

      env {
        name  = "VAULT_API_ADDR"
        value = "https://${var.vault_domain}"
      }

      env {
        name  = "VAULT_LOCAL_CONFIG"
        value = <<-EOT
          {"ui": true, "listener": {"tcp": {"tls_disable": 1, "address": "[::]:8200", "cluster_address": "[::]:8201"}}, "seal": {"gcpckms": {"project": "${var.project}", "region": "${var.region}", "key_ring": "vault-server", "crypto_key": "vault-seal"}}, "storage": {"gcs": {"bucket": "${var.storage_bucket}" }}}
        EOT
      }

      resources {
        limits = {
          memory = "2G"
          cpu    = "1"
        }
      }

      ports {
        container_port = 8200
      }
    }
  }
}

# Oh Cloud Run is so easy! Just one resource and your service is running and
# managed! Just kidding, here are 11 resources to point a domain at it >:-(
# https://docs.cloud.google.com/load-balancing/docs/https/setup-global-ext-https-serverless
resource "google_compute_global_address" "service" {
  name         = local.service_name
  description  = "For temporary vault instance"
  address_type = "EXTERNAL"
}

output "ip_address" {
  description = "Point the vault domain at this address when you're ready to use this temp instance."
  value       = google_compute_global_address.service.address
}

resource "google_certificate_manager_dns_authorization" "service" {
  name        = local.service_name
  description = local.description
  domain      = var.vault_domain
  type        = "PER_PROJECT_RECORD"
}

resource "google_certificate_manager_certificate" "service" {
  name        = local.service_name
  description = "Certificate for temporary vault instance"

  managed {
    domains = [
      google_certificate_manager_dns_authorization.service.domain,
    ]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.service.id,
    ]
  }
}

# We need this map because:
# https://github.com/hashicorp/terraform-provider-google/issues/17176
resource "google_certificate_manager_certificate_map" "service" {
  name        = local.service_name
  description = local.description
}

resource "google_certificate_manager_certificate_map_entry" "service" {
  name         = local.service_name
  description  = local.description
  map          = google_certificate_manager_certificate_map.service.name
  certificates = [google_certificate_manager_certificate.service.id]
  matcher      = "PRIMARY"
}

output "cert_dns" {
  description = "Configure these DNS records to verify the temporary vault instance's TLS certificate."
  value       = google_certificate_manager_dns_authorization.service.dns_resource_record
}

resource "google_compute_region_network_endpoint_group" "service" {
  name                  = local.service_name
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  project               = var.project

  cloud_run {
    service = google_cloud_run_v2_service.vault_temp.name
  }
}

resource "google_compute_backend_service" "service" {
  name                  = local.service_name
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.service.id
  }
}

resource "google_compute_url_map" "service" {
  name            = local.service_name
  description     = local.description
  default_service = google_compute_backend_service.service.id
}

# We need to specify a map instead of an individual certificate because:
# https://github.com/hashicorp/terraform-provider-google/issues/17176
resource "google_compute_target_https_proxy" "service" {
  name            = local.service_name
  url_map         = google_compute_url_map.service.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.service.id}"
}

resource "google_compute_global_forwarding_rule" "service" {
  name                  = local.service_name
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.service.id
  target                = google_compute_target_https_proxy.service.id
  port_range            = "443"
}

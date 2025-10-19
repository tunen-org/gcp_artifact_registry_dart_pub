terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Variables
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "europe-west1"
}

variable "service_name" {
  description = "Cloud Run service name"
  type        = string
  default     = "pub-api"
}

variable "artifact_repo_name" {
  description = "Artifact Registry repository name for Docker images"
  type        = string
  default     = "docker-image-repository"
}

variable "github_repo" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
}

variable "github_branch" {
  description = "GitHub branch to trigger builds"
  type        = string
  default     = "main"
}

variable "pub_repo_location" {
  description = "Location of the Pub package repository in Artifact Registry"
  type        = string
  default     = "europe-west1"
}

variable "pub_repo_name" {
  description = "Name of the Pub package repository in Artifact Registry"
  type        = string
  default     = "dart-package-repository"
}

# Enable required APIs
resource "google_project_service" "required_apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# Create Artifact Registry repository for Docker images
resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = var.artifact_repo_name
  description   = "Docker repository for Cloud Run images"
  format        = "DOCKER"

  depends_on = [google_project_service.required_apis]
}

# Service Account for Cloud Run
resource "google_service_account" "cloud_run_sa" {
  account_id   = "${var.service_name}-sa"
  display_name = "Service Account for ${var.service_name} Cloud Run service"
}

# Grant Cloud Run SA permissions to access Artifact Registry
resource "google_project_iam_member" "cloud_run_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Grant Cloud Run SA permissions to write to Artifact Registry (for the Pub API functionality)
resource "google_project_iam_member" "cloud_run_artifact_registry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Service Account for Cloud Build
resource "google_service_account" "cloud_build_sa" {
  account_id   = "cloud-build-${var.service_name}"
  display_name = "Service Account for Cloud Build - ${var.service_name}"
}

# Grant Cloud Build SA permissions
resource "google_project_iam_member" "cloud_build_permissions" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/run.admin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# GitHub connection for Cloud Build (requires manual setup in Console first)
# After running terraform, you'll need to manually connect your GitHub repo in the Cloud Build UI
resource "google_cloudbuild_trigger" "github_trigger" {
  name        = "${var.service_name}-deploy"
  description = "Deploy ${var.service_name} on push to ${var.github_branch}"
  
  service_account = google_service_account.cloud_build_sa.id

  github {
    owner = split("/", var.github_repo)[0]
    name  = split("/", var.github_repo)[1]
    push {
      branch = "^${var.github_branch}$"
    }
  }

  filename = "cloudbuild-cd.yaml"

  substitutions = {
    _SERVICE_NAME   = var.service_name
    _REGION         = var.region
    _ARTIFACT_REPO  = var.artifact_repo_name
  }

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.docker_repo,
  ]
}

# Cloud Run Service
resource "google_cloud_run_v2_service" "service" {
  name     = var.service_name
  location = var.region

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      # Initial placeholder image - will be replaced by Cloud Build
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/${var.service_name}:latest"

      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GCP_LOCATION"
        value = var.pub_repo_location
      }
      env {
        name  = "GCP_REPOSITORY"
        value = var.pub_repo_name
      }
      env {
        name  = "PORT"
        value = "8080"
      }

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.docker_repo,
  ]

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image, # Managed by Cloud Build
    ]
  }
}

# Outputs
output "cloud_run_url" {
  description = "URL of the deployed Cloud Run service"
  value       = google_cloud_run_v2_service.service.uri
}

output "cloud_run_service_account" {
  description = "Service account email for Cloud Run"
  value       = google_service_account.cloud_run_sa.email
}

output "cloud_build_service_account" {
  description = "Service account email for Cloud Build"
  value       = google_service_account.cloud_build_sa.email
}

output "docker_repository" {
  description = "Artifact Registry Docker repository"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}"
}

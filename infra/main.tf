terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

data "google_project" "current" {
  project_id = var.project_id
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type    = string
  default = "cloud-portfolio-789"
}

variable "region" {
  type    = string
  default = "us-central1"
}

# --- APIs -------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "firestore.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# --- Firestore ----------------------------------------------------------

resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.apis]
}

# --- Storage buckets ------------------------------------------------------

resource "google_storage_bucket" "uploads" {
  name                        = "${var.project_id}-uploads"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "thumbnails" {
  name                        = "${var.project_id}-thumbnails"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

# Thumbnails need to be publicly viewable through the API.
resource "google_storage_bucket_iam_member" "thumbnails_public_read" {
  bucket = google_storage_bucket.thumbnails.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# --- Service accounts (least privilege) ------------------------------------

resource "google_service_account" "process_photo" {
  project      = var.project_id
  account_id   = "process-photo-fn"
  display_name = "process-photo Cloud Function"
}

resource "google_storage_bucket_iam_member" "process_photo_reads_uploads" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.process_photo.email}"
}

resource "google_storage_bucket_iam_member" "process_photo_writes_thumbnails" {
  bucket = google_storage_bucket.thumbnails.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.process_photo.email}"
}

resource "google_project_iam_member" "process_photo_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.process_photo.email}"
}

resource "google_service_account" "images_api" {
  project      = var.project_id
  account_id   = "images-api-run"
  display_name = "images API Cloud Run service"
}

resource "google_project_iam_member" "images_api_firestore" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  member  = "serviceAccount:${google_service_account.images_api.email}"
}

# --- Cloud Function (event-driven) ------------------------------------

resource "google_storage_bucket" "function_source" {
  name                        = "${var.project_id}-function-source"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

data "archive_file" "process_photo_source" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/.build/process-photo-source.zip"
  excludes    = ["venv", "test_local.py", "__pycache__"]
}

resource "google_storage_bucket_object" "process_photo_source" {
  name   = "process-photo-${data.archive_file.process_photo_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.process_photo_source.output_path
}

# Cloud Storage needs permission to publish upload events into Eventarc/Pub-Sub.
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "process_photo_eventarc" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.process_photo.email}"
}

resource "google_cloudfunctions2_function" "process_photo" {
  name     = "process-photo"
  project  = var.project_id
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "process_photo"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.process_photo_source.name
      }
    }
  }

  service_config {
    available_memory      = "256Mi"
    timeout_seconds       = 60
    service_account_email = google_service_account.process_photo.email
    environment_variables = {
      THUMBNAILS_BUCKET = google_storage_bucket.thumbnails.name
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.process_photo.email
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.uploads.name
    }
  }

  depends_on = [
    google_project_iam_member.gcs_pubsub_publisher,
    google_project_iam_member.process_photo_eventarc,
  ]
}

# The Eventarc trigger invokes the function's underlying Cloud Run service directly;
# eventReceiver alone isn't enough, it also needs run.invoker on that specific service.
resource "google_cloud_run_v2_service_iam_member" "process_photo_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.process_photo.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.process_photo.email}"
}

# --- Cloud Run API ------------------------------------------------------

resource "google_artifact_registry_repository" "images_api" {
  project       = var.project_id
  location      = var.region
  repository_id = "images-api"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service" "images_api" {
  project  = var.project_id
  name     = "images-api"
  location = var.region

  template {
    service_account = google_service_account.images_api.email

    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/images-api/images-api:v1"

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
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
      max_instance_count = 2
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "images_api_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.images_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "images_api_url" {
  value = google_cloud_run_v2_service.images_api.uri
}

output "uploads_bucket" {
  value = google_storage_bucket.uploads.name
}

output "thumbnails_bucket" {
  value = google_storage_bucket.thumbnails.name
}

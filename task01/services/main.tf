variable "access_token" {
  type = string
}

variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "registry_id" {
  type = string
}

variable "user_id" {
  type = string
}

terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  token     = var.access_token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

# Create service account
resource "yandex_iam_service_account" "sa" {
  name        = "${var.user_id}-serverless-manager"
  description = "serverless manager service account"
  folder_id   = var.folder_id
}

# Assigning `serverless-containers.admin` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-serverless-containers-admin" {
  folder_id = var.folder_id
  role      = "serverless-containers.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Assigning `container-registry.images.pusher` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-container-registry-images-pusher" {
  folder_id = var.folder_id
  role      = "container-registry.images.pusher"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Assigning `ymq.admin` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-ymq-admin" {
  folder_id = var.folder_id
  role      = "ymq.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Creating a static access key
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "static access key for queue creation"
}

# Creating message broker `${var.user_id}-task`
resource "yandex_message_queue" "queue-task" {
  name                        = "${var.user_id}-task"
  visibility_timeout_seconds  = 600
  receive_wait_time_seconds   = 20
  message_retention_seconds   = 1209600
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

# Creating YDB `${var.user_id}-db-photo-face`
resource "yandex_ydb_database_serverless" "database" {
  name                = "${var.user_id}-db-photo-face"
  deletion_protection = true

  serverless_database {
    enable_throttling_rcu_limit = false
    provisioned_rcu_limit       = 10
    storage_size_limit          = 10
    throttling_rcu_limit        = 0
  }
}

# Creating face-detection serverless container
resource "yandex_serverless_container" "face-detection" {
   name               = "${var.user_id}-face-detection"
   memory             = 128
   service_account_id = yandex_iam_service_account.sa.id
   image {
       url = "cr.yandex/${var.registry_id}/face-detection:latest"
       environment = {
          BROKER_URL = yandex_message_queue.queue-task.id
       }
   }
}

# Creating face-cut serverless container
resource "yandex_serverless_container" "face-cut" {
   name               = "${var.user_id}-face-cut"
   memory             = 128
   service_account_id = yandex_iam_service_account.sa.id
   image {
       url = "cr.yandex/${var.registry_id}/face-cut:latest"
       environment = {
          DB_URL = yandex_ydb_database_serverless.database.ydb_full_endpoint
       }
   }
}

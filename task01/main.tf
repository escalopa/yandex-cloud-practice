variable "access_token" {
  type = string
}

variable "cloud_id" {
  type = string
}

variable "folder_id" {
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

# Create `bucket-manager` service account
resource "yandex_iam_service_account" "sa" {
  name        = "bucket-manager"
  description = "bucket manager service account"
  folder_id   = var.folder_id
}

# Assigning `storage.admin` to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-storage-admin" {
  folder_id = var.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Creating a static access key
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "static access key for object storage"
}

# Creating bucket `${var.user_id}-photos`
resource "yandex_storage_bucket" "bucket-photos" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = "${var.user_id}-photos"
}

# Creating bucket `${var.user_id}-faces`
resource "yandex_storage_bucket" "bucket-faces" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = "${var.user_id}-faces"
}

# Creating containers image registry
resource "yandex_container_registry" "registry" {
  name = "${var.user_id}-registry"
  folder_id = var.folder_id
}

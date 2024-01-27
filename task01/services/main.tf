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

######################################################
####### MESSAGE QUEUE
######################################################

# Create queue service account
resource "yandex_iam_service_account" "sa-queue" {
  name        = "${var.user_id}-queue-manager"
  description = "queue manager service account"
  folder_id   = var.folder_id
}

# Assigning `ymq.admin` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-ymq-admin" {
  folder_id = var.folder_id
  role      = "ymq.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa-queue.id}"
}

# Creating a static access key
resource "yandex_iam_service_account_static_access_key" "sa-queue-static-key" {
  service_account_id = yandex_iam_service_account.sa-queue.id
  description        = "static access key for queue creation"
}

# Creating message broker `${var.user_id}-task`
resource "yandex_message_queue" "queue-task" {
  name                        = "${var.user_id}-task"
  visibility_timeout_seconds  = 600
  receive_wait_time_seconds   = 20
  message_retention_seconds   = 1209600
  access_key = yandex_iam_service_account_static_access_key.sa-queue-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-queue-static-key.secret_key
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

output "sa_queue_id" {
    value = "${yandex_iam_service_account.sa-queue.id}"
}

output "queue_id" {
    value = "${yandex_message_queue.queue-task.arn}"
}

#######################################################################
####### CLOUD FUNCTIONS
#######################################################################

# Create cloud function manager service account
resource "yandex_iam_service_account" "sa-function" {
  name        = "${var.user_id}-function-manager"
  description = "function manager service account"
  folder_id   = var.folder_id
}

# Assigning `ai.vision.user` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-functions-ai-vision-user" {
  folder_id = var.folder_id
  role      = "ai.vision.user"
  member    = "serviceAccount:${yandex_iam_service_account.sa-function.id}"
}

# Assigning `storage.viewer` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-functions-storage-viewer" {
  folder_id = var.folder_id
  role      = "storage.viewer"
  member    = "serviceAccount:${yandex_iam_service_account.sa-function.id}"
}

# Assigning `ymq.writer` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-ymq-writer" {
  folder_id = var.folder_id
  role      = "ymq.writer"
  member    = "serviceAccount:${yandex_iam_service_account.sa-function.id}"
}

# Assigning `functions.functionInvoker` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-functions-functionInvoker" {
  folder_id = var.folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.sa-function.id}"
}

# Assigning `functions.editor` role to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-functions-functions-editor" {
  folder_id = var.folder_id
  role      = "functions.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa-function.id}"
}

# Creating a static access key
resource "yandex_iam_service_account_static_access_key" "sa-functions-static-key" {
  service_account_id = yandex_iam_service_account.sa-function.id
  description        = "static access key for object storage"
}

resource "yandex_function" "face-detection" {
    name               = "${var.user_id}-face-detection"
    description        = "face detection function"
    user_hash          = "face-detection"
    runtime            = "golang121"
    entrypoint         = "main.Handler"
    memory             = "128"
    execution_timeout  = "10"
    service_account_id = yandex_iam_service_account.sa-function.id
    tags               = ["latest"]
    environment = {
        "AWS_SESSION_TOKEN" = var.access_token
        "FOLDER_ID" = var.folder_id
        "QUEUE_URL" = yandex_message_queue.queue-task.id
        "AWS_ACCESS_KEY_ID" =  yandex_iam_service_account_static_access_key.sa-functions-static-key.access_key
        "AWS_SECRET_ACCESS_KEY" =  yandex_iam_service_account_static_access_key.sa-functions-static-key.secret_key
    }
    content {
        zip_filename = "./face-detection/main.zip"
    }
}

output "sa_function_id" {
    value = "${yandex_iam_service_account.sa-function.id}"
}

output "function_face_detection_id" {
    value = "${yandex_function.face-detection.id}"
}

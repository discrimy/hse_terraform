terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone = "ru-central1-a"
}

variable "folder_id" {
  type = string
}
variable "zone" {
  type = string
  default = "ru-central1-a"
}

resource "yandex_vpc_network" "network1" {
  name = "network1"
}
resource "yandex_vpc_subnet" "netwrok1-subnet1" {
  name = "network1-subnet1"
  network_id = yandex_vpc_network.network1.id
  zone = var.zone
  v4_cidr_blocks = [ "192.168.10.0/24" ]
}

data "yandex_compute_image" "ubuntu-2204-lts" {
    family = "ubuntu-2204-lts"
}
resource "yandex_compute_disk" "boot_disk" {
  name = "boot-disk"
  zone = var.zone
  image_id = data.yandex_compute_image.ubuntu-2204-lts.image_id
  size = 10
}
resource "yandex_compute_instance" "vm" {
  name = "scraper-vm"
  zone = var.zone

  resources {
    cores = 2
    memory = 2
  }
  boot_disk {
    disk_id = yandex_compute_disk.boot_disk.id
  }
  network_interface {
    subnet_id = yandex_vpc_subnet.netwrok1-subnet1.id
    nat = true
  }
  metadata = {
    ssh-keys = "admin:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "yandex_ydb_database_serverless" "db" {
  name = "ydb-serverless"
}

resource "yandex_iam_service_account" "sa-bucket" {
  name = "sa-bucket"
}
resource "yandex_resourcemanager_folder_iam_member" "storage_editor" {
  folder_id = var.folder_id
  role = "storage.editor"
  member = "serviceAccount:${yandex_iam_service_account.sa-bucket.id}"
}
resource "yandex_iam_service_account_static_access_key" "sa-bucket-key" {
  service_account_id = yandex_iam_service_account.sa-bucket.id
}

resource "yandex_storage_bucket" "bucket" {
  bucket = "terraform-bucket-${random_string.bucket_name.result}"
  access_key = yandex_iam_service_account_static_access_key.sa-bucket-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-bucket-key.secret_key

  depends_on = [ yandex_resourcemanager_folder_iam_member.storage_editor ]
}

resource "random_string" "bucket_name" {
  length = 8
  special = false
  upper = false
}

output "vm-ip" {
  value = yandex_compute_instance.vm.network_interface.0.nat_ip_address
}
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
variable "scapers-count" {
  type = number
  default = 3
}

resource "yandex_vpc_network" "network1" {
  name = "network1"
}
resource "yandex_vpc_subnet" "network1-subnet1" {
  name = "network1-subnet1"
  network_id = yandex_vpc_network.network1.id
  zone = var.zone
  v4_cidr_blocks = [ "192.168.10.0/24" ]
}

data "yandex_compute_image" "ubuntu-2204-lts" {
    family = "ubuntu-2204-lts"
}
resource "yandex_compute_disk" "boot_disk" {
  count = var.scapers-count

  name = "boot-disk-${count.index}"
  zone = var.zone
  image_id = data.yandex_compute_image.ubuntu-2204-lts.image_id
  size = 10
}
resource "yandex_compute_instance" "vm" {
  count = var.scapers-count

  name = "scraper-vm-${count.index}"
  zone = var.zone

  resources {
    cores = 2
    memory = 2
  }
  boot_disk {
    disk_id = yandex_compute_disk.boot_disk[count.index].id
  }
  network_interface {
    subnet_id = yandex_vpc_subnet.network1-subnet1.id
    nat = true
  }
  metadata = {
    user-data = data.template_file.vm-meta.rendered
  }
}
data "template_file" "vm-meta" {
  template = file("${path.module}/meta.txt.tftpl")
  vars = {
    scraper_ssh_public_key = "${file("~/.ssh/id_rsa.pub")}"
    db_connection_string = "postgres://${yandex_mdb_postgresql_user.scraper.name}:${yandex_mdb_postgresql_user.scraper.password}@${yandex_mdb_postgresql_cluster.postgres-cluster.host[0].fqdn}:6432/${yandex_mdb_postgresql_database.postgres-db.name}"
    redis_url = "redis://:${yandex_mdb_redis_cluster.redis-cluster.config[0].password}@${yandex_mdb_redis_cluster.redis-cluster.host[0].fqdn}/0"
  }
}

resource "yandex_mdb_postgresql_cluster" "postgres-cluster" {
  name        = "scraper"
  environment = "PRESTABLE"
  network_id  = yandex_vpc_network.network1.id

  config {
    version = 17
    resources {
      resource_preset_id = "s2.micro"
      disk_type_id       = "network-ssd"
      disk_size          = 16
    }
  }

  maintenance_window {
    type = "WEEKLY"
    day  = "SAT"
    hour = 12
  }

  host {
    zone      = var.zone
    subnet_id = yandex_vpc_subnet.network1-subnet1.id
  }
}
resource "yandex_mdb_postgresql_database" "postgres-db" {
  cluster_id = yandex_mdb_postgresql_cluster.postgres-cluster.id
  name       = "scraper"
  owner      = yandex_mdb_postgresql_user.scraper.name
  lc_collate = "en_US.UTF-8"
  lc_type    = "en_US.UTF-8"
}
resource "yandex_mdb_postgresql_user" "scraper" {
  cluster_id = yandex_mdb_postgresql_cluster.postgres-cluster.id
  name       = "scraper"
  password   = random_password.db-scraper-password.result
}
resource "random_password" "db-scraper-password" {
  length = 16
  special = false
}

resource "yandex_mdb_redis_cluster" "redis-cluster" {
  name = "redis-cluster"
  environment = "PRODUCTION"
  network_id = yandex_vpc_network.network1.id

  config {
    version = "7.2"
    password = random_password.redis-password.result
  }

  resources {
    resource_preset_id = "hm1.nano"
    disk_size = 16
  }

  host {
    zone = var.zone
    subnet_id = yandex_vpc_subnet.network1-subnet1.id
  }

  maintenance_window {
    type = "ANYTIME"
  }
}
resource "random_password" "redis-password" {
  length = 8
  special = false
  upper = false
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

output "vm-ips" {
  value = yandex_compute_instance.vm[*].network_interface.0.nat_ip_address
}
output "db-connection-string" {
  value = "postgres://${yandex_mdb_postgresql_user.scraper.name}:${yandex_mdb_postgresql_user.scraper.password}@${yandex_mdb_postgresql_cluster.postgres-cluster.host[0].fqdn}:6432/${yandex_mdb_postgresql_database.postgres-db.name}"
  sensitive = true
}
output "redis-connection-string" {
  value = "redis://:${yandex_mdb_redis_cluster.redis-cluster.config[0].password}@${yandex_mdb_redis_cluster.redis-cluster.host[0].fqdn}/0"
  sensitive = true
}

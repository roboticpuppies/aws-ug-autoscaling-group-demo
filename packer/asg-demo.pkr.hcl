packer {
  required_version = ">= 1.9.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name_prefix" {
  type    = string
  default = "asg-demo"
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
  ami_name  = "${var.name_prefix}-${local.timestamp}"
}

# Resolved at build time, not at validate time. A data source here would make
# `packer validate` require AWS credentials.
source "amazon-ebs" "al2023" {
  region        = var.region
  instance_type = "t4g.micro"
  ssh_username  = "ec2-user"
  ami_name      = local.ami_name

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-arm64"
      architecture        = "arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  tags = {
    Name      = local.ami_name
    Project   = "Demo"
    BuildTime = local.timestamp
  }

  snapshot_tags = {
    Name    = local.ami_name
    Project = "Demo"
  }
}

build {
  name    = "asg-demo"
  sources = ["source.amazon-ebs.al2023"]

  provisioner "shell" {
    script          = "${path.root}/scripts/provision.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}

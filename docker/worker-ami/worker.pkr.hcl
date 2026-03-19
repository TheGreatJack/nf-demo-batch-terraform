packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "profile" {
  type    = string
  default = "affc_prof"
}

source "amazon-ebs" "worker" {
  profile       = var.profile
  region        = var.region
  instance_type = "m5.large"

  source_ami_filter {
    filters = {
      name                = "al2023-ami-ecs-hvm-2023.0.*-kernel-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ami_name        = "nextflow-batch-worker-al2023-{{timestamp}}"
  ami_description = "AL2023 ECS-optimized + self-contained AWS CLI v2 at /opt/aws-cli (micromamba) for Nextflow Batch workers"
  ssh_username    = "ec2-user"

  tags = {
    Project   = "nf-core-demo"
    ManagedBy = "Packer"
    Purpose   = "nextflow-batch-worker"
  }
}

build {
  sources = ["source.amazon-ebs.worker"]

  provisioner "shell" {
    inline = [
      # Install micromamba — single static binary, needs bzip2 for tar extraction.
      "sudo dnf install -y bzip2 tar",
      "curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj -C /tmp bin/micromamba",

      # Create a self-contained conda env at /opt/aws-cli with AWS CLI v2.
      # conda-forge bundles Python, libz, libssl, and all other shared libs
      # inside the env, so it works when Nextflow bind-mounts it into containers.
      #
      # Path: /opt/aws-cli/bin/aws → grandparent /opt/aws-cli → safe for Nextflow
      # (won't shadow /usr, /usr/local, or any other container path).
      "sudo /tmp/bin/micromamba create -y -p /opt/aws-cli -c conda-forge awscli",

      # Smoke-test
      "/opt/aws-cli/bin/aws --version",

      # Clean up — micromamba binary and package cache are not needed in the AMI
      "rm -f /tmp/bin/micromamba",
      "sudo rm -rf /root/micromamba",
    ]
  }
}

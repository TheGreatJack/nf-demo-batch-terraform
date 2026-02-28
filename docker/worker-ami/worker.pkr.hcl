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
      name                = "amzn2-ami-ecs-hvm-*-x86_64-ebs"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ami_name             = "nextflow-batch-worker-{{timestamp}}"
  ami_description      = "Amazon Linux 2 ECS-optimized + AWS CLI (conda-bundled) for Nextflow Batch workers"
  ssh_username         = "ec2-user"

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
      # Install micromamba — a single static C++ binary that replaces the Python-based
      # conda solver. Much lighter on memory, resolves conda-forge packages without OOM.
      "curl -L micro.mamba.pm/install.sh | bash",

      # Create a conda environment at the target path with AWS CLI v2 from conda-forge.
      # conda-forge bundles Python + libz + libssl and all other required libs inside
      # the env, making it fully self-contained when Nextflow bind-mounts
      # /home/ec2-user/aws-cli into each worker container.
      # MAMBA_ROOT_PREFIX is set explicitly because Packer does not source .bashrc.
      "MAMBA_ROOT_PREFIX=/home/ec2-user/micromamba /home/ec2-user/.local/bin/micromamba create -y -p /home/ec2-user/aws-cli -c conda-forge awscli",

      # Smoke-test
      "/home/ec2-user/aws-cli/bin/aws --version",

      # Clean up — micromamba binary and package cache are not needed in the AMI
      "rm -rf /home/ec2-user/micromamba",
      "rm -f /home/ec2-user/.local/bin/micromamba",
    ]
  }
}

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket        = "onionomics-tfstate-630888660188-us-east-1"
    key           = "batch/terraform.tfstate"
    region        = "us-east-1"
    use_lockfile  = true
    encrypt       = true
    profile       = "Florian-sso-profile"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

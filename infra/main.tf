terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "onionomics-tfstate-399839194195-us-east-1"
    key            = "batch/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "onionomics-tfstate-lock"
    encrypt        = true
    profile        = "affc_prof"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state is fine for a portfolio project. If you move to S3 later, use native
  # locking (no DynamoDB needed on Terraform >= 1.10):
  #
  # backend "s3" {
  #   bucket       = "YOUR-EXISTING-STATE-BUCKET"   # must already exist
  #   key          = "ecs-cicd/terraform.tfstate"
  #   region       = "ca-west-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

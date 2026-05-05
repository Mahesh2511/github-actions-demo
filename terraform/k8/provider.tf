terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }

  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.region
}

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.21"
    }
  }
}

# Examples configure the provider; the module itself does not.
provider "aws" {}

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# No default_tags here on purpose. Auto Scaling group tag propagation behaves
# more predictably when tags are declared explicitly, so resources take their
# tags from local.tags instead.
provider "aws" {
  region = var.region
}

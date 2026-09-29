terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # -------------------------------------------------------------------------
  # REMOTE STATE — do this FIRST (see docs/RUNBOOK.md §2).
  # Use a SEPARATE state bucket + lock table per environment/account so a
  # stage apply can never touch prod. Fill via `-backend-config=env/<env>.hcl`.
  # -------------------------------------------------------------------------
  backend "s3" {
    # bucket         = "techblue-tfstate-<env>"      # from env/<env>.backend.hcl
    # key            = "onboarding/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "techblue-tflock-<env>"
    # encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
    }
  }
}

# CloudFront-scoped WAF must be created in us-east-1 regardless of var.region.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
    }
  }
}

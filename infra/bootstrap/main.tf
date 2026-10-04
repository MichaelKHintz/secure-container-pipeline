terraform {
    required_version = ">= 1.10"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
    }
}

provider "aws" {
    region = "us-west-2"
}

variable "state_bucket_name" {
    type = string
}

variable "budget_email" {
    type        = string
    sensitive   = true
}

resource "aws_s3_bucket" "tfstate" {
    bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id
    versioning_configuration {
        status = "Enabled"
    }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id
    rule {
        apply_server_side_encryption_by_default {
            sse_algorithm = "aws:kms"
        }
    }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
}

resource "aws_budgets_budget" "lab" {
    name            = "secure-container-pipeline"
    budget_type     = "COST"
    limit_amount    = "25"
    limit_unit      = "USD"
    time_unit       = "MONTHLY"

    notification {
        comparison_operator        = "GREATER_THAN"
        threshold                  = 50
        threshold_type             = "PERCENTAGE"
        notification_type          = "ACTUAL"
        subscriber_email_addresses = [var.budget_email]
    }

    notification {
        comparison_operator        = "GREATER_THAN"
        threshold                  = 100
        threshold_type             = "PERCENTAGE"
        notification_type          = "FORECASTED"
        subscriber_email_addresses = [var.budget_email]
    }
}

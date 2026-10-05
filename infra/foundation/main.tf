terraform {
    required_version = ">= 1.10"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
    }
    backend "s3" {
        key           = "secure-container-pipeline/foundation.tfstate"
        region        = "us-west-2"
        encrypt       = true
        use_lockfile  = true
    }
}

provider "aws" {
    region = "us-west-2"
    default_tags {
        tags = {
            project   = "secure-container-pipeline"
            lifecycle = "persistent"
        }
    }
}

variable "github_oidc_subject" {
    description = "Exact sub claim for main: repo:Owner@ownerId/secure-container-pipeline@repoId:ref:refs/heads/main"
    type        = string
}

#One customer-managed key for ECR images and EKS secrets
resource "aws_kms_key" "lab" {
    description             = "secure-container-pipeline: ECR images and EKS secrets"
    enable_key_rotation     = true
    deletion_window_in_days = 7
}

resource "aws_kms_alias" "lab" {
    name          = "alias/secure-container-pipeline"
    target_key_id = aws_kms_key.lab.key_id
}

resource "aws_ecr_repository" "app" {
    name                 = "secure-container-pipeline"
    image_tag_mutability = "IMMUTABLE"
    force_delete         = true # lab only: lets terraform destroy remove pushed images

    image_scanning_configuration {
        scan_on_push = true # free basic scan, compared against Trivy in the README
    }

    encryption_configuration {
        encryption_type = "KMS"
        kms_key         = aws_kms_key.lab.arn
    }
}

# GitHub Actions OIDC: Short-lived credentials for main of this repo only
resource "aws_iam_openid_connect_provider" "github" {
    url = "https://token.actions.githubusercontent.com"
    client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_trust" {
    statement {
        actions = ["sts:AssumeRoleWithWebIdentity"]
        principals {
            type = "Federated"
            identifiers = [aws_iam_openid_connect_provider.github.arn]
        }
        condition {
            test        = "StringEquals"
            variable    = "token.actions.githubusercontent.com:aud"
            values      = ["sts.amazonaws.com"]
        }
        condition {
            test        = "StringEquals"
            variable    = "token.actions.githubusercontent.com:sub"
            values      = [var.github_oidc_subject]
        }
    }
}

resource "aws_iam_role" "github_push" {
    name = "github-ecr-push-secure-container-pipeline"
    assume_role_policy = data.aws_iam_policy_document.github_trust.json
    max_session_duration = 3600
}

data "aws_iam_policy_document" "github_push" {
    statement {
        actions = ["ecr:GetAuthorizationToken"]
        resources = ["*"]
    }
    statement {
        actions = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload",
            "ecr:PutImage",
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:DescribeImages",
            "ecr:ListImages",
        ]
        resources = [aws_ecr_repository.app.arn]
    }
}

resource "aws_iam_role_policy" "github_push" {
    name    = "ecr-push-one-repo"
    role    = aws_iam_role.github_push.id
    policy  = data.aws_iam_policy_document.github_push.json
}

output "ecr_registry" {
    value = split("/", aws_ecr_repository.app.repository_url)[0]
}

output "push_role_arn" {
    value = aws_iam_role.github_push.arn
}

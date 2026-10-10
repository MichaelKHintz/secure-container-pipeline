terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
  }
  backend "s3" {
    key          = "secure-container-pipeline/cluster.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-west-2"
  default_tags {
    tags = {
      project   = "secure-container-pipeline"
      lifecycle = "ephemeral"
    }
  }
}

variable "my_ip_cidr" {
  description = "Your current public IP as a /32; the only source allowed to reach the EKS API"
  type        = string
}

locals {
  name = "secure-pipeline"
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Created in infra/foundation, looked up by name
data "aws_kms_alias" "lab" {
  name = "alias/secure-container-pipeline"
}

data "aws_ecr_repository" "app" {
  name = "secure-container-pipeline"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = "10.20.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # lab cost; production runs one per AZ

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = "1.35"
  upgrade_policy     = { support_type = "STANDARD" } # never bill at the extended support rate

  # API reachable only from your IP; nodes use the private endpoint
  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.my_ip_cidr]

  # Access entries only (no aws-auth ConfigMap)
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Envelope-encrypt Kubernetes Secrets with the Phase 0 key
  create_kms_key = false
  encryption_config = {
    provider_key_arn = data.aws_kms_alias.lab.target_key_arn
    resources        = ["secrets"]
  }

  # Control-plane logs to CloudWatch, kept for a week
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  addons = {
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      # IMDSv2 only, one network hop: pods cannot borrow the node's IAM role
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}

# Kyverno reads signatures from ECR through Pod Identity: one repo, read only
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kyverno_ecr_read" {
  name               = "${local.name}-kyverno-ecr-read"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "kyverno_ecr_read" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "kyverno_ecr_read" {
  name   = "ecr-read-one-repo"
  role   = aws_iam_role.kyverno_ecr_read.id
  policy = data.aws_iam_policy_document.kyverno_ecr_read.json
}

resource "aws_eks_pod_identity_association" "kyverno" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kyverno"
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno_ecr_read.arn
}

output "cluster_name" {
  value = module.eks.cluster_name
}

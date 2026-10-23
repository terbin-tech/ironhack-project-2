locals {
  service_cidr = "10.100.0.0/16"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = "martin-project-2"
  kubernetes_version = "1.37"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  create_kms_key             = false
  encryption_config          = null
  enable_irsa                = false
  create_node_security_group = false
  service_ipv4_cidr          = local.service_cidr

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  enable_cluster_creator_admin_permissions = false
  access_entries = {
    martin = {
      principal_arn = "arn:aws:iam::686699774218:user/martin"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    aws-secrets-store-csi-driver-provider = {
      # Pinned: the module otherwise takes the most recent build, which would
      # make later plans show a version change.
      addon_version = "v3.1.4-eksbuild.2"
      configuration_values = jsonencode({
        "secrets-store-csi-driver" = { enableSecretRotation = true }
      })
    }
  }
}

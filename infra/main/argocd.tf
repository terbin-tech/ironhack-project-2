data "aws_ssoadmin_instances" "this" {}

data "aws_identitystore_user" "martin" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = "martin-project-2"
    }
  }
}

module "argocd" {
  source  = "terraform-aws-modules/eks/aws//modules/capability"
  version = "~> 21.29"

  cluster_name = module.eks.cluster_name
  type         = "ARGOCD"
  name         = "martin-argocd"

  # Without this the submodule appends a random suffix to the role name.
  iam_role_name            = "martin-project-2-argocd"
  iam_role_use_name_prefix = false

  configuration = {
    argo_cd = {
      aws_idc = {
        idc_instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
        idc_region       = "us-east-1"
      }
      namespace = "argocd"
      rbac_role_mapping = [{
        role = "ADMIN"
        identity = [{
          id   = data.aws_identitystore_user.martin.user_id
          type = "SSO_USER"
        }]
      }]
    }
  }
}

# EKS creates the capability role's access entry with the capability, so the
# policy association has to wait for it.
resource "aws_eks_access_policy_association" "argocd" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.argocd.iam_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [module.argocd]
}

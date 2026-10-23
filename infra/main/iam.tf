locals {
  hosted_zone_id = "Z06626683QXS56B0ODY18"
  dns_names = [
    "martin.diogo.world",
    "a-martin.diogo.world",
    "aaaa-martin.diogo.world",
  ]

  # Subject of the fork's main branch. The owner and repository IDs keep the
  # trust tied to this repository if the fork is renamed or recreated.
  github_subject = "repo:terbin-tech@342395647/ironhack-project-2@1431057146:ref:refs/heads/main"
}

# Voting pods: read the database secret.
data "aws_iam_policy_document" "voting_pods_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["voting"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["result", "worker"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

data "aws_iam_policy_document" "voting_pods" {
  statement {
    # No kms:Decrypt: the secret uses aws/secretsmanager, whose key policy
    # allows use through Secrets Manager.
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role" "voting_pods" {
  name               = "martin-project-2-voting-pods"
  assume_role_policy = data.aws_iam_policy_document.voting_pods_trust.json
}

resource "aws_iam_role_policy" "voting_pods" {
  name   = "database-secret"
  role   = aws_iam_role.voting_pods.id
  policy = data.aws_iam_policy_document.voting_pods.json
}

resource "aws_eks_pod_identity_association" "voting" {
  for_each = toset(["result", "worker"])

  cluster_name    = module.eks.cluster_name
  namespace       = "voting"
  service_account = each.key
  role_arn        = aws_iam_role.voting_pods.arn
}

# ExternalDNS: change only the app's three records in the shared zone.
data "aws_iam_policy_document" "external_dns_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }
  }
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${local.hosted_zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = local.dns_names
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A", "AAAA", "TXT"]
    }
  }

  statement {
    actions   = ["route53:ListResourceRecordSets", "route53:ListTagsForResources"]
    resources = ["arn:aws:route53:::hostedzone/${local.hosted_zone_id}"]
  }

  statement {
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "martin-project-2-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_trust.json
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-records"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

# GitHub Actions: push images from the fork's main branch. The OIDC provider
# is shared with other projects in the account, so it is only read.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

data "aws_iam_policy_document" "github_actions" {
  statement {
    # GetAuthorizationToken does not support resource-level permissions.
    actions   = ["ecr:GetAuthorizationToken"]
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
      "ecr:DescribeImages",
    ]
    resources = [for repository in aws_ecr_repository.this : repository.arn]
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "martin-project-2-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "service_cidr" {
  value = local.service_cidr
}

output "argocd_server_url" {
  value = module.argocd.argocd_server_url
}

output "argocd_version" {
  value = module.argocd.version
}

output "node_iam_role_name" {
  value = module.eks.node_iam_role_name
}

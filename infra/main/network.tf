data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "martin-project-2"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.96.0/24", "10.0.97.0/24"]

  # One NAT gateway per zone, so the loss of one zone leaves the other with egress
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  # Flow logs of rejected packets to CloudWatch Logs, aggregated over 600 s
  enable_flow_log                           = true
  flow_log_traffic_type                     = "REJECT"
  flow_log_destination_type                 = "cloud-watch-logs"
  flow_log_max_aggregation_interval         = 600
  create_flow_log_cloudwatch_log_group      = true
  flow_log_cloudwatch_log_group_name_suffix = "martin-project-2"
  create_flow_log_cloudwatch_iam_role       = true
  vpc_flow_log_iam_role_name                = "martin-project-2-vpc-flow-log"
  vpc_flow_log_iam_role_use_name_prefix     = false
  vpc_flow_log_iam_policy_name              = "martin-project-2-vpc-flow-log"
  vpc_flow_log_iam_policy_use_name_prefix   = false

  # Only flow logs of this account's own VPC may use the delivery role
  flow_log_cloudwatch_iam_role_conditions = [
    {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    },
    {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    },
  ]
}

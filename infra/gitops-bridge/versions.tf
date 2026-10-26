terraform {
  required_version = "~> 1.17"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }

  backend "s3" {
    bucket       = "martin-tfstate-686699774218-us-east-1-an"
    key          = "gitops-bridge/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

data "terraform_remote_state" "main" {
  backend = "s3"

  config = {
    bucket = "martin-tfstate-686699774218-us-east-1-an"
    key    = "main/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.main.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.main.outputs.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "martin-project-2", "--region", "us-east-1"]
  }
}

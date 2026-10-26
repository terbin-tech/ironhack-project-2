locals {
  main = data.terraform_remote_state.main.outputs
}

# No `project` key: a project-scoped cluster would be unusable by the project-2
# AppProject. No `config` key either, as in the EKS documentation's example.
resource "kubernetes_secret_v1" "in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = "in-cluster"
    server = local.main.cluster_arn
  }
}

# The app-of-apps root needs the health of its child Applications, which Argo CD
# stopped assessing in 1.8. The Lua is verbatim from
# https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/health.md
resource "kubernetes_config_map_v1" "argocd_cm" {
  metadata {
    name      = "argocd-cm"
    namespace = "argocd"

    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    "resource.customizations.health.argoproj.io_Application" = <<-EOT
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs
    EOT
  }
}

resource "kubernetes_manifest" "project" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "project-2"
      namespace = "argocd"
    }
    spec = {
      description = "Voting app platform and workloads"
      sourceRepos = [
        "https://github.com/terbin-tech/ironhack-project-2.git",
        "https://github.com/kubernetes-sigs/gateway-api",
        "ghcr.io/nginx/charts",
        "quay.io/jetstack/charts",
        "https://kubernetes-sigs.github.io/external-dns/",
      ]
      # Required by the EKS Argo CD capability for Applications stored in argocd.
      sourceNamespaces = ["argocd"]
      destinations = [{
        name      = "in-cluster"
        namespace = "*"
      }]
      clusterResourceWhitelist = [{
        group = "*"
        kind  = "*"
      }]
    }
  }
}

resource "kubernetes_manifest" "root" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "project-2"
      source = {
        repoURL        = "https://github.com/terbin-tech/ironhack-project-2.git"
        targetRevision = "main"
        path           = "gitops/root"
      }
      destination = {
        name      = "in-cluster"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["ServerSideApply=true"]
        retry = {
          limit = 10
          backoff = {
            duration    = "10s"
            factor      = 2
            maxDuration = "5m"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret_v1.in_cluster,
    kubernetes_config_map_v1.argocd_cm,
    kubernetes_manifest.project,
  ]
}

resource "kubernetes_namespace_v1" "voting" {
  metadata {
    name = "voting"

    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/audit"           = "restricted"
    }
  }
}

# Pod Security labels on the namespaces this root does not create, at the level their pods meet.
# The Secrets Store CSI driver and the GuardDuty agent need hostPath volumes and host access.
resource "kubernetes_labels" "pod_security" {
  for_each = {
    argocd              = "restricted"
    default             = "restricted"
    aws-secrets-manager = "privileged"
    amazon-guardduty    = "privileged"
  }

  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = each.key
  }

  labels = {
    "pod-security.kubernetes.io/enforce"         = each.value
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = each.value
    "pod-security.kubernetes.io/audit"           = each.value
  }
}

resource "kubernetes_config_map_v1" "voting_config" {
  metadata {
    name      = "voting-config"
    namespace = kubernetes_namespace_v1.voting.metadata[0].name
  }

  data = {
    DB_HOST    = local.main.db_address
    DB_PORT    = tostring(local.main.db_port)
    DB_NAME    = local.main.db_name
    REDIS_HOST = local.main.valkey_primary_endpoint
    REDIS_PORT = tostring(local.main.valkey_port)
  }
}

# The mounted volume holds the files username and password and no Kubernetes
# Secret is synced from it.
resource "kubernetes_manifest" "voting_db" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "voting-db"
      namespace = kubernetes_namespace_v1.voting.metadata[0].name
    }
    spec = {
      provider = "aws"
      parameters = {
        usePodIdentity = "true"
        objects = yamlencode([{
          objectName = local.main.db_secret_arn
          objectType = "secretsmanager"
          jmesPath = [
            { path = "username", objectAlias = "username" },
            { path = "password", objectAlias = "password" },
          ]
        }])
      }
    }
  }
}

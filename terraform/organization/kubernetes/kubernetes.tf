terraform {
  required_version = ">= 0.13"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

##################
# Service accounts in google, to be mapped to kuberenetes secrets
##################


# it would be nice for this to be per app, but may not be feasible 
# since may not be able to create service accounts per job.
# Remember...I want all gcp resources defined through TF
# this is the service acccount for spark jobs and 
# can write to spark storage
resource "google_service_account" "spark-gcs" {
  project      = var.project
  account_id   = "spark-gcs-${var.organization}"
  display_name = "Spark Service account ${var.organization}"
}



resource "google_service_account" "docker-write" {
  project      = var.project
  account_id   = "docker-write-${var.organization}"
  display_name = "docker-write-${var.organization}"
}


####### START DELETE...at least for read only
# This is for writing to gcr registry
# needed for argo to deploy container to gcr
# This is for reading from gcr registry
# needed for argo containers AND for spark jobs
resource "google_service_account" "docker-read" {
  project      = var.project
  account_id   = "docker-read-${var.organization}"
  display_name = "docker-read-${var.organization}"
}

resource "google_storage_bucket_iam_member" "viewer" {
  bucket = "artifacts.${var.project}.appspot.com"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.docker-read.email}"
}
####### END DELETE

#resource "google_storage_bucket_iam_member" "writer" {
#  bucket = "artifacts.${var.project}.appspot.com"
#  role   = "roles/storage.objectAdmin"
#  member = "serviceAccount:${google_service_account.docker-write.email}"
#}

resource "google_project_iam_member" "writer" {
  project = var.project
  role    = "roles/cloudbuild.builds.builder" #"roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.docker-write.email}"
}




#resource "google_artifact_registry_repository" "orgrepo" {
#  provider = google-beta

#  location      = "us-central1"
#  repository_id = var.organization
#  description   = "organization specific docker repo"
#  format        = "DOCKER"
#}

#resource "google_artifact_registry_repository_iam_member" "providereadwrite" {
#  provider = google-beta

#  location   = google_artifact_registry_repository.orgrepo.location
#  repository = google_artifact_registry_repository.orgrepo.name
#  role       = "roles/artifactregistry.writer"
#  member     = "serviceAccount:${google_service_account.docker-write.email}"
#}



resource "google_storage_bucket" "sparkstorage" {
  project                     = var.project
  name                        = "streamstate-sparkstorage-${var.organization}"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "sparkadmin" {
  bucket = google_storage_bucket.sparkstorage.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.spark-gcs.email}"
}

# eventually this should be a per project
resource "google_project_iam_member" "containerpolicy" {
  project = var.project
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.spark-gcs.email}"
}


##################
# Set up connection to GKE
##################
data "google_client_config" "default" {
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(var.cluster_ca_cert)
}
provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(var.cluster_ca_cert)
  }
}
provider "kubectl" {
  host                   = var.cluster_endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(var.cluster_ca_cert)
}

data "template_file" "kubeconfig" {
  template = file("${path.module}/kubeconfig.yml")

  vars = {
    cluster_name  = var.cluster_name
    endpoint      = var.cluster_endpoint
    cluster_ca    = var.cluster_ca_cert
    cluster_token = data.google_client_config.default.access_token
  }
}
# I believe this is needed to persist auth for more than 60 minutes
# careful!  this is sensitive, I believe
resource "local_file" "kubeconfig" {
  depends_on = [var.cluster_id]
  content    = data.template_file.kubeconfig.rendered
  filename   = "${path.root}/kubeconfig"
}

##################
# Create Kubernetes resources
##################
resource "kubernetes_namespace" "mainnamespace" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_namespace" "argoevents" {
  metadata {
    name = "argo-events"
  }
}

##################
# Map GCP service accounts to kubernetes service accounts
##################


# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# this works with google service account binding to connect kubernetes and google accounts
resource "kubernetes_service_account" "docker-cfg-write-events" {
  metadata {
    name      = "docker-cfg-write"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.docker-write.email
    }
  }
  depends_on = [kubernetes_namespace.argoevents]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# link service account and kubernetes service account
resource "google_service_account_iam_binding" "bind_docker_write_argo" {
  service_account_id = google_service_account.docker-write.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project}.svc.id.goog[${kubernetes_namespace.argoevents.metadata.0.name}/${kubernetes_service_account.docker-cfg-write-events.metadata.0.name}]",
  ]
  depends_on = [
    kubernetes_service_account.docker-cfg-write-events
  ]
}


# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# this works with google service account binding to connect kubernetes and google accounts
resource "kubernetes_service_account" "docker-cfg-read-events" {
  metadata {
    name      = "docker-cfg-read"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.docker-read.email
    }
  }
  depends_on = [kubernetes_namespace.argoevents]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# link service account and kubernetes service account
resource "google_service_account_iam_binding" "bind_docker_read_argo" {
  service_account_id = google_service_account.docker-read.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project}.svc.id.goog[${kubernetes_namespace.argoevents.metadata.0.name}/${kubernetes_service_account.docker-cfg-read-events.metadata.0.name}]",
  ]
  depends_on = [
    kubernetes_service_account.docker-cfg-read-events
  ]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# this works with google service account binding to connect kubernetes and google accounts
resource "kubernetes_service_account" "docker-cfg-read" {
  metadata {
    name      = "docker-cfg-read"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.docker-read.email
    }
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# link service account and kubernetes service account
resource "google_service_account_iam_binding" "bind_docker_read" {
  service_account_id = google_service_account.docker-read.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project}.svc.id.goog[${kubernetes_namespace.mainnamespace.metadata.0.name}/${kubernetes_service_account.docker-cfg-read.metadata.0.name}]",
  ]
  depends_on = [
    kubernetes_service_account.docker-cfg-read
  ]
}


# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# this works with google service account binding to connect kubernetes and google accounts
resource "kubernetes_service_account" "spark-service" {
  metadata {
    name      = "spark"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.spark-gcs.email
    }
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# link service account and kubernetes service account
resource "google_service_account_iam_binding" "bind_spark_svc" {
  service_account_id = google_service_account.spark-gcs.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project}.svc.id.goog[${kubernetes_namespace.mainnamespace.metadata.0.name}/${kubernetes_service_account.spark-service.metadata.0.name}]",
  ]
  depends_on = [
    kubernetes_service_account.spark-service
  ]
}



##################
# Standalone kubernetes service accounts and secrets
##################


resource "random_password" "cassandra_password" {
  length  = 16
  special = true
}

resource "random_string" "cassandra_userid" {
  length  = 8
  special = false
}
resource "kubernetes_secret" "cassandra_svc" {
  metadata {
    name      = "cassandra-secret"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  data = {
    username = random_string.cassandra_userid.result
    password = random_password.cassandra_password.result
  }
  type       = "kubernetes.io/generic"
  depends_on = [kubernetes_namespace.mainnamespace]
}

resource "kubernetes_service_account" "cassandra_svc" {
  metadata {
    name      = "cassandra-svc"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }

  secret {
    name = kubernetes_secret.cassandra_svc.metadata.0.name
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}


##################
# Install Cassandra
##################

resource "helm_release" "cassandra" {
  name             = "cass-operator"
  namespace        = "cass-operator"
  create_namespace = true
  repository       = "https://datastax.github.io/charts"
  chart            = "cass-operator"

  set {
    name  = "clusterWideInstall"
    value = true
  }
}

data "kubectl_file_documents" "cassandra" {
  content = templatefile("../../gke/cassandra.yml", { secret = kubernetes_secret.cassandra_svc.metadata.0.name })
}

resource "kubectl_manifest" "cassandra" {
  count              = 3 # length(data.kubectl_file_documents.cassandra.documents)
  yaml_body          = element(data.kubectl_file_documents.cassandra.documents, count.index)
  override_namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  depends_on         = [helm_release.cassandra]
}

##################
# Install Spark
##################
resource "helm_release" "spark" {
  name             = "spark-operator"
  namespace        = "spark-operator"
  create_namespace = true
  repository       = "https://googlecloudplatform.github.io/spark-on-k8s-operator"
  chart            = "spark-operator"

}


##################
# Install Argo
##################


data "kubectl_file_documents" "argoworkflow" {
  content = file("../../argo/argoinstall.yml")
}
resource "kubectl_manifest" "argoworkflow" {
  count              = length(data.kubectl_file_documents.argoworkflow.documents)
  yaml_body          = element(data.kubectl_file_documents.argoworkflow.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubernetes_namespace.argoevents]
}

data "kubectl_file_documents" "argoevents" {
  content = file("../../argo/argoeventsinstall.yml")
}

resource "kubectl_manifest" "argoevents" {
  count              = length(data.kubectl_file_documents.argoevents.documents)
  yaml_body          = element(data.kubectl_file_documents.argoevents.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubectl_manifest.argoworkflow]
}

data "kubectl_file_documents" "argoeventworkflow" {
  content = templatefile("../../argo/eventworkflow.yml", {
    project           = var.project,
    dockersecretwrite = kubernetes_service_account.docker-cfg-write-events.metadata.0.name,
    dockersecretread  = kubernetes_service_account.docker-cfg-read-events.metadata.0.name,
    registry          = var.registry
    organization      = var.organization
  })
}
## The docker containers needed for this are built as part of the CI/CD pipeline that
## includes provisioning global TF, so the images will be available
## question: which images?  The latest?  Or specific tags?
resource "kubectl_manifest" "argoeventworkflow" {
  count              = 3 #length(data.kubectl_file_documents.argoeventworkflow.documents)
  yaml_body          = element(data.kubectl_file_documents.argoeventworkflow.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubectl_manifest.argoevents]
}
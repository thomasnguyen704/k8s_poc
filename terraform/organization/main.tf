variable "organization" {
  type = string
}
variable "namespace" {
  type = string
}
variable "project" {
  type = string
}
variable "registryprefix" {
  type    = string                       # eg gcr.io
  default = "us-central1-docker.pkg.dev" #"gcr.io" # us-central1-docker.pkg.dev/streamstatetest/streamstatetest
}
# this is likely a per-organization bucket
# TODO probably need to subsitute prefix at runtime
# so each organization gets own "backend"
terraform {
  required_version = ">= 0.13"
  backend "gcs" {
    bucket = "terraform-state-streamstate"
    prefix = "terraform/state-organization"
  }
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 3.52"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0.1"
    }
  }
}

module "gke-cluster" {
  source       = "./gke"
  organization = var.organization
  project      = var.project
  region       = "us-central1"

}
module "serviceaccounts" {
  source        = "./serviceaccounts"
  organization  = var.organization
  project       = var.project
  cluster_email = module.gke-cluster.cluster_email
}
#module "swagger" {
#  source    = "./swagger"
#  project   = var.project
#  clusterip = module.gke-cluster.endpoint
#}
module "kubernetes-config" {
  source                   = "./kubernetes"
  cluster_name             = module.gke-cluster.cluster_name
  cluster_id               = module.gke-cluster.cluster_id # creates dependency on cluster creation
  cluster_endpoint         = module.gke-cluster.cluster_endpoint
  cluster_ca_cert          = module.gke-cluster.cluster_ca_cert
  organization             = var.organization
  project                  = var.project
  registryprefix           = var.registryprefix
  namespace                = var.namespace
  docker_write_svc_email   = module.serviceaccounts.docker_write_svc_email
  docker_write_svc_name    = module.serviceaccounts.docker_write_svc_name
  spark_gcs_svc_name       = module.serviceaccounts.spark_gcs_svc_name
  spark_history_svc_email  = module.serviceaccounts.spark_history_svc_email
  spark_history_svc_name   = module.serviceaccounts.spark_history_svc_name
  org_registry             = module.serviceaccounts.org_registry
  spark_history_bucket_url = module.serviceaccounts.spark_history_bucket_url
  spark_storage_bucket_url = module.serviceaccounts.spark_storage_bucket_url
}





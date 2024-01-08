#Specify the compatible terraform version
terraform {
  required_version = ">= 1.0.2"
}

# Validating the project ids provided by the user before next steps
data "google_project" "project" {

  for_each = local.project_ids_map

  project_id = each.value

}

# Create Service account
resource "google_service_account" "project_service_account" {

  project      = var.svc_account_project_id
  account_id   = var.unravel_service_account
  display_name = "Unravel Healthcheck Service Account"

}

# Create roles, service account and associated private keys
module "monitoring_iam" {

  source = "./modules/iam"

  project_ids             = local.project_ids_map
  role_permission         = local.monitoring_project_role_permission
  role_name               = "mon_${var.unravel_role}"
  unravel_service_account = "serviceAccount:${google_service_account.project_service_account.email}"


  depends_on = [
  data.google_project.project, module.google_enable_monitoring_api]

}

# Create roles, service account and associated private keys
module "admin_iam" {

  source = "./modules/iam"

  project_ids             = local.admin_project_ids_map
  role_permission         = local.admin_project_role_permission
  role_name               = "admin_${var.unravel_role}"
  unravel_service_account = "serviceAccount:${google_service_account.project_service_account.email}"


  depends_on = [
  data.google_project.project, module.google_enable_admin_api]

}

# Create roles, service account and associated private keys
module "billing_iam" {

  source = "./modules/iam"

  project_ids             = local.billing_project_ids_map
  role_permission         = local.billing_project_role_permission
  role_name               = "billing_${var.unravel_role}"
  unravel_service_account = "serviceAccount:${google_service_account.project_service_account.email}"


  depends_on = [
  data.google_project.project, module.google_enable_billing_api]

}
# Enable GCP service API
module "google_enable_monitoring_api" {

  source = "./modules/apis"

  project_all  = var.monitoring_project_ids
  service_apis = local.monitoring_apis

  depends_on = [
  data.google_project.project]

}

# Enable GCP service API
module "google_enable_admin_api" {

  source = "./modules/apis"

  project_all  = var.admin_project_ids
  service_apis = local.admin_apis

  depends_on = [
  data.google_project.project]

}

# Enable GCP service API
module "google_enable_billing_api" {

  source = "./modules/apis"

  project_all  = var.billing_project_ids
  service_apis = local.billing_apis

  depends_on = [
  data.google_project.project]

}

# Generate base64 encoded key for Unravel service account
resource "google_service_account_key" "unravel_key" {

  service_account_id = google_service_account.project_service_account.name

  depends_on = [module.admin_iam, module.billing_iam, module.monitoring_iam]
}

# Write decoded Service account private keys to filesystem
resource "local_file" "unravel_keys" {

  content  = base64decode(google_service_account_key.unravel_key.private_key)
  filename = "${var.unravel_keys_location}/${var.svc_account_project_id}.json"

}






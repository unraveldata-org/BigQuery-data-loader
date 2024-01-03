# Variables which are constant. Changing these values will result in broken data
locals {

  # Permission required for the Unravel application to gather metrics and generate insights for API based polling model
  monitoring_project_role_permission = [
    "bigquery.jobs.create",
    "bigquery.jobs.listAll",
    "storage.objects.create",
    "storage.objects.list"
  ]

  # Permission required for the Unravel application to gather metrics from admin projects about reservations and commitments
  admin_project_role_permission = [
    "bigquery.jobs.create",
    "bigquery.reservations.list",
    "storage.objects.create",
    "storage.objects.list"
  ]

  billing_project_role_permission = [
    "bigquery.jobs.create",
    "bigquery.tables.getData",
    "storage.objects.create",
    "storage.objects.list"
  ]

  # Converting from list to Map for consistency
  project_ids_map         = { for project in toset(var.monitoring_project_ids) : project => project }
  admin_project_ids_map   = { for admin_project in toset(var.admin_project_ids) : admin_project => admin_project }
  billing_project_ids_map = { for billing_project in toset(var.billing_project_ids) : billing_project => billing_project }

  # API's to be enabled for Monitoring projects
  monitoring_apis = ["bigqueryreservation.googleapis.com"]

  # API's to be enabled for Admin project
  admin_apis = []

  # API's to be enabled for Billing project
  billing_apis = []

}



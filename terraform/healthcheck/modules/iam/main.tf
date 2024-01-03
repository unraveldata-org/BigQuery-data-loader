
### Monitoring Projects ###

# Create IAM Roles for all monitoring projects
# Create a role if a project is a monitoring project and (billing and/or datapage) project
# If the billing project is not a monitoring project, resources are handled in billing.tf
resource "google_project_iam_custom_role" "unravel_role" {

  for_each = var.project_ids

  project     = each.value
  role_id     = var.role_name
  title       = "Unravel Healthcheck Role"
  description = "Unravel Healthcheck Role to grant access to Read permissions in Bigquery projects"
  permissions = var.role_permission
}



resource "google_project_iam_member" "unravel_iam" {

  for_each = var.project_ids


  project = each.value
  role    = google_project_iam_custom_role.unravel_role[each.value].name
  member  = var.unravel_service_account
}





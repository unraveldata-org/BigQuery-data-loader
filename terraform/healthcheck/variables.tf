variable "monitoring_project_ids" {
  description = "GCP Project IDs for configuring Unravel Bigquery. Only those queries running in these projects will be monitored"
  type        = list(string)

  default = []

  validation {
    condition = length([
      for project in var.monitoring_project_ids : true
      if can(regex("[a-z0-9-]+$", project))
    ]) == length(var.monitoring_project_ids)
    error_message = "Accepts only GCP project ID and not Project Name. Please provide a valid GCP project ID. Ex: 'tactical-factor-123456'."
  }

  validation {
    condition     = length(var.monitoring_project_ids) == length(distinct(var.monitoring_project_ids))
    error_message = "All project ids must be unique."
  }
}

variable "admin_project_ids" {
  description = "GCP Admin Project IDs where reservations/collections are configured"
  type        = list(string)

  validation {
    condition = length([
      for project in var.admin_project_ids : true
      if can(regex("[a-z0-9-]+$", project))
    ]) == length(var.admin_project_ids)
    error_message = "Accepts only GCP project ID and not Project Name. Please provide a valid GCP project ID. Ex: 'tactical-factor-123456'."
  }

  validation {
    condition     = length(var.admin_project_ids) == length(distinct(var.admin_project_ids))
    error_message = "All project ids must be unique."
  }

  default = []

}


variable "billing_project_ids" {
  description = "GCP Admin Project IDs where reservations/collections are configured"
  type        = list(string)

  validation {
    condition = length([
      for project in var.billing_project_ids : true
      if can(regex("[a-z0-9-]+$", project))
    ]) == length(var.billing_project_ids)
    error_message = "Accepts only GCP project ID and not Project Name. Please provide a valid GCP project ID. Ex: 'tactical-factor-123456'."
  }

  validation {
    condition     = length(var.billing_project_ids) == length(distinct(var.billing_project_ids))
    error_message = "All project ids must be unique."
  }

  default = []

}

variable "svc_account_project_id" {
  description = "ID of the GCP Project where Unravel VM  is running"
  type        = string

  default = null
}


variable "unravel_keys_location" {
  description = "Local FS path to save GCP service account Keys"
  type        = string

  default = "./keys"

  validation {
    condition     = can(regex("[a-z0-9-._/A-Z]+[A-Za-z0-9]$", var.unravel_keys_location))
    error_message = "A valid filesystem path where unravel user have access to without a trailing '/'. Ex: './keys' ."
  }
}

variable "unravel_role" {
  description = "Custom role name for Unravel"
  type        = string

  default = "unravel_healthcheck_role"

  validation {
    condition     = can(regex("^[a-z0-9_.]{3,64}$", var.unravel_role))
    error_message = "ID must start with a letter, and contain only the following characters: letters, numbers, dashes (-)."
  }
}

variable "unravel_service_account" {
  description = "Service account name for Unravel"
  type        = string

  default = "unravel-health-svc-account"

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{4,28}[a-z0-9]$", var.unravel_service_account))
    error_message = "ID must start with a letter, and contain only the following characters: letters, numbers, dashes (-) and should have atleast 6 characters."
  }

}


variable "project_ids" {
  description = "List of projects ids from input.tfvars file in key value pair"
  type        = map(string)
  default     = {}
}

variable "role_permission" {
  description = "List of role permissions from local variables"
  default     = []
}

variable "svc_account_project_id" {
  description = "List of admin project role permissions from local variables"
  default     = []
}

variable "role_name" {
  description = "Unravel custom role name"
  default     = ""
}


variable "unravel_service_account" {
  description = "Unravel service account name"
  default     = ""
}


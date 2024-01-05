![Unravel](https://www.unraveldata.com/wp-content/themes/unravel-child/src/images/unLogo.svg)  
# GCP Resource Creation and Configuration for Unravel Bigquery Integration
![Terraform Workflow](https://github.com/unraveldata-org/unravel-terraform-scripts/actions/workflows/run-prcheck.yml/badge.svg)

Project for managing Unravel Bigquery GCP resource configuration! This project aims to simplify the process of setting up and managing Google Cloud resources using Terraform. Below are the instructions to get started:

## Prerequisites
Before proceeding with the installation, ensure that you have the following packages installed on your system:

```bash
git
curl
vim
```
The GCP user running this terrafrom script should have the following permissions.

```bash
Monitoring Projects
    bigquery.jobs.create
    bigquery.jobs.listAll
    storage.objects.create
    storage.objects.list

Admin Projects
    bigquery.jobs.create
    bigquery.reservations.list
    storage.objects.create
    storage.objects.list

Billing Projects
    bigquery.jobs.create
    bigquery.tables.getData
    storage.objects.create
    storage.objects.list
```


### Download Terraform
To download and install Terraform, follow these steps:

Visit https://www.terraform.io/downloads to access the Terraform downloads page and the instructions to install terraform.

### Configure gcloud
Before using this project, you need to authenticate with Google Cloud using gcloud. Follow the instructions provided at https://cloud.google.com/sdk/docs/install-sdk for a one-time configuration. You can find the installation instruction based on the Machine Arch and OS installed in the above link.

### Initialize gcloud
To authenticate gcloud, execute the following commands:

```bash
gcloud init
gcloud auth application-default login
```
## Configuration and Installation
Unravel requires few permissions to access Bigquery API/Logs from the GCP projects to generate insights. These project can be classified in to 3 based on the characteristics.

1. Monitoring projects: Projects where Bigquery jobs are running and needs to be integrated with Unravel. Mostly all the projects will come under this.
2. Admin Project: Project(s) where Bigquery Slot reservations/Commitments are defined. This Project may or may not be running Bigquery jobs.
3. Unravel Projects: The Project where Unravel VM is installed. It may or may not be running Bigquery jobs. 
4. Billing projects: Project where billing data is stored.


Authentication models for querying BigQuery API/logs:
1. Single Key based authentication.

### Single Key based authentication.
A "Master service account" is created under the "Unravel Project," and IAM roles are set up in each "Monitoring Project," "Admin Project," and "Unravel Project." These roles are associated with the "Master Service account" in the "Unravel Project."

However, in this model, we generate a key for the "Master Service account." This key will be used by Unravel to gain access.



## Create Terraform Input File
Begin by duplicating the provided example input file, input.tfvars.example, and renaming it as input.tfvars. This will serve as your working copy, where you'll input your specific project details.

```bash
cp input.tfvars.example input.tfvars
```

```bash
terraform output unravel_service_account
```
### Creating resources for Single Key based authentication.
Following variables should be updated.

**unravel_project_id** (Required)(string): This variable should contain the GCP Project ID where the Unravel VM is installed. It is crucial to accurately specify this ID for successful integration with Unravel.

**monitoring_project_ids** (Required)(map): Here, you must provide a map of GCP Project IDs(key) and the corresponding PubSub subscription name(values) to be created in these projects. These projects are where the BigQuery Jobs are running and need monitoring. Ensure that all relevant projects are included in this list. 

**admin_project_ids** (Optional)(list): If your setup involves Admin Projects where BigQuery slot reservations are configured, provide a list of their GCP Project IDs in this variable. Otherwise, leave it empty or omit it.

**key_based_auth_model** (Required)(bool) : Set this variable as `true` 


## Configuring Terraform Backend.(Optional)
It is always recommended to keep the state file in a central storage. Please configure `backend.tf` file in the repo to use Google Storage as your Terraform state file storage.

```bash
cp backend.tf.example backend.tf
```
Update the file with an already existing Google Storage Path where the user executing the terraform have access to.

## Run Terraform to Create Resources
Run Terraform commands in the terraform directory:
``` bash
cd bigquery
terraform init
terraform plan --var-file=input.tfvars
terraform apply --var-file=input.tfvars
```

## List the Resources Created by Terraform
To view a list of resources created by Terraform, execute the following command:

```bash
terraform output
```

terraform output unravel_keys_location
```

```
terraform output unravel_keys_location
```


## Destroy the Resources Created by Terraform
It is possible to eliminate resources either entirely or partially.

### Removing from Unravel
To remove projects from Unravel, use the remove command.

```bash
<Unravel_installation_path>/manager config bigquery remove <project_id>
<Unravel_installation_path>/manager config apply --restart
```

### Removing Unravel Resources from Monitored projects
Modify the input.tfvars file accordingly to exclude the designated project(s), then proceed to rerun  Terraform.  

```bash
terraform apply --var-file=input.tfvars
```

### Remove ALL resources [ CAUTION ]
To remove all changes made through Terraform, execute the following command:

```bash
cd bigquery
terraform destroy --var-file=input.tfvars
```


## Documentation
All documentation for Unravel can be found on our webpage:
https://docs.unraveldata.com

## Support and Feedback
If you encounter any issues or have questions during the integration process, don't hesitate to reach out to our support team at support@unraveldata.com. We are here to assist you and ensure a successful setup.

We value your feedback! If you have any suggestions or improvements to contribute to this repository, please feel free to open an issue or submit a pull request.

Thank you for choosing Unravel for your big data observability needs. We are excited to help you optimize your big data applications and enhance your data platform's performance and efficiency. Happy Unraveling!



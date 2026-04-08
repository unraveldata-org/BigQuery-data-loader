import os
import requests
import json
import time
import concurrent.futures
import google.auth.transport.requests
from google.cloud import bigquery
from google.auth import compute_engine
from google.api_core.exceptions import NotFound
from google.cloud import resourcemanager_v3


def getCredentials():
    credentials, project = google.auth.default()
    auth_request = google.auth.transport.requests.Request()
    credentials.refresh(auth_request)
    return credentials


def fetchDataFromPaginationApi(url, credentials):
    all_data = []
    next_page_token = None
    params = {}
    while True:
        if next_page_token:
            params['pageToken'] = next_page_token

        response = requests.get(url, params=params, headers={
            'Authorization': f'Bearer {credentials.token}'
        })

        if response.status_code != 200:
            print(f"Error to fetch data: {response.status_code}, {response.text}")
            return None
        data = response.json()
        all_data.extend(data.get('transferConfigs', []))
        next_page_token = data.get('nextPageToken')

        if not next_page_token:
            break
        print(f"fetching with token {next_page_token}")
    return all_data


def fetchDataFromApi(projectId):
    projectDetailsUrl = f'https://cloudresourcemanager.googleapis.com/v1/projects/{projectId}'
    ancestorDetailsUrl = f'https://cloudresourcemanager.googleapis.com/v1/projects/{projectId}:getAncestry'
    jobDetailsUrls = f'https://bigquerydatatransfer.googleapis.com/v1/projects/{projectId}/transferConfigs'
    credentials = getCredentials()
    print(f"fetching data for project {projectId}.")

    projectDetails = requests.get(projectDetailsUrl, headers={
        'Authorization': f'Bearer {credentials.token}'
    })
    ancestorDetails = requests.post(ancestorDetailsUrl, headers={
        'Authorization': f'Bearer {credentials.token}'
    })
    scheduledJobDetails = fetchDataFromPaginationApi(jobDetailsUrls, credentials)

    data = {}
    if projectDetails.status_code == 200:
        data["projectDetails"] = projectDetails.json()
    else:
        print(f"Failed to fetch the project details. error_code: {projectDetails.status_code}, message: {projectDetails.text}")

    if ancestorDetails.status_code == 200:
        data["ancestorDetails"] = ancestorDetails.json()
    else:
        print(f"Failed to fetch the project ancestor details. error_code: {ancestorDetails.status_code}, message: {ancestorDetails.text}")

    if scheduledJobDetails is not None:
        data["scheduledJobDetails"] = scheduledJobDetails
    else:
        print(f"Failed to fetch the scheduled job details for {projectId}.")
    print(f"Fetch complete for project: {projectId}")

    return data


def transformProjectData(projectData):
    transformedData = {
        "project_number": projectData.get("projectNumber", None),
        "project_id": projectData.get("projectId", None),
        "lifecycle_state": projectData.get("lifecycleState", None),
        "name": projectData.get("name", None),
        "create_time": projectData.get("createTime", None),
        "labels": json.dumps(projectData.get("labels", None)) if projectData.get("labels") else None,
        "parent": projectData.get("parent", None),
        "tags": json.dumps(projectData.get("tags", None)) if projectData.get("tags") else None
    }
    return transformedData


def transformAncestorsData(ancestorsData):
    transformed_data = []
    for data in ancestorsData['ancestor']:
        ancestor = {
            "resource_id": data.get("resourceId", None)
        }
        transformed_data.append(ancestor)
    return {
        'ancestor': transformed_data
    }


def transformJobsData(project, jobsData):
    transformed_data = []

    for config in jobsData:
        schedule_options = config.get("scheduleOptions", None)
        schedule_options_v2 = config.get("scheduleOptionsV2", None)
        email_prefermences = config.get("emailPreferences", None)
        encryption_configuration = config.get("encryptionConfiguration", None)
        params = config.get("params", None)
        error = config.get("error", None)
        transfer_config = {
            "project": project,
            "name": config.get("name", None),
            "display_name": config.get("displayName", None),
            "data_source_id": config.get("dataSourceId", None),
            "params": json.dumps(config.get("params", None)) if config.get("params") else None,
            "schedule": config.get("schedule", None),
            "schedule_options": None if not schedule_options else {
                "disable_auto_scheduling": schedule_options.get("disableAutoScheduling", None),
                "start_time": schedule_options.get("startTime", None),
                "end_time": schedule_options.get("endTime", None),
            },
            "schedule_options_V2": None if not schedule_options_v2 else {
                "time_based_schedule": None if schedule_options_v2.get("timeBasedSchedule") is None else {
                    "schedule": schedule_options_v2.get("timeBasedSchedule").get("schedule", None),
                    "start_time": schedule_options_v2.get("timeBasedSchedule").get("startTime", None),
                    "end_time": schedule_options_v2.get("timeBasedSchedule").get("endTime", None)
                },
                "manual_schedule": json.dumps(schedule_options_v2.get("manualSchedule")) if schedule_options_v2.get("manualSchedule") else None,
                "event_driven_schedule": None if schedule_options_v2.get("eventDrivenSchedule") is None else {
                    "pubsub_subscription": schedule_options_v2.get("eventDrivenSchedule").get("pubsubSubscription", None)
                },
            },
            "data_refresh_window_days": config.get("dataRefreshWindowDays", None),
            "disabled": config.get("disabled", None),
            "update_time": config.get("updateTime", None),
            "next_run_time": config.get("nextRunTime", None),
            "state": config.get("state", None),
            "user_id": config.get("userId", None),
            "dataset_region": config.get("datasetRegion", None),
            "notification_pubsub_topic": config.get("notificationPubsubTopic", None),
            "email_preferences": None if not email_prefermences else {
                "enable_failure_email": email_prefermences.get("enableFailureEmail", None)
            },
            "encryption_configuration": None if not encryption_configuration else {
                "kms_key_name": encryption_configuration.get("kmsKeyName", None)
            },
            "error": json.dumps(config.get("error", None)) if config.get("error") else None,
            "destination_dataset_id": config.get("destinationDatasetId", None),
            "owner_info": config.get("ownerInfo", None)
        }
        transformed_data.append(transfer_config)
    return transformed_data


def storeToBQTable(bqClient, projects_to_fetch, project_id, dataset_id):
    for project in projects_to_fetch:
        print(f'Storing data for project {project}')
        data = fetchDataFromApi(project)
        if data and "projectDetails" in data:
            projectData = transformProjectData(data['projectDetails'])
            if projectData:
                errors = bqClient.insert_rows_json(f'{project_id}.{dataset_id}.project_details', [projectData])
                print(f"Data inserted in project_details for project {project}")
                if errors:
                    print(f"Error in storing data into project table: {errors}")
            else:
                print(f"No Data to insert for project details in project {project}")
        if data and "ancestorDetails" in data:
            ancestorsData = transformAncestorsData(data['ancestorDetails'])
            if ancestorsData:
                errors = bqClient.insert_rows_json(f'{project_id}.{dataset_id}.ancestor_details', [ancestorsData])
                print(f"Data inserted in ancestor_details for project {project}")
                if errors:
                    print(f"Error in storing ancestor details to table: {errors}")
            else:
                print(f"No Data to insert for ancestor details in project: {project}")
        if data and "scheduledJobDetails" in data:
            transformed_data = transformJobsData(project, data['scheduledJobDetails'])
            if transformed_data:
                errors = bqClient.insert_rows_json(f'{project_id}.{dataset_id}.scheduled_job_details', transformed_data)
                print(f"Data inserted in job_details for project {project}")
                if errors:
                    print(f"Error in storing scheduled job details to table: {errors}")
            else:
                print(f"No Data to insert for scheduled jobs in project {project}")


def create_table(bqClient, query):
    query_job = bqClient.query(query)
    results = query_job.result()
    return results


def create_tables(queries, bqClient):
    print("##Creating tables##")
    count = 0
    with concurrent.futures.ThreadPoolExecutor() as executor:
        futures = [executor.submit(create_table, bqClient, query) for query in queries]
        concurrent.futures.wait(futures)

        for future in futures:
            try:
                result = future.result()
                count += 1
                print(f"Table created: {result}")
            except Exception as e:
                print(f"Error occured while creating table {e}")
    return count


def check_table_exists(bqClient, project_id, dataset_id, table_name):
    table_ref = bqClient.dataset(dataset_id).table(table_name)
    try:
        bqClient.get_table(table_ref)
        return True
    except Exception:
        return False


def verifyTables(client, project_id, dataset_id):
    tables = ['project_details', 'ancestor_details', 'scheduled_job_details']
    time.sleep(5)
    for table in tables:
        if not check_table_exists(client, project_id, dataset_id, table):
            print(f"Table {table} not ready yet, retrying...")
            retries = 5
            for _ in range(retries):
                time.sleep(5)
                if check_table_exists(client, project_id, dataset_id, table):
                    print(f"Table {table} is now available.")
                    break
                else:
                    print(f"Table {table} was not created successfully after retries.")
                    return False
        else:
            print(f"Table {table} is already available.")
    return True


def is_project_exists(project_id):
    resourceManagerClient = resourcemanager_v3.ProjectsClient()
    try:
        resourceManagerClient.get_project(name=f'projects/{project_id}')
        return True
    except NotFound:
        print(f"Project {project_id} does not exists. Provide different project")
        return False
    except Exception as e:
        print(f"Error getting project status {e}")
        return False


def is_dataset_exists(client, project_id, dataset_id):
    try:
        client.get_dataset(f"{project_id}.{dataset_id}")
        return True
    except NotFound:
        print(f"Dataset {dataset_id} does not exists.")
        return False


def create_dataset(client, project_id, dataset_id):
    try:
        print(f"creating dataset {dataset_id}")
        dataset = bigquery.Dataset(f"{project_id}.{dataset_id}")
        dataset.location = 'US'
        dataset = client.create_dataset(dataset)
        print(f"Dataset created {dataset_id}")
        return True
    except Exception as e:
        print(f"Error while creating dataset {e}")
        return False


def main():
    print(
        "To Run this script, user should have the rights on the source project/dataset"
        "\n[fetch the data from project] and target project/dataset [to store data in dataset]"
    )
    print(
        "This script will try to fetch the data from the following api's\n"
        "1. https://cloudresourcemanager.googleapis.com/v1/projects/{projectId}\n"
        "2. https://cloudresourcemanager.googleapis.com/v1/projects/{projectId}:getAncestry\n"
        "3. https://bigquerydatatransfer.googleapis.com/v1/projects/{projectId}/transferConfigs\n"
    )

    project_id = input("Provide project id to store data shared with unravel.\n")
    dataset_id = input("Provide dataset to store data shared with unravel:\n")
    projects_to_fetch = input(
        "Provide the list of projects to fetch the data. List of projects must be comma separated\n"
        "ex: project1, project2, ...\n"
    )
    projects_to_fetch = [project.strip() for project in projects_to_fetch.split(",")]
    print(projects_to_fetch)

    create_table_queries = [
        f"""create table `{project_id}.{dataset_id}.project_details` (project_number string, project_id string, lifecycle_state string,
name string, create_time string, labels JSON, parent struct<type string, id string>, tags JSON)""",
        f"""create table `{project_id}.{dataset_id}.scheduled_job_details` (
project STRING,
name STRING,
display_name\tSTRING,
data_source_id\tSTRING,
params JSON,
schedule STRING,
schedule_options struct<disable_auto_scheduling BOOLEAN, start_time string, end_time string>,
schedule_options_V2\tstruct<time_based_schedule struct<schedule string, start_time string, end_time string>, manual_schedule json, event_driven_schedule struct<pubsub_subscription string>>,
data_refresh_window_days INTEGER,
disabled BOOLEAN,
update_time STRING,
next_run_time\tSTRING,
state\tSTRING,
user_id\t\tSTRING,
dataset_region\t\tSTRING,
notification_pubsub_topic\t\tSTRING,
email_preferences struct<enable_failure_email BOOLEAN>,
encryption_configuration struct<kms_key_name string>,
error struct<code INTEGER, message string, details array<JSON>>,
destination_dataset_id STRING,
owner_info\tstruct<email string>)""",
        f"""create table `{project_id}.{dataset_id}.ancestor_details` (ancestor array<struct<resource_id struct<type string, id string>>>)"""
    ]

    client = bigquery.Client()

    if is_project_exists(project_id):
        if is_dataset_exists(client, project_id, dataset_id) or create_dataset(client, project_id, dataset_id):
            tableCreatedNumber = create_tables(create_table_queries, client)
            if tableCreatedNumber == len(create_table_queries):
                if verifyTables(client, project_id, dataset_id):
                    storeToBQTable(client, projects_to_fetch, project_id, dataset_id)


if __name__ == "__main__":
    main()
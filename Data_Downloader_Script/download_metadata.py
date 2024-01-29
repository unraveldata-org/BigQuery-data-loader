from google.cloud import bigquery
import argparse
import yaml


class download_metadata(object):

    def __init__(self, args):
        with open(args.config_file, 'r') as yaml_file:
            self.config = yaml.safe_load(yaml_file)['bigquery']

        self.project_ids = self.config.get('projects', '').split(',')
        self.regions = self.config.get('locations', '').split(',')
        self.billing_project = self.config.get('billing_project', '')
        self.billing_dataset = self.config.get('billing_dataset', '')
        self.billing_table = self.config.get('billing_table', '')
        self.credentials_path = self.config.get('credential', '')
        self.gcs_bucket_path = self.config.get('gcs_bucket_path', '')

        with open(self.credentials_path, 'r') as key_file:
            self.service_account_key = yaml.safe_load(key_file)

    def start(self):
        self.download_jobs_metadata()
        self.download_jobs_timeline_metadata()
        self.download_billing_metadata()

    def download_jobs_metadata(self):
        try:
            # Iterate for each project
            for project_id in self.project_ids:
                # Set up BigQuery client using Service Account
                client = bigquery.Client.from_service_account_info(
                    self.service_account_key, project=project_id
                )

                # Build and execute the query for each region
                for region in self.regions:
                    query = f"""
                        CREATE TEMP TABLE JOBS_TEMP AS
                        (SELECT 
                        "{region}" as location,
                        creation_time,
                        project_id,
                        project_number,
                        user_email,
                        job_id,
                        job_type,
                        statement_type,
                        priority,
                        start_time,
                        end_time,
                        query,
                        state,
                        reservation_id,
                        total_bytes_processed,
                        total_slot_ms,
                        error_result.reason as error_result_reason,
                        error_result.location as error_result_location,
                        error_result.debug_info as error_result_debug_info,
                        error_result.message as error_result_message,
                        cache_hit,
                        destination_table.project_id as destination_table_project_id,
                        destination_table.dataset_id as destination_table_dataset_id,
                        destination_table.table_id as destination_table_table_id,
                        TO_JSON(referenced_tables) as referenced_tables,
                        TO_JSON(labels) as labels,
                        TO_JSON(timeline) as timeline,
                        TO_JSON(job_stages) as job_stages,
                        total_bytes_billed,
                        transaction_id,
                        parent_job_id,
                        session_info.session_id as session_info_session_id,
                        TO_JSON(dml_statistics) as dml_statistics,
                        total_modified_partitions,
                        TO_JSON(query_info) as query_info,
                        transferred_bytes,
                        TO_JSON(bi_engine_statistics) as bi_engine_statistics,
                        TO_JSON(materialized_view_statistics) as materialized_view_statistics
                        FROM `{project_id}.region-{region}.INFORMATION_SCHEMA.JOBS` 
                        WHERE creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 DAY) AND CURRENT_TIMESTAMP());
            
                        EXPORT DATA OPTIONS(
                        uri='gs://{self.gcs_bucket_path}/JOBS_{project_id}_{region}_*.csv',
                        format='CSV',
                        overwrite=true,
                        header=true,
                        field_delimiter = ',') AS
                        SELECT * from JOBS_TEMP;
                    """

                    query_job = client.query(query)
                    query_job.result()

                    print(f"Jobs Query executed successfully for location : {region} in project {project_id}.")
        except Exception as e:
            print(f"An error occurred while downloading Jobs Data : {e}")


    def download_jobs_timeline_metadata(self):
        try:
            # Iterate for each project
            for project_id in self.project_ids:
                # Set up BigQuery client using Service Account
                client = bigquery.Client.from_service_account_info(
                    self.service_account_key, project=project_id
                )
                # Build and execute the query for each region
                for region in self.regions:
                    query = f"""
                        CREATE TEMP TABLE JOBSTIMELINE_TEMP AS
                        (SELECT
                        "{region}" as location,
                        period_start,
                        period_slot_ms,
                        project_id,
                        project_number,
                        user_email,
                        job_id,
                        job_type,
                        statement_type,
                        priority,
                        job_creation_time,
                        job_start_time,
                        job_end_time,
                        state,
                        reservation_id,
                        total_bytes_processed,
                        cache_hit,
                        total_bytes_billed,
                        transaction_id,
                        parent_job_id,
                        period_shuffle_ram_usage_ratio,
                        period_estimated_runnable_units,
                        error_result.reason as error_result_reason,
                        error_result.location as error_result_location,
                        error_result.debug_info as error_result_debug_info,
                        error_result.message as error_result_message
                        FROM `{project_id}`.`region-{region}`.INFORMATION_SCHEMA.JOBS_TIMELINE 
                        WHERE job_creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 180 DAY) AND CURRENT_TIMESTAMP());
                        
                        EXPORT DATA OPTIONS(
                          uri='gs://{self.gcs_bucket_path}/JOBSTIMELINE_{project_id}_{region}*.csv',
                          format='CSV',
                          overwrite=true,
                          header=true,
                          field_delimiter = ',') AS
                           SELECT * from JOBSTIMELINE_TEMP;
                    """

                    query_job = client.query(query)
                    query_job.result()

                    print(f"Jobs TimeLine Query executed successfully for location : {region} in project {project_id}.")
        except Exception as e:
            print(f"An error occurred while downloading Jobs TimeLine Data : {e}")

    def download_billing_metadata(self):
        try:
            # Set up BigQuery client using Service Account
            client = bigquery.Client.from_service_account_info(
                self.service_account_key, project=self.billing_project
            )
            # Build and Execute the query
            query = f"""
                CREATE TEMP TABLE BILLING_TEMP AS
                SELECT 
                billing_account_id,
                service.id as service_id,
                service.description as service_description,
                sku.id as sku_id,
                sku.description as sku_description,
                usage_start_time,
                usage_end_time,
                project.id as project_id,
                project.number as project_number,
                TO_JSON(project) as project,
                TO_JSON(labels) as labels,
                TO_JSON(system_labels) as system_labels,
                TO_JSON(location) as location,
                TO_JSON(resource) as resource,
                TO_JSON(tags) as tags,
                TO_JSON(price) as price,
                export_time,
                cost,
                currency,
                currency_conversion_rate,
                TO_JSON(usage) as usage,
                TO_JSON(credits) as credits,
                invoice.month as invoice_month,
                cost_type,
                TO_JSON(adjustment_info) as adjustment_info
                FROM `{self.billing_project}.{self.billing_dataset}.{self.billing_table}` WHERE export_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY) AND CURRENT_TIMESTAMP();
                
                EXPORT DATA OPTIONS(
                  uri='gs://{self.gcs_bucket_path}/GCP_BILLING_*.csv',
                  format='CSV',
                  overwrite=true,
                  header=true,
                  field_delimiter = ',') AS
                   SELECT * from BILLING_TEMP;
                    """

            query_job = client.query(query)
            query_job.result()

            print(f"Billing Data Query executed successfully for project_id : {self.billing_project}, datasetId {self.billing_dataset}, table : {self.billing_table}")
        except Exception as e:
            print(f"An error occurred while downloading Billing Data : {e}")


def main():
    parser = argparse.ArgumentParser(description="Config file path")
    parser.add_argument("--config_file", help="Path to the configuration file")
    args = parser.parse_args()
    pt = download_metadata(args)
    pt.start()

if __name__ == "__main__":
    main()
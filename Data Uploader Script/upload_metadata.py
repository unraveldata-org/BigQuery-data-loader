from google.cloud import bigquery
from google.cloud.exceptions import NotFound
import argparse
import yaml

class upload_metadata(object):

    def __init__(self, args):
        with open(args.config_file, 'r') as yaml_file:
            self.config = yaml.safe_load(yaml_file)['bigquery']

        self.upload_project = self.config.get('upload_project', '')
        self.upload_dataset = self.config.get('upload_dataset', '')
        self.jobs_table_name = self.config.get('jobs_table_name', '')
        self.jobs_timeline_table_name = self.config.get('jobs_timeline_table_name', '')
        self.billing_table_name = self.config.get('billing_table_name', '')
        self.jobs_data_gcs_bucket_path = self.config.get('jobs_data_gcs_bucket_path', '')
        self.jobs_timeline_data_gcs_bucket_path = self.config.get('jobs_timeline_data_gcs_bucket_path', '')
        self.billing_data_gcs_bucket_path = self.config.get('billing_data_gcs_bucket_path', '')
        self.credentials_path = self.config.get('credential', '')

        with open(self.credentials_path, 'r') as key_file:
            self.service_account_key = yaml.safe_load(key_file)

    def start(self):
        self.upload_jobs_metadata()
        self.upload_jobs_timeline_metadata()
        self.upload_billing_metadata()

    def upload_jobs_metadata(self):
        try:
            client = bigquery.Client.from_service_account_info(
                self.service_account_key, project=self.upload_project
            )

            uri = f'gs://{self.jobs_data_gcs_bucket_path}/JOBS_*.csv'

            dataset = bigquery.Dataset(client.dataset(self.upload_dataset))

            try:
                client.get_dataset(dataset)
            except NotFound:
                client.create_dataset(dataset)

            schema = []
            table = bigquery.Table(dataset.table(self.jobs_table_name), schema=schema)
            table = client.create_table(table)

            job_config = bigquery.LoadJobConfig()
            job_config.source_format = bigquery.SourceFormat.CSV
            job_config.write_disposition = bigquery.WriteDisposition.WRITE_APPEND
            job_config.autodetect = True
            job_config.allow_quoted_newlines = True
            job_config.allow_jagged_rows = True
            job_config.field_delimiter = ','
            job_config.quote_character = '"'

            load_job = client.load_table_from_uri(uri, table.reference, job_config=job_config)
            load_job.result()

            print(f"Jobs Data uploaded successfully to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.jobs_table_name}")

        except Exception as e:
            print(f"An error occurred while uploading Jobs Data to to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.jobs_table_name} exception : {e}")


    def upload_jobs_timeline_metadata(self):
        try:
            client = bigquery.Client.from_service_account_info(
                self.service_account_key, project=self.upload_project
            )

            uri = f'gs://{self.jobs_timeline_data_gcs_bucket_path}/JOBSTIMELINE_*.csv'

            dataset = bigquery.Dataset(client.dataset(self.upload_dataset))

            try:
                client.get_dataset(dataset)
            except NotFound:
                client.create_dataset(dataset)

            schema = []
            table = bigquery.Table(dataset.table(self.jobs_timeline_table_name), schema=schema)
            table = client.create_table(table)

            job_config = bigquery.LoadJobConfig()
            job_config.source_format = bigquery.SourceFormat.CSV
            job_config.write_disposition = bigquery.WriteDisposition.WRITE_APPEND
            job_config.autodetect = True
            job_config.allow_quoted_newlines = True
            job_config.allow_jagged_rows = True
            job_config.field_delimiter = ','
            job_config.quote_character = '"'

            load_job = client.load_table_from_uri(uri, table.reference, job_config=job_config)
            load_job.result()

            print(f"Jobs TimeLine Data uploaded successfully to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.jobs_timeline_table_name}")

        except Exception as e:
            print(f"An error occurred while uploading Jobs TimeLine Data to to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.jobs_timeline_table_name} exception : {e}")


    def upload_billing_metadata(self):
        try:
            client = bigquery.Client.from_service_account_info(
                self.service_account_key, project=self.upload_project
            )

            uri = f'gs://{self.billing_data_gcs_bucket_path}/GCP_BILLING_*.csv'

            dataset = bigquery.Dataset(client.dataset(self.upload_dataset))

            try:
                client.get_dataset(dataset)
            except NotFound:
                client.create_dataset(dataset)

            schema = []
            table = bigquery.Table(dataset.table(self.billing_table_name), schema=schema)
            table = client.create_table(table)

            job_config = bigquery.LoadJobConfig()
            job_config.source_format = bigquery.SourceFormat.CSV
            job_config.write_disposition = bigquery.WriteDisposition.WRITE_APPEND
            job_config.autodetect = True
            job_config.allow_quoted_newlines = True
            job_config.allow_jagged_rows = True
            job_config.field_delimiter = ','
            job_config.quote_character = '"'

            load_job = client.load_table_from_uri(uri, table.reference, job_config=job_config)
            load_job.result()

            print(f"Billing Data uploaded successfully to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.billing_table_name}")

        except Exception as e:
            print(f"An error occurred while uploading Billing Data to to project_id: {self.upload_project}, datasetId: {self.upload_dataset}, table: {self.billing_table_name} exception : {e}")


def main():
    parser = argparse.ArgumentParser(description="Config file path")
    parser.add_argument("--config_file", help="Path to the configuration file")
    args = parser.parse_args()
    pt = upload_metadata(args)
    pt.start()

if __name__ == "__main__":
    main()
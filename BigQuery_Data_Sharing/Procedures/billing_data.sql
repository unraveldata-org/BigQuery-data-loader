CREATE SCHEMA IF NOT EXISTS unravel_share_US
  OPTIONS (
      location = 'US'
  );
CREATE OR REPLACE PROCEDURE unravel_share_US.export_billing_data(
  dataset_name STRING,
  look_back_days INT64,
  billing_export_project STRING,
  billing_dataset STRING,
  billing_table STRING
)
BEGIN
   IF billing_export_project IS NULL THEN
       RAISE USING MESSAGE = "ERROR: billing_export_project is NULL!";
   END IF;


   IF billing_dataset IS NULL THEN
       RAISE USING MESSAGE = "billing_dataset is empty!";
   END IF;


   IF billing_table IS NULL THEN
       RAISE USING MESSAGE = "billing_table is empty!";
   END IF;


   BEGIN
       EXECUTE IMMEDIATE FORMAT("""
           CREATE TABLE %s.BILLING_TABLE AS
           SELECT * FROM `%s.%s.%s`
           WHERE export_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()
       """, dataset_name, billing_export_project, billing_dataset, billing_table,look_back_days);
   EXCEPTION WHEN ERROR THEN
           RAISE USING MESSAGE = "ERROR: Failed to create BILLING table!";
   END;
END;




CALL unravel_share_US.export_billing_data(
  'unravel_share_US',
  <number-of-days>,
  '<billing-project>',
  '<billing-dataset>',
  '<billing-table-name>'
);



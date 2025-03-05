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


SET @@location = 'US';

CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_US(
  dataset_name STRING,
  look_back_days INT64,
  tables ARRAY<STRING>,
  region STRING,
  project_names ARRAY<STRING>
)
BEGIN
  DECLARE project_name STRING;
  DECLARE table_name STRING;
  DECLARE where_clause STRING;

  IF region IS NULL THEN
      RAISE USING MESSAGE = "region is NULL!";
  END IF;

  IF dataset_name IS NULL THEN
      RAISE USING MESSAGE = "dataset_name is NULL!";
  END IF;

  IF ARRAY_LENGTH(project_names) = 0 THEN
      RAISE USING MESSAGE = "project_names array is empty!";
  END IF;

  IF ARRAY_LENGTH(tables) = 0 THEN
      RAISE USING MESSAGE = "tables array is empty!";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO
      SET table_name = table_row.f0_;

      BEGIN
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.%s_%s` AS
              SELECT *, "%s" as region, "%s" as project FROM `%s.region-%s.INFORMATION_SCHEMA.%s`
          """, dataset_name, table_name, region, region, project_names[SAFE_OFFSET(0)], project_names[SAFE_OFFSET(0)], region, table_name);
      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || table_name || " table!";
      END;

      FOR project_row IN (SELECT * FROM UNNEST(project_names)) DO
          SET project_name = project_row.f0_;

          IF project_name IS NULL THEN
              RAISE USING MESSAGE = "ERROR: project_name is NULL!";
          END IF;

          BEGIN
              SET where_clause = CASE
                  WHEN table_name = 'JOBS' THEN
                      FORMAT("WHERE creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
                  WHEN table_name = 'JOBS_TIMELINE' THEN
                      FORMAT("WHERE job_creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
                  ELSE
                      ""
              END;

              EXECUTE IMMEDIATE FORMAT("""
                  INSERT INTO `%s.%s_%s`
                  SELECT *, "%s" as region, "%s" as project
                  FROM `%s`.`region-%s`.INFORMATION_SCHEMA.%s
                  %s
              """, dataset_name, table_name, region, region, project_name, project_name, region, table_name, where_clause);
          EXCEPTION WHEN ERROR THEN
              RAISE USING MESSAGE = "ERROR: Failed to insert into " || table_name || " table for project: " || project_name;
          END;
      END FOR;
  END FOR;
END;


SET @@location = 'EU';

CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_EU(
  dataset_name STRING,
  look_back_days INT64,
  tables ARRAY<STRING>,
  region STRING,
  project_names ARRAY<STRING>
)
BEGIN
  DECLARE project_name STRING;
  DECLARE table_name STRING;
  DECLARE where_clause STRING;

  IF region IS NULL THEN
      RAISE USING MESSAGE = "region is NULL!";
  END IF;

  IF dataset_name IS NULL THEN
      RAISE USING MESSAGE = "dataset_name is NULL!";
  END IF;

  IF ARRAY_LENGTH(project_names) = 0 THEN
      RAISE USING MESSAGE = "project_names array is empty!";
  END IF;

  IF ARRAY_LENGTH(tables) = 0 THEN
      RAISE USING MESSAGE = "tables array is empty!";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO
      SET table_name = table_row.f0_;

      BEGIN
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.%s_%s` AS
              SELECT *, "%s" as region, "%s" as project FROM `%s.region-%s.INFORMATION_SCHEMA.%s`
          """, dataset_name, table_name, region, region, project_names[SAFE_OFFSET(0)], project_names[SAFE_OFFSET(0)], region, table_name);
      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || table_name || " table!";
      END;

      FOR project_row IN (SELECT * FROM UNNEST(project_names)) DO
          SET project_name = project_row.f0_;

          IF project_name IS NULL THEN
              RAISE USING MESSAGE = "ERROR: project_name is NULL!";
          END IF;

          BEGIN
              SET where_clause = CASE
                  WHEN table_name = 'JOBS' THEN
                      FORMAT("WHERE creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
                  WHEN table_name = 'JOBS_TIMELINE' THEN
                      FORMAT("WHERE job_creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
                  ELSE
                      ""
              END;

              EXECUTE IMMEDIATE FORMAT("""
                  INSERT INTO `%s.%s_%s`
                  SELECT *, "%s" as region, "%s" as project
                  FROM `%s`.`region-%s`.INFORMATION_SCHEMA.%s
                  %s
              """, dataset_name, table_name, region, region,project_name, project_name, region, table_name, where_clause);
          EXCEPTION WHEN ERROR THEN
              RAISE USING MESSAGE = "ERROR: Failed to insert into " || table_name || " table for project: " || project_name;
          END;
      END FOR;
  END FOR;
END;



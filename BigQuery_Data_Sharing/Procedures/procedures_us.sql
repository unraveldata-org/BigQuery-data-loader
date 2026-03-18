SET @@location = 'US';

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

CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_US(
  dataset_name STRING,
  look_back_days INT64,
  tables ARRAY<STRING>,
  region STRING,
  project_ids ARRAY<STRING>
)
BEGIN

  DECLARE table_name STRING;
  DECLARE project_id STRING;
  DECLARE col_list STRING;
  DECLARE dest_table_name STRING;
  DECLARE time_filter STRING;
  DECLARE baseline_project STRING;

  IF region IS NULL THEN
      RAISE USING MESSAGE = "region is NULL!";
  END IF;

  IF dataset_name IS NULL THEN
      RAISE USING MESSAGE = "dataset_name is NULL!";
  END IF;

  IF ARRAY_LENGTH(tables) = 0 THEN
      RAISE USING MESSAGE = "tables array is empty!";
  END IF;

  IF ARRAY_LENGTH(project_ids) = 0 THEN
      RAISE USING MESSAGE = "project_ids array is empty!";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

      SET table_name = table_row.f0_;
      SET dest_table_name = CONCAT(table_name, '_', region);

      -- Set time filter based on table name
      SET time_filter = CASE table_name
          WHEN 'JOBS'          THEN FORMAT("WHERE creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
          WHEN 'JOBS_TIMELINE' THEN FORMAT("WHERE job_creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()", look_back_days)
          ELSE ""
      END;

      --------------------------------------------------------------------------------
      -- Create destination table using first project as schema baseline
      --------------------------------------------------------------------------------

      SET baseline_project = (
          SELECT p
          FROM UNNEST(project_ids) AS p
          WHERE p IS NOT NULL AND p != ""
          LIMIT 1
      );

      IF baseline_project IS NULL or baseline_project = '' THEN
          RAISE USING MESSAGE = "ERROR: No valid baseline project id found in project_ids.";
      END IF;

      BEGIN
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.%s` AS
              SELECT *, "%s" AS region, "" AS project
              FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
              %s
              LIMIT 0
          """,
          dataset_name,
          dest_table_name,
          region,
          baseline_project,
          region,
          table_name,
          time_filter);

      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || dest_table_name || " table!";
      END;

      --------------------------------------------------------------------------------
      -- Fetch column list from destination table, excluding added columns
      --------------------------------------------------------------------------------

      EXECUTE IMMEDIATE FORMAT("""
    SELECT STRING_AGG(column_name, ', ' ORDER BY ordinal_position)
    FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
    WHERE table_catalog = @@project_id
      AND table_schema = @dataset_name
      AND table_name = @dest_table_name
      AND column_name NOT IN ('region', 'project')
""", region)
INTO col_list
USING dataset_name AS dataset_name, dest_table_name AS dest_table_name;

      IF col_list IS NULL THEN
          RAISE USING MESSAGE = "ERROR: Could not retrieve column list for " || dest_table_name;
      END IF;

      --------------------------------------------------------------------------------
      -- Insert from each project
      --------------------------------------------------------------------------------

      FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

          SET project_id = project_row.f0_;

          IF project_id IS NULL or project_id = '' THEN
              RAISE USING MESSAGE = "ERROR: project_id is NULL or empty!";
          END IF;

          BEGIN

              EXECUTE IMMEDIATE FORMAT("""
                  INSERT INTO `%s.%s` (%s, region, project)
                  SELECT %s, "%s" AS region, "%s" AS project
                  FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
                  %s
              """,
              dataset_name,
              dest_table_name,
              col_list,
              col_list,
              region,
              project_id,
              project_id,
              region,
              table_name,
              time_filter);

          EXCEPTION WHEN ERROR THEN
              RAISE USING MESSAGE =
                  "ERROR: Failed to insert into " || table_name ||
                  " for project: " || project_id;
          END;

      END FOR;

  END FOR;

END;

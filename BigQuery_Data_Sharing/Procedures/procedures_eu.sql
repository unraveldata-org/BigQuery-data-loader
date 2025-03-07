SET @@location = 'EU';

CREATE SCHEMA IF NOT EXISTS unravel_share_EU
  OPTIONS (
      location = 'EU'
  );

CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_EU(
  dataset_name STRING,
  look_back_days INT64,
  tables ARRAY<STRING>,
  region STRING,
  project_ids ARRAY<STRING>
)
BEGIN
  DECLARE project_id STRING;
  DECLARE table_name STRING;
  DECLARE where_clause STRING;

  IF region IS NULL THEN
      RAISE USING MESSAGE = "region is NULL!";
  END IF;

  IF dataset_name IS NULL THEN
      RAISE USING MESSAGE = "dataset_name is NULL!";
  END IF;

  IF ARRAY_LENGTH(project_ids) = 0 THEN
      RAISE USING MESSAGE = "project_ids array is empty!";
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
          """, dataset_name, table_name, region, region, project_ids[SAFE_OFFSET(0)], project_ids[SAFE_OFFSET(0)], region, table_name);
      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || table_name || " table!";
      END;

      FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO
          SET project_id = project_row.f0_;

          IF project_id IS NULL THEN
              RAISE USING MESSAGE = "ERROR: project_id is NULL!";
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
              """, dataset_name, table_name, region, region,project_id, project_id, region, table_name, where_clause);
          EXCEPTION WHEN ERROR THEN
              RAISE USING MESSAGE = "ERROR: Failed to insert into " || table_name || " table for project: " || project_id;
          END;
      END FOR;
  END FOR;
END;


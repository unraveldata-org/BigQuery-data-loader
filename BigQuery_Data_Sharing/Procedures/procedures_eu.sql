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

  DECLARE table_name STRING;
  DECLARE project_id STRING;
  DECLARE where_clause STRING;
  DECLARE project_filter STRING;

  IF region IS NULL THEN
      RAISE USING MESSAGE = "region is NULL!";
  END IF;

  IF dataset_name IS NULL THEN
      RAISE USING MESSAGE = "dataset_name is NULL!";
  END IF;

  IF ARRAY_LENGTH(tables) = 0 THEN
      RAISE USING MESSAGE = "tables array is empty!";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

      SET table_name = table_row.f0_;

      -- Create destination table
      BEGIN
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.%s_%s` AS
              SELECT *, "%s" AS region, "" AS project
              FROM `region-%s`.INFORMATION_SCHEMA.%s
              WHERE 1 = 0
          """,
          dataset_name,
          table_name,
          region,
          region,
          region,
          table_name);

      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || table_name || " table!";
      END;

      --------------------------------------------------------------------------------
      -- JOBS and JOBS_TIMELINE → Organization views
      --------------------------------------------------------------------------------

      IF table_name = 'JOBS_BY_ORGANIZATION' THEN

          SET project_filter = CASE
              WHEN ARRAY_LENGTH(project_ids) > 0
              THEN "AND project_id IN UNNEST(@project_ids)"
              ELSE ""
          END;

          EXECUTE IMMEDIATE FORMAT("""
              INSERT INTO `%s.%s_%s`
              SELECT *, "%s" AS region, project_id AS project
              FROM `region-%s`.INFORMATION_SCHEMA.JOBS_BY_ORGANIZATION
              WHERE creation_time BETWEEN
                    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
                    AND CURRENT_TIMESTAMP()
              %s
          """,
          dataset_name,
          table_name,
          region,
          region,
          region,
          look_back_days,
          project_filter)
          USING project_ids AS project_ids;

      --------------------------------------------------------------------------------

      ELSEIF table_name = 'JOBS_TIMELINE_BY_ORGANIZATION' THEN

          SET project_filter = CASE
              WHEN ARRAY_LENGTH(project_ids) > 0
              THEN "AND project_id IN UNNEST(@project_ids)"
              ELSE ""
          END;

          EXECUTE IMMEDIATE FORMAT("""
              INSERT INTO `%s.%s_%s`
              SELECT *, "%s" AS region, project_id AS project
              FROM `region-%s`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_ORGANIZATION
              WHERE job_creation_time BETWEEN
                    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
                    AND CURRENT_TIMESTAMP()
              %s
          """,
          dataset_name,
          table_name,
          region,
          region,
          region,
          look_back_days,
          project_filter)
          USING project_ids AS project_ids;

      --------------------------------------------------------------------------------
      -- Other tables
      --------------------------------------------------------------------------------

      ELSE

          IF ARRAY_LENGTH(project_ids) = 0 THEN
              RAISE USING MESSAGE = "project_ids required for table: " || table_name;
          END IF;

          FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

              SET project_id = project_row.f0_;

              BEGIN

                  EXECUTE IMMEDIATE FORMAT("""
                      INSERT INTO `%s.%s_%s`
                      SELECT *, "%s" AS region, "%s" AS project
                      FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
                  """,
                  dataset_name,
                  table_name,
                  region,
                  region,
                  project_id,
                  project_id,
                  region,
                  table_name);

              EXCEPTION WHEN ERROR THEN
                  RAISE USING MESSAGE =
                      "ERROR: Failed to insert into " || table_name ||
                      " for project: " || project_id;

              END;

          END FOR;

      END IF;

  END FOR;

END;

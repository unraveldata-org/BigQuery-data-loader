SET @@location = 'EU';

CREATE SCHEMA IF NOT EXISTS unravel_share_EU
OPTIONS (location = 'EU');

CREATE OR REPLACE PROCEDURE unravel_share_EU.export_org_metadata_EU(
  dataset_name STRING,
  look_back_days INT64,
  tables ARRAY<STRING>,
  region STRING,
  project_ids ARRAY<STRING>
)
BEGIN

  DECLARE table_name STRING;
  DECLARE dest_table_name STRING;
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
      SET dest_table_name = CONCAT(table_name, '_', region);

      IF table_name NOT IN ('JOBS_BY_ORGANIZATION', 'JOBS_TIMELINE_BY_ORGANIZATION') THEN
          RAISE USING MESSAGE = "Unsupported table: " || table_name;
      END IF;

      --------------------------------------------------------------------------------
      -- Create destination table
      --------------------------------------------------------------------------------

      BEGIN
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.%s` AS
              SELECT *, "%s" AS region, "" AS project
              FROM `region-%s`.INFORMATION_SCHEMA.%s
              WHERE 1 = 0
          """,
          dataset_name,
          dest_table_name,
          region,
          region,
          table_name);

      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || dest_table_name || " table!";
      END;

      --------------------------------------------------------------------------------
      -- Optional project filter
      --------------------------------------------------------------------------------

      SET project_filter = CASE
          WHEN ARRAY_LENGTH(project_ids) > 0
          THEN "AND project_id IN (SELECT * FROM UNNEST(@project_ids))"
          ELSE ""
      END;

      --------------------------------------------------------------------------------
      -- JOBS_BY_ORGANIZATION
      --------------------------------------------------------------------------------

      IF table_name = 'JOBS_BY_ORGANIZATION' THEN

          EXECUTE IMMEDIATE FORMAT("""
              INSERT INTO `%s.%s`
              SELECT *, "%s" AS region, project_id AS project
              FROM `region-%s`.INFORMATION_SCHEMA.JOBS_BY_ORGANIZATION
              WHERE creation_time BETWEEN
                    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
                    AND CURRENT_TIMESTAMP()
              %s
          """,
          dataset_name,
          dest_table_name,
          region,
          region,
          look_back_days,
          project_filter)
          USING project_ids AS project_ids;

      --------------------------------------------------------------------------------
      -- JOBS_TIMELINE_BY_ORGANIZATION
      --------------------------------------------------------------------------------

      ELSEIF table_name = 'JOBS_TIMELINE_BY_ORGANIZATION' THEN

          EXECUTE IMMEDIATE FORMAT("""
              INSERT INTO `%s.%s`
              SELECT *, "%s" AS region, project_id AS project
              FROM `region-%s`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_ORGANIZATION
              WHERE job_creation_time BETWEEN
                    TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
                    AND CURRENT_TIMESTAMP()
              %s
          """,
          dataset_name,
          dest_table_name,
          region,
          region,
          look_back_days,
          project_filter)
          USING project_ids AS project_ids;

      END IF;

  END FOR;

END;

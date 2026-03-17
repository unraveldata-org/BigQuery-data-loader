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
  DECLARE col_list STRING;
  DECLARE dest_table_name STRING;
  DECLARE time_filter STRING;

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
          project_ids[OFFSET(0)],
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

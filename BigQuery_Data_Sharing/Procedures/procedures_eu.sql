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
  DECLARE col_list STRING;
  DECLARE dest_table_name STRING;

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

      -- Create destination table
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
          RAISE USING MESSAGE = "ERROR: Failed to create " || table_name || " table!";
      END;

      --------------------------------------------------------------------------------
      -- JOBS_BY_ORGANIZATION → Organization view
      --------------------------------------------------------------------------------

      IF table_name = 'JOBS_BY_ORGANIZATION' THEN

          SET project_filter = CASE
              WHEN ARRAY_LENGTH(project_ids) > 0
              THEN "AND project_id IN UNNEST(@project_ids)"
              ELSE ""
          END;

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
      -- JOBS_TIMELINE_BY_ORGANIZATION → Organization view
      --------------------------------------------------------------------------------

      ELSEIF table_name = 'JOBS_TIMELINE_BY_ORGANIZATION' THEN

          SET project_filter = CASE
              WHEN ARRAY_LENGTH(project_ids) > 0
              THEN "AND project_id IN UNNEST(@project_ids)"
              ELSE ""
          END;

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

      --------------------------------------------------------------------------------
      -- Other tables (COLUMNS, TABLES, TABLE_STORAGE, etc.)
      -- Uses explicit column list to handle schema differences across projects
      --------------------------------------------------------------------------------

      ELSE

          IF ARRAY_LENGTH(project_ids) = 0 THEN
              RAISE USING MESSAGE = "project_ids required for table: " || table_name;
          END IF;

          -- Build column list from destination table schema (excludes 'region' and 'project'
          -- as those are added explicitly in the INSERT)
          EXECUTE IMMEDIATE FORMAT("""
    SELECT STRING_AGG(column_name, ', ' ORDER BY ordinal_position)
    FROM `%s.region-%s`.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema = '%s'
      AND table_name = '%s'
      AND column_name NOT IN ('region', 'project')
""",
@@project_id,
region,
dataset_name,
dest_table_name)
INTO col_list;

          IF col_list IS NULL THEN
              RAISE USING MESSAGE = "ERROR: Could not retrieve column list for " || dest_table_name;
          END IF;

          FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

              SET project_id = project_row.f0_;

              BEGIN

                  EXECUTE IMMEDIATE FORMAT("""
                      INSERT INTO `%s.%s` (%s, region, project)
                      SELECT %s, "%s" AS region, "%s" AS project
                      FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
                  """,
                  dataset_name,
                  dest_table_name,
                  col_list,
                  col_list,
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

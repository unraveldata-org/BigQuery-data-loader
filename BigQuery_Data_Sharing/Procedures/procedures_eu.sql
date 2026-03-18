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
          project_ids[OFFSET(0)],
          region,
          table_name,
          time_filter);

      EXCEPTION WHEN ERROR THEN
          RAISE USING MESSAGE = "ERROR: Failed to create " || dest_table_name || " table!";
      END;

      --------------------------------------------------------------------------------
      -- Insert from each project
      --------------------------------------------------------------------------------

      FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

          SET project_id = project_row.f0_;

          IF project_id IS NULL or project_id = '' THEN
            RAISE USING MESSAGE = "ERROR: project_id is NULL or empty!";
          END IF;

          -- Step 1: Create a real table from source project's INFORMATION_SCHEMA view (0 rows)
          EXECUTE IMMEDIATE FORMAT("""
              CREATE OR REPLACE TABLE `%s.src_cols_temp` AS
              SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
              LIMIT 0
          """, dataset_name, project_id, region, table_name);

          -- Step 2: Intersect destination columns with src_cols_temp columns
          EXECUTE IMMEDIATE FORMAT("""
              SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
              FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS c
              WHERE c.table_catalog = '%s'
                AND c.table_schema = '%s'
                AND c.table_name = '%s'
                AND c.column_name NOT IN ('region', 'project')
                AND c.column_name IN (
                  SELECT column_name
                  FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
                  WHERE table_catalog = '%s'
                    AND table_schema = '%s'
                    AND table_name = 'src_cols_temp'
                )
          """, region, @@project_id, dataset_name, dest_table_name, region, @@project_id, dataset_name)
          INTO col_list;

          -- Step 3: Drop the temp table
          EXECUTE IMMEDIATE FORMAT("""
              DROP TABLE IF EXISTS `%s.src_cols_temp`
          """, dataset_name);

          IF col_list IS NULL THEN
              RAISE USING MESSAGE = "ERROR: Could not retrieve column list for " || dest_table_name || " in project: " || project_id;
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

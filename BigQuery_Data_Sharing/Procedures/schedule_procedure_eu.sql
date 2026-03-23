SET @@location = 'EU';

CREATE SCHEMA IF NOT EXISTS unravel_share_EU
  OPTIONS (location = 'EU');

CREATE TABLE IF NOT EXISTS `unravel_share_EU.error_log`
(
  run_ts        TIMESTAMP,
  dest_table    STRING,
  project_id    STRING,
  error_message STRING,
  logged_at     TIMESTAMP
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Procedure to create projects_table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_EU.create_projects_table(
  dataset_name           STRING,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING
)
BEGIN

  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  BEGIN
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.projects_table` AS
      SELECT DISTINCT project.id AS project_id
      FROM `%s.%s.%s`
      WHERE service.id IN (
        '650B-3C82-34DB',
        '16B8-3DDA-9F10',
        'DCC9-8DB9-673F',
        '24E6-581D-38E5'
      )
    """,
    dataset_name,
    billing_export_project, billing_dataset, billing_table);

  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_EU.error_log`
      (run_ts, dest_table, project_id, error_message, logged_at)
    VALUES
      (CURRENT_TIMESTAMP(), 'projects_table', billing_export_project, @@error.message, CURRENT_TIMESTAMP());

  END;

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Procedure to incrementally sync billing data
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_EU.export_billing_data_incremental(
  dataset_name           STRING,
  lookback_days          INT64,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING
)
BEGIN

  DECLARE last_sync_ts   TIMESTAMP;
  DECLARE current_run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE dest_table     STRING DEFAULT 'BILLING_TABLE';

  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  -- Create destination table if first run (partitioned + clustered)
  EXECUTE IMMEDIATE FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.%s`
    PARTITION BY DATE(export_time)
    AS
    SELECT * FROM `%s.%s.%s`
    WHERE FALSE
  """, dataset_name, dest_table,
       billing_export_project, billing_dataset, billing_table);

  -- Resolve watermark from destination table
  EXECUTE IMMEDIATE FORMAT("""
    SELECT MAX(export_time) FROM `%s.%s`
  """, dataset_name, dest_table)
  INTO last_sync_ts;

  IF last_sync_ts IS NULL THEN
    SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
  END IF;

  BEGIN

    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO `%s.%s`
      SELECT * FROM `%s.%s.%s`
      WHERE export_time >  TIMESTAMP '%s'
        AND export_time <= TIMESTAMP '%s'
        AND service.id IN (
          '650B-3C82-34DB',
          '16B8-3DDA-9F10',
          'DCC9-8DB9-673F',
          '24E6-581D-38E5'
        )
    """,
    dataset_name, dest_table,
    billing_export_project, billing_dataset, billing_table,
    FORMAT_TIMESTAMP('%F %T', last_sync_ts),
    FORMAT_TIMESTAMP('%F %T', current_run_ts));

  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_EU.error_log`
      (run_ts, dest_table, project_id, error_message, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project, @@error.message, CURRENT_TIMESTAMP());

  END;

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Procedure to incrementally sync metadata tables
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_incremental_EU(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  project_ids    ARRAY<STRING>
)
BEGIN

  DECLARE table_name       STRING;
  DECLARE project_id       STRING;
  DECLARE col_list         STRING;
  DECLARE dest_table_name  STRING;
  DECLARE time_filter      STRING;
  DECLARE baseline_project STRING;
  DECLARE last_sync_ts     TIMESTAMP;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  -- DDL strings for partition + cluster per table
  DECLARE partition_clause STRING;
  DECLARE cluster_clause   STRING;

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

  SET baseline_project = (
    SELECT p FROM UNNEST(project_ids) AS p
    WHERE p IS NOT NULL AND p != ''
    LIMIT 1
  );
  IF baseline_project IS NULL OR baseline_project = '' THEN
    RAISE USING MESSAGE = "ERROR: No valid baseline project id found in project_ids.";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

    SET table_name      = table_row.f0_;
    SET dest_table_name = CONCAT(table_name, '_', region);

    -- Resolve partition + cluster clauses per table
    SET partition_clause = CASE table_name
      WHEN 'JOBS'         THEN 'PARTITION BY DATE(creation_time)'
      WHEN 'JOBS_TIMELINE' THEN 'PARTITION BY DATE(job_creation_time)'
      ELSE ''
    END;

    SET cluster_clause = CASE table_name
      WHEN 'JOBS'          THEN 'CLUSTER BY project_id, user_email'
      WHEN 'JOBS_TIMELINE' THEN 'CLUSTER BY project_id, user_email'
      ELSE ''
    END;

    BEGIN
      -- Create destination table with partition + cluster if it doesn't exist
      EXECUTE IMMEDIATE FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s`
        %s
        %s
        AS
        SELECT *, CAST(NULL AS STRING) AS region, CAST(NULL AS STRING) AS project
        FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
        LIMIT 0
      """,
      dataset_name, dest_table_name,
      partition_clause,
      cluster_clause,
      baseline_project, region, table_name);
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_EU.error_log`
        (run_ts, dest_table, project_id, error_message, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
        'DDL failed for table ' || table_name || ': ' || @@error.message,
        CURRENT_TIMESTAMP());
      CONTINUE;  -- skip entire table, move to next one in tables array
    END;

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        INSERT INTO `unravel_share_EU.error_log`
          (run_ts, dest_table, project_id, error_message, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id, 'project_id is NULL or empty', CURRENT_TIMESTAMP());
        CONTINUE;
      END IF;

      IF table_name IN ('JOBS', 'JOBS_TIMELINE') THEN

        EXECUTE IMMEDIATE FORMAT("""
          SELECT MAX(%s) FROM `%s.%s`
        """,
        CASE table_name
          WHEN 'JOBS'          THEN 'creation_time'
          WHEN 'JOBS_TIMELINE' THEN 'job_creation_time'
        END,
        dataset_name, dest_table_name)
        INTO last_sync_ts;

        IF last_sync_ts IS NULL THEN
          SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
        END IF;

      END IF;

      SET time_filter = CASE table_name
        WHEN 'JOBS' THEN FORMAT(
          "WHERE creation_time     > TIMESTAMP '%s' AND creation_time     <= TIMESTAMP '%s'",
          FORMAT_TIMESTAMP('%F %T', last_sync_ts),
          FORMAT_TIMESTAMP('%F %T', current_run_ts))
        WHEN 'JOBS_TIMELINE' THEN FORMAT(
          "WHERE job_creation_time > TIMESTAMP '%s' AND job_creation_time <= TIMESTAMP '%s'",
          FORMAT_TIMESTAMP('%F %T', last_sync_ts),
          FORMAT_TIMESTAMP('%F %T', current_run_ts))
        ELSE "WHERE TRUE"
      END;

      BEGIN
        -- Step 1: temp table for column intersection
        EXECUTE IMMEDIATE FORMAT("""
          CREATE OR REPLACE TABLE `%s.src_cols_temp` AS
          SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
          LIMIT 0
        """, dataset_name, project_id, region, table_name);
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_EU.error_log`
          (run_ts, dest_table, project_id, error_message, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
            'Step1 src_cols_temp failed: ' || @@error.message,
            CURRENT_TIMESTAMP());
        CONTINUE;  -- skip to next project
      END;

      BEGIN
        -- Step 2: column intersection
        EXECUTE IMMEDIATE FORMAT("""
          SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
          FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS c
          WHERE c.table_catalog = '%s'
            AND c.table_schema  = '%s'
            AND c.table_name    = '%s'
            AND c.column_name  NOT IN ('region', 'project')
            AND c.column_name  IN (
              SELECT column_name
              FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
              WHERE table_catalog = '%s'
                AND table_schema  = '%s'
                AND table_name    = 'src_cols_temp'
            )
        """, region, @@project_id, dataset_name, dest_table_name,
             region, @@project_id, dataset_name)
        INTO col_list;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_EU.error_log`
          (run_ts, dest_table, project_id, error_message, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
          'Step2 col_list failed: ' || @@error.message,
          CURRENT_TIMESTAMP());
        CONTINUE;  -- skip to next project
      END;

        -- Step 3: drop temp table
        EXECUTE IMMEDIATE FORMAT("""
          DROP TABLE IF EXISTS `%s.src_cols_temp`
        """, dataset_name);

        IF col_list IS NULL THEN
          INSERT INTO `unravel_share_EU.error_log`
            (run_ts, dest_table, project_id, error_message, logged_at)
          VALUES
            (current_run_ts, dest_table_name, project_id,
            'col_list is NULL for project: ' || project_id,
            CURRENT_TIMESTAMP());
          CONTINUE;  -- skip to next project instead of raising
        END IF;

      BEGIN
        -- Step 4: incremental insert
        EXECUTE IMMEDIATE FORMAT("""
          INSERT INTO `%s.%s` (%s, region, project)
          SELECT %s, '%s' AS region, '%s' AS project
          FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
          %s
        """,
        dataset_name, dest_table_name,
        col_list,
        col_list,
        region,
        project_id,
        project_id, region, table_name,
        time_filter);
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_EU.error_log`
          (run_ts, dest_table, project_id, error_message, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
          'Step4 insert failed: ' || @@error.message,
          CURRENT_TIMESTAMP());
        CONTINUE;  -- skip to next project
      END;

    END FOR;  -- projects

  END FOR;  -- tables

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper: resolves project_ids from projects_table then calls main procedure
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_incremental_EU_all_projects(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  projects_table STRING
)
BEGIN

  DECLARE project_ids ARRAY<STRING>;

  -- FIX: added opening parenthesis and dataset prefix
  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(project_id IGNORE NULLS)
    FROM `%s.%s`
  """, dataset_name, projects_table)
  INTO project_ids;

  IF project_ids IS NULL OR ARRAY_LENGTH(project_ids) = 0 THEN
    RAISE USING MESSAGE = "ERROR: No rows present in: " || projects_table;
  END IF;

  CALL unravel_share_EU.export_metadata_incremental_EU(
    dataset_name,
    lookback_days,
    tables,
    region,
    project_ids
  );

END;

SET @@location = 'US';

CREATE SCHEMA IF NOT EXISTS unravel_share_US
  OPTIONS (
      location = 'US'
  );

CREATE SCHEMA IF NOT EXISTS unravel_share_US_projects_list
  OPTIONS (
      location = 'US'
  );

CREATE TABLE IF NOT EXISTS `unravel_share_US.error_log`
(
  run_ts         TIMESTAMP,
  dest_table     STRING,
  project_id     STRING,
  error_message  STRING,
  failed_sql     STRING,
  logged_at      TIMESTAMP
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Procedure to create projects_table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_US_projects_list.create_projects_table(
  dataset_name           STRING,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING
)
BEGIN

  DECLARE exec_sql STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  SET exec_sql = FORMAT("""
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

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (CURRENT_TIMESTAMP(), 'projects_table', billing_export_project,
       'Failed to create projects_table: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
  END;

END;

CREATE OR REPLACE PROCEDURE unravel_share_US.export_billing_data(
  dataset_name           STRING,
  look_back_days         INT64,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING
)
BEGIN

  DECLARE exec_sql STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  SET exec_sql = FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.BILLING_TABLE` AS
    SELECT *
    FROM `%s.%s.%s`
    WHERE _PARTITIONTIME > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
      AND service.id IN (
        '650B-3C82-34DB',
        '16B8-3DDA-9F10',
        'DCC9-8DB9-673F',
        '24E6-581D-38E5'
      )
  """, dataset_name, billing_export_project, billing_dataset, billing_table, look_back_days);

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (CURRENT_TIMESTAMP(), 'BILLING_TABLE', billing_export_project,
       'Billing snapshot failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
  END;

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Main procedure: export metadata (snapshot — full replace each run)
-- Uses rotating staging tables to stay within BigQuery DML quota.
-- Backup → delete → insert → cleanup for safe replacement.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_US(
  dataset_name   STRING,
  look_back_days INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  project_ids    ARRAY<STRING>
)
BEGIN

  DECLARE table_name       STRING;
  DECLARE col_list         STRING;
  DECLARE dest_table_name  STRING;
  DECLARE baseline_project STRING;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE temp_table_name  STRING;
  DECLARE run_uuid         STRING DEFAULT REPLACE(GENERATE_UUID(), '-', '_');
  DECLARE time_filter      STRING;
  DECLARE project_id       STRING;
  DECLARE staging_has_rows INT64;

  -- Batching variables
  DECLARE batch_size       INT64 DEFAULT 20;
  DECLARE batch_count      INT64;
  DECLARE batch_number     INT64;
  DECLARE staging_table    STRING;
  DECLARE staging_tables   ARRAY<STRING>;
  DECLARE flush_sql        STRING;
  DECLARE st               STRING;

  -- SQL capture for error logging
  DECLARE exec_sql         STRING;

  -- Backup table for safe replace
  DECLARE backup_table     STRING;

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
    RAISE USING MESSAGE = "ERROR: No valid baseline project id found.";
  END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

    SET table_name      = table_row.f0_;
    SET dest_table_name = CONCAT(table_name, '_', region);

    -- Snapshot time filter: JOBS/JOBS_TIMELINE get a lookback window, others get everything
    SET time_filter = CASE table_name
      WHEN 'JOBS' THEN FORMAT(
        "WHERE creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()",
        look_back_days)
      WHEN 'JOBS_TIMELINE' THEN FORMAT(
        "WHERE job_creation_time BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY) AND CURRENT_TIMESTAMP()",
        look_back_days)
      ELSE 'WHERE TRUE'
    END;

    -- ─── DDL: create destination if not exists (Partition/Cluster clauses removed) ───
    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.%s`
      AS
      SELECT *, CAST(NULL AS STRING) AS region,
             CAST(NULL AS STRING) AS project,
             CURRENT_TIMESTAMP() AS ingestion_ts
      FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
      LIMIT 0
    """,
    dataset_name, dest_table_name,
    baseline_project, region, table_name);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_US.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'DDL failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    -- ─── Resolve col_list using baseline project ───
    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);

    SET exec_sql = FORMAT("""
      CREATE OR REPLACE TABLE `%s.%s` AS
      SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
    """, dataset_name, temp_table_name, baseline_project, region, table_name);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_US.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list temp table failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    SET exec_sql = FORMAT("""
      SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS c
      WHERE c.table_catalog = '%s'
        AND c.table_schema  = '%s'
        AND c.table_name    = '%s'
        AND c.column_name NOT IN ('region', 'project', 'ingestion_ts')
        AND c.column_name IN (
          SELECT column_name
          FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
          WHERE table_catalog = '%s'
            AND table_schema  = '%s'
            AND table_name    = '%s'
        )
    """, region, @@project_id, dataset_name, dest_table_name,
         region, @@project_id, dataset_name, temp_table_name);

    BEGIN
      EXECUTE IMMEDIATE exec_sql INTO col_list;
    EXCEPTION WHEN ERROR THEN
      EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, temp_table_name);
      INSERT INTO `unravel_share_US.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, temp_table_name);

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_US.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list is NULL – no column overlap', NULL, CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────
    -- ROTATING STAGING TABLES
    -- Each staging table receives up to batch_size per-project INSERTs.
    -- When full, rotate to a new staging table (UUID + batch number).
    -- At the end, flush ALL staging tables → destination.
    -- ─────────────────────────────────────────────────────────────────────

    SET staging_tables = [];
    SET batch_count    = 0;
    SET batch_number   = 0;
    SET staging_table  = '';

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        INSERT INTO `unravel_share_US.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
           'project_id is NULL or empty', NULL, CURRENT_TIMESTAMP());
        CONTINUE;
      END IF;

      -- ─── Rotate staging table when batch is full or first iteration ───
      IF batch_count >= batch_size OR staging_table = '' THEN
        SET batch_number  = batch_number + 1;
        SET staging_table = CONCAT('stg_', table_name, '_', run_uuid, '_b', batch_number);
        SET batch_count   = 0;

        SET exec_sql = FORMAT("""
          CREATE TABLE `%s.%s` AS
          SELECT %s, CAST(NULL AS STRING) AS region,
                 CAST(NULL AS STRING) AS project
          FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
          LIMIT 0
        """, dataset_name, staging_table,
             col_list,
             baseline_project, region, table_name);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
          SET staging_tables = ARRAY_CONCAT(staging_tables, [staging_table]);
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_US.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, baseline_project,
             FORMAT('Staging table creation failed (batch %d): ', batch_number)
               || @@error.message, exec_sql, CURRENT_TIMESTAMP());
          CONTINUE;
        END;
      END IF;

      -- ─── Insert this project's snapshot data into current staging table ───
      SET exec_sql = FORMAT("""
        INSERT INTO `%s.%s` (%s, region, project)
        SELECT %s, '%s' AS region, '%s' AS project
        FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
        %s
      """,
      dataset_name, staging_table, col_list,
      col_list, region, project_id,
      project_id, region, table_name,
      time_filter);

      BEGIN
        EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_US.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
           'Staging insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
        CONTINUE;
      END;

      SET batch_count = batch_count + 1;

    END FOR;  -- projects

    -- ─────────────────────────────────────────────────────────────────────
    -- FLUSH: all staging tables → destination
    -- Snapshot = full replace for all projects present in staging.
    -- Safety: backup → delete → insert → cleanup
    -- If insert fails after delete, restore from backup.
    -- ─────────────────────────────────────────────────────────────────────

    IF ARRAY_LENGTH(staging_tables) > 0 THEN

      -- Build UNION ALL across all staging tables
      SET flush_sql = '';
      FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
        SET st = stg_row.f0_;
        IF flush_sql != '' THEN
          SET flush_sql = flush_sql || '\nUNION ALL\n';
        END IF;
        SET flush_sql = flush_sql || FORMAT("""
          SELECT %s, region, project FROM `%s.%s`
        """, col_list, dataset_name, st);
      END FOR;

      -- Check if any staging table has rows
      SET staging_has_rows = 0;
      FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
        SET st = stg_row.f0_;
        EXECUTE IMMEDIATE FORMAT("""
          SELECT COUNT(*) FROM `%s.%s` LIMIT 1
        """, dataset_name, st)
        INTO staging_has_rows;
        IF staging_has_rows > 0 THEN
          SET staging_has_rows = 1;
        END IF;
      END FOR;

      IF staging_has_rows > 0 THEN

        SET backup_table = CONCAT('bkp_', table_name, '_', run_uuid);

        -- Step 1: Backup rows that will be deleted
        SET exec_sql = FORMAT("""
          CREATE TABLE `%s.%s` AS
          SELECT * FROM `%s.%s`
          WHERE region = '%s'
            AND project IN (
              SELECT DISTINCT project FROM (%s)
            )
        """, dataset_name, backup_table,
             dataset_name, dest_table_name,
             region, flush_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_US.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'ALL_PROJECTS',
             'Backup before delete failed — skipping table to protect data: '
               || @@error.message,
             exec_sql, CURRENT_TIMESTAMP());
          FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
            EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
              dataset_name, stg_row.f0_);
          END FOR;
          CONTINUE;
        END;

        -- Step 2: Delete existing rows for projects present in staging
        SET exec_sql = FORMAT("""
          DELETE FROM `%s.%s`
          WHERE region = '%s'
            AND project IN (
              SELECT DISTINCT project FROM (%s)
            )
        """, dataset_name, dest_table_name, region, flush_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_US.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'ALL_PROJECTS',
             'Delete failed — no data lost, skipping table: ' || @@error.message,
             exec_sql, CURRENT_TIMESTAMP());
          EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
            dataset_name, backup_table);
          FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
            EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
              dataset_name, stg_row.f0_);
          END FOR;
          CONTINUE;
        END;

        -- Step 3: Insert new snapshot data from staging
        SET exec_sql = FORMAT("""
          INSERT INTO `%s.%s` (%s, region, project)
          %s
        """, dataset_name, dest_table_name, col_list, flush_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          -- INSERT failed after DELETE — restore from backup
          INSERT INTO `unravel_share_US.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'ALL_PROJECTS',
             'Flush insert failed after delete — attempting restore from '
               || backup_table || ': ' || @@error.message,
             exec_sql, CURRENT_TIMESTAMP());

          BEGIN
            EXECUTE IMMEDIATE FORMAT("""
              INSERT INTO `%s.%s`
              SELECT * FROM `%s.%s`
            """, dataset_name, dest_table_name,
                 dataset_name, backup_table);

            -- Restore succeeded
            EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
              dataset_name, backup_table);

          EXCEPTION WHEN ERROR THEN
            -- CRITICAL: restore also failed — keep backup for manual recovery
            INSERT INTO `unravel_share_US.error_log`
              (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
            VALUES
              (current_run_ts, dest_table_name, 'ALL_PROJECTS',
               'CRITICAL: Restore failed — manual recovery needed from: '
                 || dataset_name || '.' || backup_table
                 || ' | Error: ' || @@error.message,
               NULL, CURRENT_TIMESTAMP());
            -- Do NOT drop backup_table
          END;

          FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
            EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
              dataset_name, stg_row.f0_);
          END FOR;
          CONTINUE;
        END;

        -- Step 4: Everything succeeded — drop backup
        EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
          dataset_name, backup_table);

      END IF;  -- staging_has_rows > 0

      -- ─── Clean up all staging tables ───
      FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
        EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
          dataset_name, stg_row.f0_);
      END FOR;

    END IF;  -- staging_tables not empty

  END FOR;  -- tables

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper: resolves project_ids from projects_table then calls main procedure
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_US_all_projects(
  dataset_name   STRING,
  look_back_days INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  projects_table STRING
)
BEGIN

  DECLARE project_ids ARRAY<STRING>;

  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(DISTINCT project_id)
    FROM `%s`
    WHERE project_id IS NOT NULL AND project_id != ''
  """, projects_table)
  INTO project_ids;

  IF project_ids IS NULL OR ARRAY_LENGTH(project_ids) = 0 THEN
    RAISE USING MESSAGE = "ERROR: No rows present in: " || projects_table;
  END IF;

  CALL unravel_share_US.export_metadata_US(
    dataset_name,
    look_back_days,
    tables,
    region,
    project_ids
  );

END;

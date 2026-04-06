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
  run_ts        TIMESTAMP,
  dest_table    STRING,
  project_id    STRING,
  error_message STRING,
  failed_sql    STRING,
  logged_at     TIMESTAMP
)
PARTITION BY DATE(logged_at)
CLUSTER BY project_id;

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
     RAISE USING MESSAGE = "ERROR: Failed to create projects_table!";
  END;

END;

CREATE OR REPLACE PROCEDURE unravel_share_US.export_billing_data_incremental(
  dataset_name           STRING,
  look_back_days         INT64,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING,
  retention_days         INT64
)
BEGIN

  DECLARE exec_sql        STRING;
  DECLARE last_sync_ts    TIMESTAMP;
  DECLARE current_run_ts  TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE dest_table      STRING DEFAULT 'BILLING_TABLE';
  DECLARE billing_col_list STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  -- ─── Step 1: Create destination table if first run ───
  SET exec_sql = FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.%s`
    PARTITION BY DATE(export_time)
    OPTIONS (partition_expiration_days = %d)
    AS
    SELECT *, CURRENT_TIMESTAMP() AS ingestion_ts
    FROM `%s.%s.%s`
    WHERE FALSE
  """, dataset_name, dest_table, retention_days,
       billing_export_project, billing_dataset, billing_table);

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing DDL failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
    RETURN;
  END;

  -- ─── Step 2: Resolve common columns between source and destination ───
  SET exec_sql = FORMAT("""
    SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
    FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS c
    WHERE c.table_name = '%s'
      AND c.column_name != 'ingestion_ts'
      AND c.column_name IN (
        SELECT column_name
        FROM `%s`.INFORMATION_SCHEMA.COLUMNS
        WHERE table_name = '%s'
      )
  """,
  billing_export_project, billing_dataset, billing_table,
  dataset_name, dest_table);

  BEGIN
    EXECUTE IMMEDIATE exec_sql INTO billing_col_list;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing col_list resolution failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
    RETURN;
  END;

  IF billing_col_list IS NULL THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'billing_col_list is NULL – no column overlap between source and destination',
       NULL, CURRENT_TIMESTAMP());
    RETURN;
  END IF;

  -- ─── Step 3: Find watermark (last synced export_time) ───
  EXECUTE IMMEDIATE FORMAT("""
    SELECT MAX(export_time) FROM `%s.%s`
  """, dataset_name, dest_table)
  INTO last_sync_ts;

  IF last_sync_ts IS NULL THEN
    SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL look_back_days DAY);
  END IF;

  -- ─── Step 4: Incremental insert ───
  SET exec_sql = FORMAT("""
    INSERT INTO `%s.%s` (%s, ingestion_ts)
    SELECT %s, CURRENT_TIMESTAMP()
    FROM `%s.%s.%s`
    WHERE export_time >  TIMESTAMP '%s'
      AND export_time <= TIMESTAMP '%s'
      AND service.id IN (
        '650B-3C82-34DB',
        '16B8-3DDA-9F10',
        'DCC9-8DB9-673F',
        '24E6-581D-38E5'
      )
  """,
  dataset_name, dest_table, billing_col_list,
  billing_col_list,
  billing_export_project, billing_dataset, billing_table,
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_sync_ts),
  FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_US.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing incremental insert failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
  END;

END;


CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_incremental_US(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  project_ids    ARRAY<STRING>,
  retention_days INT64
)
BEGIN

  DECLARE table_name       STRING;
  DECLARE col_list         STRING;
  DECLARE dest_table_name  STRING;
  DECLARE baseline_project STRING;
  DECLARE last_sync_ts     TIMESTAMP;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE partition_clause STRING;
  DECLARE cluster_clause   STRING;
  DECLARE temp_table_name  STRING;
  DECLARE run_uuid         STRING DEFAULT REPLACE(GENERATE_UUID(), '-', '_');
  DECLARE time_col         STRING;
  DECLARE time_filter      STRING;
  DECLARE project_id       STRING;
  DECLARE staging_has_rows INT64;

  -- Batching variables
  DECLARE batch_size       INT64 DEFAULT 1000;
  DECLARE batch_count      INT64;
  DECLARE batch_number     INT64;
  DECLARE staging_table    STRING;
  DECLARE staging_tables   ARRAY<STRING>;
  DECLARE flush_sql        STRING;
  DECLARE st               STRING;

  -- SQL capture variable for error logging
  DECLARE exec_sql         STRING;

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

    SET partition_clause = CASE table_name
      WHEN 'JOBS'          THEN 'PARTITION BY DATE(creation_time)'
      WHEN 'JOBS_TIMELINE' THEN 'PARTITION BY DATE(job_creation_time)'
      ELSE ''
    END;

    SET cluster_clause = CASE table_name
      WHEN 'JOBS'          THEN 'CLUSTER BY project_id, user_email'
      WHEN 'JOBS_TIMELINE' THEN 'CLUSTER BY project_id, user_email'
      ELSE ''
    END;

    -- ─── DDL: create destination if not exists ───
    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.%s`
      %s
      %s
      %s
      AS
      SELECT *, CAST(NULL AS STRING) AS region,
             CAST(NULL AS STRING) AS project,
             CURRENT_TIMESTAMP() AS ingestion_ts
      FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
      LIMIT 0
    """,
    dataset_name, dest_table_name,
    partition_clause, cluster_clause,
    IF(partition_clause != '',
       FORMAT('OPTIONS (partition_expiration_days = %d)', retention_days), ''),
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

      -- ─── Per-project watermark for incremental tables ───
      IF table_name IN ('JOBS', 'JOBS_TIMELINE') THEN

        SET time_col = IF(table_name = 'JOBS', 'creation_time', 'job_creation_time');

        EXECUTE IMMEDIATE FORMAT("""
          SELECT MAX(%s) FROM `%s.%s`
          WHERE project = '%s' AND region = '%s'
        """, time_col, dataset_name, dest_table_name, project_id, region)
        INTO last_sync_ts;

        IF last_sync_ts IS NULL THEN
          SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
        END IF;

        SET time_filter = FORMAT(
          "WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
          time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_sync_ts),
          time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));

      ELSE
        SET time_filter = 'WHERE TRUE';
      END IF;

      -- ─── Insert this project's data into current staging table ───
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
    -- FLUSH: all staging tables → destination in ONE DML
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
        IF staging_has_rows = 0 THEN
          EXECUTE IMMEDIATE FORMAT("""
            SELECT COUNT(*) FROM `%s.%s` LIMIT 1
          """, dataset_name, st)
          INTO staging_has_rows;
          IF staging_has_rows > 0 THEN
            SET staging_has_rows = 1;
          END IF;
        END IF;
      END FOR;

      IF staging_has_rows > 0 THEN

        -- For non-incremental tables, delete existing rows first
        IF table_name NOT IN ('JOBS', 'JOBS_TIMELINE') THEN

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
               'Batched delete before flush failed: ' || @@error.message,
               exec_sql, CURRENT_TIMESTAMP());
            -- Clean up all staging tables and skip
            FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
              EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
                dataset_name, stg_row.f0_);
            END FOR;
            CONTINUE;
          END;
        END IF;

        -- ─── Single INSERT: all staging tables → destination ───
        SET exec_sql = FORMAT("""
          INSERT INTO `%s.%s` (%s, region, project)
          %s
        """, dataset_name, dest_table_name, col_list, flush_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_US.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'ALL_PROJECTS',
             'Final flush to destination failed: ' || @@error.message,
             exec_sql, CURRENT_TIMESTAMP());
        END;

      END IF;

      -- ─── Clean up all staging tables ───
      FOR stg_row IN (SELECT * FROM UNNEST(staging_tables)) DO
        EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",
          dataset_name, stg_row.f0_);
      END FOR;

    END IF;

  END FOR;  -- tables

END;


-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper: resolves project_ids from projects_table then calls main procedure
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_US.export_metadata_incremental_US_all_projects(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  projects_table STRING,
  retention_days INT64
)
BEGIN

  DECLARE project_ids ARRAY<STRING>;

  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(project_id IGNORE NULLS)
    FROM `%s`
  """, projects_table)
  INTO project_ids;

  IF project_ids IS NULL OR ARRAY_LENGTH(project_ids) = 0 THEN
    RAISE USING MESSAGE = "ERROR: No rows present in: " || projects_table;
  END IF;

  CALL unravel_share_US.export_metadata_incremental_US(
    dataset_name,
    lookback_days,
    tables,
    region,
    project_ids,
    retention_days
  );

END;

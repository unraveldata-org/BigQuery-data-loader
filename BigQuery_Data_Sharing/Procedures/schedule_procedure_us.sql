SET @@location = 'US';

CREATE SCHEMA IF NOT EXISTS unravel_share_us_partitioned
  OPTIONS (
      location = 'US'
  );

CREATE SCHEMA IF NOT EXISTS unravel_share_US_projects_list
  OPTIONS (
      location = 'US'
  );


CREATE TABLE IF NOT EXISTS `unravel_share_us_partitioned.error_log`
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

CREATE OR REPLACE PROCEDURE unravel_share_us.migrate_tables_to_partitioned(
  source_dataset  STRING,   -- e.g. 'unravel_share_us'
  target_dataset  STRING,   -- e.g. 'unravel_share_us_partitioned'
  region          STRING    -- e.g. 'US'
)
BEGIN

  DECLARE exec_sql        STRING;
  DECLARE col_list        STRING;
  DECLARE current_run_ts  TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

  -- ── Create target dataset if it doesn't exist ─────────────────────────
  SET exec_sql = FORMAT("""
    CREATE SCHEMA IF NOT EXISTS `%s`
    OPTIONS (location = 'US')
  """, target_dataset);

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    RAISE USING MESSAGE = 'Failed to create target dataset: ' || @@error.message;
  END;

  -- ── Table-level config: partition col, cluster cols, expiry days ───────
  FOR tbl IN (
    SELECT
      table_id,
      partition_col,
      cluster_cols,
      expiry_days
    FROM UNNEST([
  STRUCT('ASSIGNMENTS_US'         AS table_id, CAST(NULL AS STRING)        AS partition_col, 'project_id'             AS cluster_cols, CAST(180 AS INT64) AS expiry_days),
  STRUCT('ASSIGNMENT_CHANGES_US',              'DATE(change_timestamp)',                      'project_id',                             CAST(180 AS INT64)               ),
  STRUCT('BILLING_TABLE',                      'DATE(export_time)',                           NULL,                             CAST(365 AS INT64)               ),
  STRUCT('COLUMNS_US',                         CAST(NULL AS STRING),                          'table_catalog',                          CAST(NULL AS INT64)              ),
  STRUCT('JOBS_TIMELINE_US',                   'DATE(job_creation_time)',                     'project_id, user_email',                 CAST(180 AS INT64)               ),
  STRUCT('JOBS_US',                            'DATE(creation_time)',                         'project_id, user_email',                 CAST(180 AS INT64)               ),
  STRUCT('RESERVATIONS_TIMELINE_US',           'DATE(period_start)',                          'project_id',                             CAST(180 AS INT64)               ),
  STRUCT('RESERVATIONS_US',                    CAST(NULL AS STRING),                          'project_id',                             CAST(NULL AS INT64)              ),
  STRUCT('RESERVATION_CHANGES_US',             'DATE(change_timestamp)',                      'project_id',                             CAST(180 AS INT64)               ),
  STRUCT('SCHEMATA_OPTIONS_US',                CAST(NULL AS STRING),                          'catalog_name',                           CAST(NULL AS INT64)              ),
  STRUCT('TABLES_US',                          CAST(NULL AS STRING),                          'table_catalog',                          CAST(NULL AS INT64)              ),
  STRUCT('TABLE_OPTIONS_US',                   CAST(NULL AS STRING),                          'table_catalog',                          CAST(NULL AS INT64)              ),
  STRUCT('TABLE_STORAGE_US',                   CAST(NULL AS STRING),                          'table_catalog',                          CAST(NULL AS INT64)              ),
  STRUCT('error_log',                          'DATE(logged_at)',                             'project_id',                             CAST(365 AS INT64)               )
])
  ) DO

    -- ── Build col_list from source table ──────────────────────────────────
    SET exec_sql = FORMAT("""
      SELECT STRING_AGG(column_name, ', ' ORDER BY ordinal_position)
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
      WHERE table_catalog = '%s'
        AND table_schema  = '%s'
        AND table_name    = '%s'
    """, region, @@project_id, source_dataset, tbl.table_id);

    BEGIN
      EXECUTE IMMEDIATE exec_sql INTO col_list;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, tbl.table_id, @@project_id,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, tbl.table_id, @@project_id,
         'col_list is NULL – source table missing or empty schema', NULL, CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    -- ── DDL: CREATE TABLE in target dataset ───────────────────────────────
    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.%s`
      %s
      %s
      %s
      AS
      SELECT %s FROM `%s.%s`
      WHERE FALSE
    """,
    target_dataset, tbl.table_id,
    -- PARTITION BY clause
    IF(tbl.partition_col IS NOT NULL,
       FORMAT('PARTITION BY %s', tbl.partition_col), ''),
    -- CLUSTER BY clause
    IF(tbl.cluster_cols IS NOT NULL,
       FORMAT('CLUSTER BY %s', tbl.cluster_cols), ''),
    -- OPTIONS clause (only if partitioned + expiry set)
    IF(tbl.partition_col IS NOT NULL AND tbl.expiry_days IS NOT NULL,
       FORMAT('OPTIONS (partition_expiration_days = %d)', tbl.expiry_days), ''),
    col_list,
    source_dataset, tbl.table_id);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, tbl.table_id, @@project_id,
         'DDL failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    -- ── DML: Copy data from source → target ───────────────────────────────
    SET exec_sql = FORMAT("""
      INSERT INTO `%s.%s` (%s)
      SELECT %s FROM `%s.%s`
    """,
    target_dataset, tbl.table_id, col_list,
    col_list,
    source_dataset, tbl.table_id);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, tbl.table_id, @@project_id,
         'Data copy failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
    END;

  END FOR;

END;


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

CREATE OR REPLACE PROCEDURE unravel_share_us_partitioned.export_billing_data_incremental(
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
    INSERT INTO `unravel_share_us_partitioned.error_log`
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
    INSERT INTO `unravel_share_us_partitioned.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing col_list resolution failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
    RETURN;
  END;

  IF billing_col_list IS NULL THEN
    INSERT INTO `unravel_share_us_partitioned.error_log`
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
    INSERT INTO `unravel_share_us_partitioned.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing incremental insert failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
  END;

END;


CREATE OR REPLACE PROCEDURE unravel_share_us_partitioned.export_metadata_incremental_US(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  project_ids    ARRAY<STRING>,
  retention_days INT64,
  batch_size     INT64
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

  -- Batching variables
  DECLARE batch_count      INT64;
  DECLARE batch_union_sql  STRING;   -- accumulates SELECT fragments for current batch
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

    -- ─── DDL: create destination if not exists ───────────────────────────
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
      INSERT INTO `unravel_share_us_partitioned.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'DDL failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    -- ─── Resolve col_list using baseline project ──────────────────────────
    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);

    SET exec_sql = FORMAT("""
      CREATE OR REPLACE TABLE `%s.%s` AS
      SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
    """, dataset_name, temp_table_name, baseline_project, region, table_name);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_partitioned.error_log`
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
      INSERT INTO `unravel_share_us_partitioned.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, temp_table_name);

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us_partitioned.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list is NULL – no column overlap', NULL, CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────
    -- BATCHED DIRECT INSERT  (50 projects → 1 INSERT per batch)
    -- ─────────────────────────────────────────────────────────────────────

    SET batch_count     = 0;
    SET batch_union_sql = '';

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        INSERT INTO `unravel_share_us_partitioned.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
           'project_id is NULL or empty', NULL, CURRENT_TIMESTAMP());
        CONTINUE;
      END IF;

      -- ─── Per-project watermark for incremental tables ─────────────────
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

      -- ─── Append this project's SELECT fragment to the batch ──────────
      IF batch_union_sql != '' THEN
        SET batch_union_sql = batch_union_sql || '\nUNION ALL\n';
      END IF;

      SET batch_union_sql = batch_union_sql || FORMAT("""
        SELECT %s, '%s' AS region, '%s' AS project
        FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
        %s
      """, col_list, region, project_id,
           project_id, region, table_name,
           time_filter);

      SET batch_count = batch_count + 1;

      -- ─── Flush when batch is full ─────────────────────────────────────
      IF batch_count >= batch_size THEN

        -- For non-incremental tables: DELETE existing rows for these projects first
        IF table_name NOT IN ('JOBS', 'JOBS_TIMELINE') THEN
          SET exec_sql = FORMAT("""
            DELETE FROM `%s.%s`
            WHERE region = '%s'
              AND project IN (
                SELECT DISTINCT project FROM (%s)
              )
          """, dataset_name, dest_table_name, region, batch_union_sql);

          BEGIN
            EXECUTE IMMEDIATE exec_sql;
          EXCEPTION WHEN ERROR THEN
            INSERT INTO `unravel_share_us_partitioned.error_log`
              (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
            VALUES
              (current_run_ts, dest_table_name, 'BATCH',
               'Batch delete failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
            -- Reset and skip this batch
            SET batch_union_sql = '';
            SET batch_count     = 0;
            CONTINUE;
          END;
        END IF;

        -- Single INSERT for entire batch
        SET exec_sql = FORMAT("""
          INSERT INTO `%s.%s` (%s, region, project, ingestion_ts)
          SELECT batch_rows.*, CURRENT_TIMESTAMP()
          FROM (%s) AS batch_rows
        """, dataset_name, dest_table_name, col_list, batch_union_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_us_partitioned.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'BATCH',
             'Batch insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
        END;

        -- Reset batch accumulator
        SET batch_union_sql = '';
        SET batch_count     = 0;

      END IF;

    END FOR;  -- projects

    -- ─── Flush any remaining projects (partial last batch) ───────────────
    IF batch_count > 0 AND batch_union_sql != '' THEN

      IF table_name NOT IN ('JOBS', 'JOBS_TIMELINE') THEN
        SET exec_sql = FORMAT("""
          DELETE FROM `%s.%s`
          WHERE region = '%s'
            AND project IN (
              SELECT DISTINCT project FROM (%s)
            )
        """, dataset_name, dest_table_name, region, batch_union_sql);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_us_partitioned.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'REMAINDER_BATCH',
             'Remainder batch delete failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
          CONTINUE;
        END;
      END IF;

      SET exec_sql = FORMAT("""
        INSERT INTO `%s.%s` (%s, region, project, ingestion_ts)
        SELECT batch_rows.*, CURRENT_TIMESTAMP()
        FROM (%s) AS batch_rows
      """, dataset_name, dest_table_name, col_list, batch_union_sql);

      BEGIN
        EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_partitioned.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, 'REMAINDER_BATCH',
           'Remainder batch insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      END;

    END IF;

  END FOR;  -- tables

END;

-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper: resolves project_ids from projects_table then calls main procedure
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_partitioned.export_metadata_incremental_US_all_projects(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  projects_table STRING,
  retention_days INT64,
  batch_size     INT64
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

  CALL unravel_share_us_partitioned.export_metadata_incremental_US(
    dataset_name,
    lookback_days,
    tables,
    region,
    project_ids,
    retention_days,
    batch_size
  );

END;

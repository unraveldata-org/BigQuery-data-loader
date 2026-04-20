SET @@location = 'US';

CREATE SCHEMA IF NOT EXISTS unravel_share_us_new
  OPTIONS (
      location = 'US'
  );

CREATE SCHEMA IF NOT EXISTS unravel_share_us_projects_list
  OPTIONS (
      location = 'US'
  );


CREATE TABLE IF NOT EXISTS `unravel_share_us_new.error_log`
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

CREATE OR REPLACE PROCEDURE unravel_share_US.migrate_tables_to_new(
  source_dataset  STRING,   -- e.g. 'unravel_share_US'
  target_dataset  STRING,   -- e.g. 'unravel_share_us_new'
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
      INSERT INTO `unravel_share_us_new.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, tbl.table_id, @@project_id,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log`
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
    -- OPTIONS clause (only if new + expiry set)
    IF(tbl.partition_col IS NOT NULL AND tbl.expiry_days IS NOT NULL,
       FORMAT('OPTIONS (partition_expiration_days = %d)', tbl.expiry_days), ''),
    col_list,
    source_dataset, tbl.table_id);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log`
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
      INSERT INTO `unravel_share_us_new.error_log`
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
CREATE OR REPLACE PROCEDURE unravel_share_us_projects_list.create_projects_table(
  dataset_name           STRING,
  billing_export_project STRING,
  billing_dataset        STRING,
  billing_table          STRING
)
BEGIN

  DECLARE table_exists     BOOL    DEFAULT FALSE;
  DECLARE last_export_ts   TIMESTAMP;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE exec_sql         STRING;

  -- ── Validate inputs ──────────────────────────────────────────────────────
  IF billing_export_project IS NULL OR billing_export_project = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_export_project is empty!";
  END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_dataset is empty!";
  END IF;
  IF billing_table IS NULL OR billing_table = '' THEN
    RAISE USING MESSAGE = "ERROR: billing_table is empty!";
  END IF;

  -- ── Check whether projects_table already exists ──────────────────────────
  -- INFORMATION_SCHEMA.TABLES returns a row only if the table is present;
  -- INTO receives NULL if no row matches, so we default-to-FALSE safely.
  BEGIN
  -- Try to get the watermark; if this fails, the table doesn't exist
  EXECUTE IMMEDIATE FORMAT("SELECT MAX(last_seen) FROM `%s.projects_table`", dataset_name) 
  INTO last_export_ts;
  SET table_exists = TRUE;
EXCEPTION WHEN ERROR THEN
  -- If we land here, the table likely doesn't exist
  SET table_exists = FALSE;
END;

  -- ════════════════════════════════════════════════════════════════════════
  -- FIRST RUN — table does not exist yet
  -- Create it and load all project IDs with no time filter.
  -- ════════════════════════════════════════════════════════════════════════
  IF NOT table_exists THEN

    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.projects_table`
      (
        project_id   STRING NOT NULL,
        first_seen   TIMESTAMP,
        last_seen    TIMESTAMP
      )
      CLUSTER BY project_id
    """, dataset_name);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      RAISE USING MESSAGE = "ERROR: Failed to create projects_table – " || @@error.message;
    END;

    -- Full initial load — no export_time filter
    SET exec_sql = FORMAT("""
      INSERT INTO `%s.projects_table` (project_id, first_seen, last_seen)
      SELECT
        project.id                AS project_id,
        MIN(export_time)          AS first_seen,
        MAX(export_time)          AS last_seen
      FROM `%s.%s.%s`
      WHERE service.id IN (
        '650B-3C82-34DB',
        '16B8-3DDA-9F10',
        'DCC9-8DB9-673F',
        '24E6-581D-38E5'
      )
        AND project.id IS NOT NULL
      GROUP BY project.id
    """,
    dataset_name,
    billing_export_project, billing_dataset, billing_table);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      RAISE USING MESSAGE = "ERROR: Failed to populate projects_table on first run – " || @@error.message;
    END;

  -- ════════════════════════════════════════════════════════════════════════
  -- SUBSEQUENT RUNS — table already exists
  -- Watermark = MAX(last_seen) already recorded in projects_table.
  -- Scan only billing rows with export_time > watermark, then MERGE
  -- so that new project IDs are inserted and existing ones get their
  -- last_seen timestamp bumped.
  -- ════════════════════════════════════════════════════════════════════════
  ELSE

    -- Derive watermark from the projects_table itself (last_seen column)
    EXECUTE IMMEDIATE FORMAT("""
      SELECT MAX(last_seen) FROM `%s.projects_table`
    """, dataset_name)
    INTO last_export_ts;

    -- If somehow last_seen is all NULL fall back to a full re-scan
    IF last_export_ts IS NULL THEN
      SET last_export_ts = TIMESTAMP('1970-01-01 00:00:00 UTC');
    END IF;

    SET exec_sql = FORMAT("""
      MERGE `%s.projects_table` AS tgt
      USING (
        SELECT
          project.id       AS project_id,
          MIN(export_time) AS first_seen,
          MAX(export_time) AS last_seen
        FROM `%s.%s.%s`
        WHERE _PARTITIONDATE >= DATE(TIMESTAMP '%s')
          AND service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5')
          AND export_time >  TIMESTAMP '%s'
          AND export_time <= TIMESTAMP '%s'
          AND project.id IS NOT NULL
        GROUP BY 1
      ) AS src
      ON tgt.project_id = src.project_id
      WHEN MATCHED AND src.last_seen > tgt.last_seen THEN
        UPDATE SET last_seen = src.last_seen
      WHEN NOT MATCHED THEN
        INSERT (project_id, first_seen, last_seen)
        VALUES (src.project_id, src.first_seen, src.last_seen)
    """,
    dataset_name,
    billing_export_project, billing_dataset, billing_table,
    FORMAT_TIMESTAMP('%F', last_export_ts), -- For _PARTITIONDATE
    FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_export_ts),
    FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      RAISE USING MESSAGE = "ERROR: Failed to merge incremental project IDs – " || @@error.message;
    END;

  END IF;

END;

CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_billing_data_incremental(
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
    INSERT INTO `unravel_share_us_new.error_log`
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
    INSERT INTO `unravel_share_us_new.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing col_list resolution failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
    RETURN;
  END;

  IF billing_col_list IS NULL THEN
    INSERT INTO `unravel_share_us_new.error_log`
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
    INSERT INTO `unravel_share_us_new.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table, billing_export_project,
       'Billing incremental insert failed: ' || @@error.message,
       exec_sql, CURRENT_TIMESTAMP());
  END;

END;


-- ─────────────────────────────────────────────────────────────────────────────
-- export_metadata_incremental_US
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_metadata_incremental_US(
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
  DECLARE last_sync_date   DATE;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE partition_clause STRING;
  DECLARE cluster_clause   STRING;
  DECLARE temp_table_name  STRING;
  DECLARE run_uuid         STRING DEFAULT REPLACE(GENERATE_UUID(), '-', '_');
  DECLARE time_col         STRING;
  DECLARE time_filter      STRING;
  DECLARE project_id       STRING;
  DECLARE is_by_org        BOOL;

  DECLARE batch_count      INT64;
  DECLARE batch_union_sql  STRING;
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
    SET is_by_org       = ENDS_WITH(table_name, 'BY_ORGANIZATION');
    SET dest_table_name = CONCAT(table_name, '_', region);

    -- ── Partition clause ──────────────────────────────────────────────────
    SET partition_clause = CASE table_name
      WHEN 'JOBS'                               THEN 'PARTITION BY DATE(creation_time)'
      WHEN 'JOBS_BY_ORGANIZATION'               THEN 'PARTITION BY DATE(creation_time)'
      WHEN 'JOBS_TIMELINE'                      THEN 'PARTITION BY DATE(job_creation_time)'
      WHEN 'RESERVATIONS_TIMELINE'              THEN 'PARTITION BY DATE(period_start)'
      WHEN 'RESERVATION_CHANGES'                THEN 'PARTITION BY DATE(change_timestamp)'
      WHEN 'CAPACITY_COMMITMENT_CHANGES'        THEN 'PARTITION BY DATE(change_timestamp)'
      WHEN 'ASSIGNMENT_CHANGES'                 THEN 'PARTITION BY DATE(change_timestamp)'
      WHEN 'SHARED_DATASET_USAGE'               THEN 'PARTITION BY DATE(job_start_time)'
      WHEN 'TABLE_STORAGE_USAGE_TIMELINE'       THEN 'PARTITION BY usage_date'
      WHEN 'STREAMING_TIMELINE_BY_ORGANIZATION' THEN 'PARTITION BY DATE(start_timestamp)'
      ELSE ''
    END;

    -- ── Cluster clause ────────────────────────────────────────────────────
    SET cluster_clause = CASE table_name
      WHEN 'JOBS'                               THEN 'CLUSTER BY project_id, user_email'
      WHEN 'JOBS_BY_ORGANIZATION'               THEN 'CLUSTER BY project_id, user_email'
      WHEN 'JOBS_TIMELINE'                      THEN 'CLUSTER BY project_id, user_email'
      WHEN 'RESERVATIONS_TIMELINE'              THEN 'CLUSTER BY project_id'
      WHEN 'RESERVATION_CHANGES'                THEN 'CLUSTER BY project_id'
      WHEN 'CAPACITY_COMMITMENT_CHANGES'        THEN 'CLUSTER BY project_id'
      WHEN 'ASSIGNMENT_CHANGES'                 THEN 'CLUSTER BY project_id'
      WHEN 'SHARED_DATASET_USAGE'               THEN 'CLUSTER BY project_id, dataset_id'
      WHEN 'TABLE_STORAGE_USAGE_TIMELINE'       THEN 'CLUSTER BY table_catalog'
      WHEN 'STREAMING_TIMELINE_BY_ORGANIZATION' THEN 'CLUSTER BY dataset_id, table_id'
      ELSE ''
    END;

    -- ── DDL: create destination table if needed ───────────────────────────
    IF is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s`
        %s
        %s
        %s
        AS
        SELECT *, CAST(NULL AS STRING) AS region,
               CURRENT_TIMESTAMP() AS ingestion_ts
        FROM `region-%s`.INFORMATION_SCHEMA.%s
        LIMIT 0
      """,
      dataset_name, dest_table_name,
      partition_clause, cluster_clause,
      IF(partition_clause != '',
         FORMAT('OPTIONS (partition_expiration_days = %d)', retention_days), ''),
      region, table_name);
    ELSE
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
    END IF;

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'DDL failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    -- ── Resolve col_list ──────────────────────────────────────────────────
    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);

    IF is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE OR REPLACE TABLE `%s.%s` AS
        SELECT * FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name, temp_table_name, region, table_name);
    ELSE
      SET exec_sql = FORMAT("""
        CREATE OR REPLACE TABLE `%s.%s` AS
        SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name, temp_table_name, baseline_project, region, table_name);
    END IF;

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log`
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
      INSERT INTO `unravel_share_us_new.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, temp_table_name);

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list is NULL – no column overlap', NULL, CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    -- ═════════════════════════════════════════════════════════════════════
    -- BY_ORGANIZATION path
    -- ═════════════════════════════════════════════════════════════════════
    IF is_by_org THEN

      SET time_col    = NULL;
      SET time_filter = 'WHERE TRUE';

      -- Assign time_col for each incrementally-tracked BY_ORG view
      IF table_name = 'STREAMING_TIMELINE_BY_ORGANIZATION' THEN
        SET time_col = 'start_timestamp';
      ELSEIF table_name = 'RECOMMENDATIONS_BY_ORGANIZATION' THEN
        SET time_col = 'last_updated_time';
      ELSEIF table_name = 'JOBS_BY_ORGANIZATION' THEN
        SET time_col = 'creation_time';
      END IF;

      IF time_col IS NOT NULL THEN

        -- Incremental: watermark from last loaded row for this region
        EXECUTE IMMEDIATE FORMAT("""
          SELECT MAX(%s) FROM `%s.%s`
          WHERE region = '%s'
        """, time_col, dataset_name, dest_table_name, region)
        INTO last_sync_ts;

        IF last_sync_ts IS NULL THEN
          SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
        END IF;

        SET time_filter = FORMAT(
          "WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
          time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_sync_ts),
          time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));

      ELSE

        -- Non-incremental BY_ORG view: full replace for this region
        SET exec_sql = FORMAT("""
          DELETE FROM `%s.%s` WHERE region = '%s'
        """, dataset_name, dest_table_name, region);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_us_new.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'BY_ORG',
             'BY_ORG delete failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
          CONTINUE;
        END;

      END IF;

      SET exec_sql = FORMAT("""
        INSERT INTO `%s.%s` (%s, region, ingestion_ts)
        SELECT %s, '%s', CURRENT_TIMESTAMP()
        FROM `region-%s`.INFORMATION_SCHEMA.%s
        %s
      """, dataset_name, dest_table_name, col_list,
           col_list, region,
           region, table_name,
           time_filter);

      BEGIN
        EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, 'BY_ORG',
           'BY_ORG insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      END;

      CONTINUE;  -- skip per-project batching below

    END IF;

    -- ═════════════════════════════════════════════════════════════════════
    -- Per-project batched path
    -- ═════════════════════════════════════════════════════════════════════

    SET batch_count     = 0;
    SET batch_union_sql = '';

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO

      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        INSERT INTO `unravel_share_us_new.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, project_id,
           'project_id is NULL or empty', NULL, CURRENT_TIMESTAMP());
        CONTINUE;
      END IF;

      -- ── Per-project watermark / time-filter ──────────────────────────
      --
      --  Group A  TIMESTAMP cols — pure append, watermark per project:
      --           JOBS, JOBS_TIMELINE,
      --           RESERVATIONS_TIMELINE, RESERVATION_CHANGES,
      --           CAPACITY_COMMITMENT_CHANGES, ASSIGNMENT_CHANGES,
      --           SHARED_DATASET_USAGE, INSIGHTS
      --
      --  Group B  DATE col — pure append, watermark per project:
      --           TABLE_STORAGE_USAGE_TIMELINE (usage_date)
      --
      --  Everything else — full replace (DELETE + INSERT)
      --
      IF table_name IN (
            'JOBS',
            'JOBS_TIMELINE',
            'RESERVATIONS_TIMELINE',
            'RESERVATION_CHANGES',
            'CAPACITY_COMMITMENT_CHANGES',
            'ASSIGNMENT_CHANGES',
            'SHARED_DATASET_USAGE',
            'INSIGHTS'
          ) THEN

        SET time_col = CASE table_name
          WHEN 'JOBS'                        THEN 'creation_time'
          WHEN 'JOBS_TIMELINE'               THEN 'job_creation_time'
          WHEN 'RESERVATIONS_TIMELINE'       THEN 'period_start'
          WHEN 'RESERVATION_CHANGES'         THEN 'change_timestamp'
          WHEN 'CAPACITY_COMMITMENT_CHANGES' THEN 'change_timestamp'
          WHEN 'ASSIGNMENT_CHANGES'          THEN 'change_timestamp'
          WHEN 'SHARED_DATASET_USAGE'        THEN 'job_start_time'
          WHEN 'INSIGHTS'                    THEN 'last_updated_time'
        END;

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

      ELSEIF table_name = 'TABLE_STORAGE_USAGE_TIMELINE' THEN

        EXECUTE IMMEDIATE FORMAT("""
          SELECT MAX(usage_date) FROM `%s.%s`
          WHERE project = '%s' AND region = '%s'
        """, dataset_name, dest_table_name, project_id, region)
        INTO last_sync_date;

        IF last_sync_date IS NULL THEN
          SET last_sync_date = DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days DAY);
        END IF;

        SET time_filter = FORMAT(
          "WHERE usage_date > DATE '%s' AND usage_date <= DATE '%s'",
          FORMAT_DATE('%F', last_sync_date),
          FORMAT_DATE('%F', CURRENT_DATE()));

      ELSE
        SET time_filter = 'WHERE TRUE';
      END IF;

      -- ── Append this project's SELECT to the batch ─────────────────────
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

      -- ── Flush when batch is full ──────────────────────────────────────
      IF batch_count >= batch_size THEN

        -- Timeseries tables are append-only — skip the DELETE
        IF table_name NOT IN (
              'JOBS',
              'JOBS_TIMELINE',
              'RESERVATIONS_TIMELINE',
              'RESERVATION_CHANGES',
              'CAPACITY_COMMITMENT_CHANGES',
              'ASSIGNMENT_CHANGES',
              'SHARED_DATASET_USAGE',
              'INSIGHTS',
              'TABLE_STORAGE_USAGE_TIMELINE'
            ) THEN

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
            INSERT INTO `unravel_share_us_new.error_log`
              (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
            VALUES
              (current_run_ts, dest_table_name, 'BATCH',
               'Batch delete failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
            SET batch_union_sql = '';
            SET batch_count     = 0;
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
          INSERT INTO `unravel_share_us_new.error_log`
            (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
          VALUES
            (current_run_ts, dest_table_name, 'BATCH',
             'Batch insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
        END;

        SET batch_union_sql = '';
        SET batch_count     = 0;

      END IF;

    END FOR;  -- projects

    -- ── Flush remainder ───────────────────────────────────────────────────
    IF batch_count > 0 AND batch_union_sql != '' THEN

      IF table_name NOT IN (
            'JOBS',
            'JOBS_TIMELINE',
            'RESERVATIONS_TIMELINE',
            'RESERVATION_CHANGES',
            'CAPACITY_COMMITMENT_CHANGES',
            'ASSIGNMENT_CHANGES',
            'SHARED_DATASET_USAGE',
            'INSIGHTS',
            'TABLE_STORAGE_USAGE_TIMELINE'
          ) THEN

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
          INSERT INTO `unravel_share_us_new.error_log`
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
        INSERT INTO `unravel_share_us_new.error_log`
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
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_metadata_incremental_US_all_projects(
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

  CALL unravel_share_us_new.export_metadata_incremental_US(
    dataset_name,
    lookback_days,
    tables,
    region,
    project_ids,
    retention_days,
    batch_size
  );

END;

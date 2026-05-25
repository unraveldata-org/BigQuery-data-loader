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

  -- ═════════════════════════════════════════════════════════════════════
  -- ALL DECLARE statements must come first (BigQuery script rule)
  -- ═════════════════════════════════════════════════════════════════════

  -- Per-table config
  -- strategy: one of 'INCREMENTAL_APPEND', 'SNAPSHOT_MERGE', 'AUDIT_APPEND'
  -- time_col: timestamp/date column for watermark (INCREMENTAL_APPEND, AUDIT_APPEND)
  -- time_col_type: 'TIMESTAMP' or 'DATE' (affects watermark predicate)
  -- merge_keys: comma-separated natural-key columns (SNAPSHOT_MERGE only)
  -- partition_col_expr: PARTITION BY expression (e.g. 'DATE(creation_time)')
  -- cluster_cols: CLUSTER BY columns
  -- is_by_org: TRUE if source is region-<region>.INFORMATION_SCHEMA.X (no project prefix)
  DECLARE config ARRAY<STRUCT<
    table_name        STRING,
    strategy          STRING,
    time_col          STRING,
    time_col_type     STRING,
    merge_keys        STRING,
    partition_col_expr STRING,
    cluster_cols      STRING,
    is_by_org         BOOL
  >>;

  -- Working variables
  DECLARE current_table     STRING;  -- renamed from table_name to avoid shadowing struct field
  DECLARE cfg               STRUCT<
    table_name STRING, strategy STRING, time_col STRING, time_col_type STRING,
    merge_keys STRING, partition_col_expr STRING, cluster_cols STRING, is_by_org BOOL>;
  DECLARE col_list          STRING;
  DECLARE dest_table_name   STRING;
  DECLARE baseline_project  STRING;
  DECLARE last_sync_ts      TIMESTAMP;
  DECLARE last_sync_date    DATE;
  DECLARE current_run_ts    TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE partition_clause  STRING;
  DECLARE cluster_clause    STRING;
  DECLARE temp_table_name   STRING;
  DECLARE run_uuid          STRING DEFAULT REPLACE(GENERATE_UUID(), '-', '_');
  DECLARE time_filter       STRING;
  DECLARE project_id        STRING;
  DECLARE exec_sql          STRING;

  -- Batch accumulators
  DECLARE batch_count       INT64;
  DECLARE batch_union_sql   STRING;
  DECLARE batch_projects    ARRAY<STRING>;

  -- ═════════════════════════════════════════════════════════════════════
  -- Statements begin here
  -- ═════════════════════════════════════════════════════════════════════

  -- Populate config
  SET config = [
    -- ── Per-project incremental append (time watermark) ──────────────────
    STRUCT('JOBS'                        AS table_name, 'INCREMENTAL_APPEND' AS strategy, 'creation_time'     AS time_col, 'TIMESTAMP' AS time_col_type, CAST(NULL AS STRING) AS merge_keys, 'DATE(creation_time)'     AS partition_col_expr, 'project_id, user_email' AS cluster_cols, FALSE AS is_by_org),
    STRUCT('JOBS_TIMELINE',                'INCREMENTAL_APPEND',                          'job_creation_time',             'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(job_creation_time)',                       'project_id, user_email',                  FALSE),
    STRUCT('RESERVATIONS_TIMELINE',        'INCREMENTAL_APPEND',                          'period_start',                  'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(period_start)',                            'project_id',                              FALSE),
    STRUCT('TABLE_STORAGE_USAGE_TIMELINE', 'INCREMENTAL_APPEND',                          'usage_date',                    'DATE',                       CAST(NULL AS STRING),                     'usage_date',                                    'table_catalog',                           FALSE),

    -- ── Audit / change logs (append with time watermark) ─────────────────
    STRUCT('RESERVATION_CHANGES',          'AUDIT_APPEND',                                'change_timestamp',              'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(change_timestamp)',                        'project_id',                              FALSE),
    STRUCT('CAPACITY_COMMITMENT_CHANGES',  'AUDIT_APPEND',                                'change_timestamp',              'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(change_timestamp)',                        'project_id',                              FALSE),
    STRUCT('ASSIGNMENT_CHANGES',           'AUDIT_APPEND',                                'change_timestamp',              'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(change_timestamp)',                        'project_id',                              FALSE),
    STRUCT('SHARED_DATASET_USAGE',         'AUDIT_APPEND',                                'job_start_time',                'TIMESTAMP',                  CAST(NULL AS STRING),                     'DATE(job_start_time)',                          'project_id, dataset_id',                  FALSE),

    -- ── Snapshot (MERGE with natural key) — schema metadata ──────────────
    STRUCT('TABLES',                       'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name',                                 CAST(NULL AS STRING), 'table_catalog', FALSE),
    STRUCT('VIEWS',                        'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name',                                 CAST(NULL AS STRING), 'table_catalog', FALSE),
    STRUCT('MATERIALIZED_VIEWS',           'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name',                                 CAST(NULL AS STRING), 'table_catalog', FALSE),
    STRUCT('TABLE_OPTIONS',                'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name, option_name',                    CAST(NULL AS STRING), 'table_catalog', FALSE),
    STRUCT('TABLE_STORAGE',                'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name',                                 CAST(NULL AS STRING), 'table_catalog', FALSE),
    STRUCT('COLUMNS',                      'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'table_catalog, table_schema, table_name, column_name',                    CAST(NULL AS STRING), 'table_catalog', FALSE),

    -- ── Snapshot — schema-level metadata ─────────────────────────────────
    STRUCT('SCHEMATA',                     'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'catalog_name, schema_name, location',                                               CAST(NULL AS STRING), 'catalog_name',  FALSE),
    STRUCT('SCHEMATA_OPTIONS',             'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'catalog_name, schema_name, option_name',                                  CAST(NULL AS STRING), 'catalog_name',  FALSE),
    STRUCT('SCHEMATA_LINKS',               'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'catalog_name, schema_name, linked_schema_catalog_number, linked_schema_name',    CAST(NULL AS STRING), 'catalog_name',  FALSE),
    STRUCT('SCHEMATA_REPLICAS',            'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'catalog_name, schema_name, replica_name, location',                                 CAST(NULL AS STRING), 'catalog_name',  FALSE),
    STRUCT('SCHEMATA_REPLICAS_BY_FAILOVER_RESERVATION', 'SNAPSHOT_MERGE',                  CAST(NULL AS STRING),            CAST(NULL AS STRING),         'catalog_name, schema_name, replica_name, failover_reservation_name',                                 CAST(NULL AS STRING), 'catalog_name',  FALSE),

    -- ── Snapshot — reservation/capacity state ────────────────────────────
    STRUCT('ASSIGNMENTS',                  'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'project_id, assignment_id, job_type',                                               CAST(NULL AS STRING), 'project_id',    FALSE),
    STRUCT('RESERVATIONS',                 'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'project_id, reservation_name',                                            CAST(NULL AS STRING), 'project_id',    FALSE),
    STRUCT('CAPACITY_COMMITMENTS',         'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'project_id, capacity_commitment_id',                                               CAST(NULL AS STRING), 'project_id',    FALSE),

    -- ── Snapshot — insights (stateful; merge, don't append) ──────────────
    STRUCT('INSIGHTS',                     'SNAPSHOT_MERGE',                              CAST(NULL AS STRING),            CAST(NULL AS STRING),         'project_id, subtype, insight_id',                CAST(NULL AS STRING), 'project_id',    FALSE),

    -- ── BY_ORGANIZATION views — time-based incremental append ────────────
    STRUCT('JOBS_BY_ORGANIZATION',               'INCREMENTAL_APPEND', 'creation_time',     'TIMESTAMP', CAST(NULL AS STRING), 'DATE(creation_time)',     'project_id, user_email', TRUE),
    STRUCT('JOBS_TIMELINE_BY_ORGANIZATION',      'INCREMENTAL_APPEND', 'job_creation_time', 'TIMESTAMP', CAST(NULL AS STRING), 'DATE(job_creation_time)', 'project_id, user_email', TRUE),
    STRUCT('STREAMING_TIMELINE_BY_ORGANIZATION', 'INCREMENTAL_APPEND', 'start_timestamp',   'TIMESTAMP', CAST(NULL AS STRING), 'DATE(start_timestamp)',   'project_id, dataset_id, table_id',   TRUE),
    STRUCT('WRITE_API_TIMELINE_BY_ORGANIZATION', 'INCREMENTAL_APPEND', 'start_timestamp',   'TIMESTAMP', CAST(NULL AS STRING), 'DATE(start_timestamp)',   'project_id, dataset_id, table_id',             TRUE),

    -- ── BY_ORGANIZATION — stateful (recommendations): MERGE on natural key ──
    -- Uses SNAPSHOT_MERGE strategy with is_by_org=TRUE; _flush_batch handles
    -- the BY_ORG merge path (no project column in key, source scanned once
    -- from region-level view).
    STRUCT('RECOMMENDATIONS_BY_ORGANIZATION',    'SNAPSHOT_MERGE',     CAST(NULL AS STRING), CAST(NULL AS STRING),
           'project_id, recommender, subtype, recommendation_id',
           CAST(NULL AS STRING), 'project_id, recommender', TRUE)
  ];

  -- ── Input validation ──────────────────────────────────────────────────
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

  -- ═════════════════════════════════════════════════════════════════════
  -- Main loop: one iteration per requested table
  -- ═════════════════════════════════════════════════════════════════════
  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

    SET current_table = table_row.f0_;

    -- Lookup config for this table
    -- Note: use current_table (not table_name) to avoid shadowing c.table_name
    SET cfg = (
      SELECT AS STRUCT * FROM UNNEST(config) c WHERE c.table_name = current_table LIMIT 1
    );

    IF cfg IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, current_table, baseline_project,
         'No config entry for table: ' || current_table, NULL, CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    SET dest_table_name = CONCAT(current_table, '_', region);

    SET partition_clause = IF(cfg.partition_col_expr IS NOT NULL,
      FORMAT('PARTITION BY %s', cfg.partition_col_expr), '');
    SET cluster_clause = IF(cfg.cluster_cols IS NOT NULL,
      FORMAT('CLUSTER BY %s', cfg.cluster_cols), '');

    -- ── DDL: create destination table if needed ─────────────────────────
    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s`
        %s %s %s
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
      region, current_table);
    ELSE
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s`
        %s %s %s
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
      baseline_project, region, current_table);
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

    -- ── Resolve col_list (intersection of source & destination columns) ──
    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);

    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE OR REPLACE TABLE `%s.%s` AS
        SELECT * FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name, temp_table_name, region, current_table);
    ELSE
      SET exec_sql = FORMAT("""
        CREATE OR REPLACE TABLE `%s.%s` AS
        SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name, temp_table_name, baseline_project, region, current_table);
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
    IF cfg.is_by_org THEN

      -- ── BY_ORG + SNAPSHOT_MERGE: delegate to _flush_batch ─────────────
      IF cfg.strategy = 'SNAPSHOT_MERGE' THEN

        -- Build the "batch" as a single SELECT from the region-level view
        SET batch_union_sql = FORMAT("""
          SELECT %s, '%s' AS region
          FROM `region-%s`.INFORMATION_SCHEMA.%s
        """, col_list, region, region, current_table);

        CALL unravel_share_us_new._flush_batch(
          dataset_name, dest_table_name, col_list, region,
          batch_union_sql,
          CAST([] AS ARRAY<STRING>),  -- batch_projects: unused for BY_ORG merge
          cfg.strategy, cfg.merge_keys,
          TRUE,                        -- is_by_org
          current_run_ts);

        CONTINUE;  -- next table
      END IF;

      -- ── BY_ORG + INCREMENTAL_APPEND (and legacy non-incremental fallback) ──
      IF cfg.time_col IS NOT NULL THEN
        EXECUTE IMMEDIATE FORMAT("""
          SELECT MAX(%s) FROM `%s.%s`
          WHERE region = '%s'
        """, cfg.time_col, dataset_name, dest_table_name, region)
        INTO last_sync_ts;

        IF last_sync_ts IS NULL THEN
          SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
        END IF;

        SET time_filter = FORMAT(
          "WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
          cfg.time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_sync_ts),
          cfg.time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));
      ELSE
        -- Non-incremental BY_ORG without merge keys: full replace for this region
        -- (kept for backward compatibility; prefer SNAPSHOT_MERGE going forward)
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

        SET time_filter = 'WHERE TRUE';
      END IF;

      SET exec_sql = FORMAT("""
        INSERT INTO `%s.%s` (%s, region, ingestion_ts)
        SELECT %s, '%s', CURRENT_TIMESTAMP()
        FROM `region-%s`.INFORMATION_SCHEMA.%s
        %s
      """, dataset_name, dest_table_name, col_list,
           col_list, region,
           region, current_table,
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

      CONTINUE;  -- next table
    END IF;

    -- ═════════════════════════════════════════════════════════════════════
    -- Per-project batched path
    -- ═════════════════════════════════════════════════════════════════════

    SET batch_count     = 0;
    SET batch_union_sql = '';
    SET batch_projects  = [];

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

      -- ── Resolve per-project time_filter ────────────────────────────────
      IF cfg.strategy IN ('INCREMENTAL_APPEND', 'AUDIT_APPEND') THEN

        IF cfg.time_col_type = 'DATE' THEN
          EXECUTE IMMEDIATE FORMAT("""
            SELECT MAX(%s) FROM `%s.%s`
            WHERE project = '%s' AND region = '%s'
          """, cfg.time_col, dataset_name, dest_table_name, project_id, region)
          INTO last_sync_date;

          IF last_sync_date IS NULL THEN
            SET last_sync_date = DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days DAY);
          END IF;

          SET time_filter = FORMAT(
            "WHERE %s > DATE '%s' AND %s <= DATE '%s'",
            cfg.time_col, FORMAT_DATE('%F', last_sync_date),
            cfg.time_col, FORMAT_DATE('%F', CURRENT_DATE()));
        ELSE
          -- TIMESTAMP
          EXECUTE IMMEDIATE FORMAT("""
            SELECT MAX(%s) FROM `%s.%s`
            WHERE project = '%s' AND region = '%s'
          """, cfg.time_col, dataset_name, dest_table_name, project_id, region)
          INTO last_sync_ts;

          IF last_sync_ts IS NULL THEN
            SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY);
          END IF;

          SET time_filter = FORMAT(
            "WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
            cfg.time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', last_sync_ts),
            cfg.time_col, FORMAT_TIMESTAMP('%F %H:%M:%E6S', current_run_ts));
        END IF;

      ELSE
        -- SNAPSHOT_MERGE: no time filter
        SET time_filter = 'WHERE TRUE';
      END IF;

      -- ── Append to batch ────────────────────────────────────────────────
      IF batch_union_sql != '' THEN
        SET batch_union_sql = batch_union_sql || '\nUNION ALL\n';
      END IF;

      SET batch_union_sql = batch_union_sql || FORMAT("""
        SELECT %s, '%s' AS region, '%s' AS project
        FROM `%s.region-%s`.INFORMATION_SCHEMA.%s
        %s
      """, col_list, region, project_id,
           project_id, region, current_table,
           time_filter);

      SET batch_projects = ARRAY_CONCAT(batch_projects, [project_id]);
      SET batch_count = batch_count + 1;

      -- ── Flush when batch full ──────────────────────────────────────────
      IF batch_count >= batch_size THEN
        CALL unravel_share_us_new._flush_batch(
          dataset_name, dest_table_name, col_list, region,
          batch_union_sql, batch_projects, cfg.strategy, cfg.merge_keys,
          FALSE,  -- is_by_org
          current_run_ts);
        SET batch_union_sql = '';
        SET batch_projects  = [];
        SET batch_count     = 0;
      END IF;

    END FOR;  -- projects

    -- ── Flush remainder ───────────────────────────────────────────────────
    IF batch_count > 0 AND batch_union_sql != '' THEN
      CALL unravel_share_us_new._flush_batch(
        dataset_name, dest_table_name, col_list, region,
        batch_union_sql, batch_projects, cfg.strategy, cfg.merge_keys,
        FALSE,  -- is_by_org
        current_run_ts);
    END IF;

  END FOR;  -- tables

END;


-- ─────────────────────────────────────────────────────────────────────────────
-- Helper procedure: flush a single batch
--
-- Strategy-aware & BY_ORG-aware:
--
--   INCREMENTAL_APPEND / AUDIT_APPEND
--     Plain INSERT. For per-project: inserts (col_list, region, project, ingestion_ts).
--     (This procedure is only called for per-project append paths; BY_ORG append
--      is handled inline in the main procedure.)
--
--   SNAPSHOT_MERGE, is_by_org = FALSE
--     MERGE on (region, project, <merge_keys>), scoped via batch_projects,
--     with WHEN NOT MATCHED BY SOURCE … DELETE to drop vanished rows.
--
--   SNAPSHOT_MERGE, is_by_org = TRUE
--     MERGE on (region, <merge_keys>), scoped by region only (no project column),
--     with WHEN NOT MATCHED BY SOURCE … DELETE for this region. batch_projects
--     is ignored.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._flush_batch(
  dataset_name     STRING,
  dest_table_name  STRING,
  col_list         STRING,
  region           STRING,
  batch_union_sql  STRING,
  batch_projects   ARRAY<STRING>,
  strategy         STRING,
  merge_keys       STRING,
  is_by_org        BOOL,
  current_run_ts   TIMESTAMP
)
BEGIN

  DECLARE exec_sql    STRING;
  DECLARE on_clause   STRING;
  DECLARE set_clause  STRING;
  DECLARE insert_cols STRING;
  DECLARE insert_vals STRING;
  DECLARE source_scope STRING;  -- identifies the caller for error_log

  SET source_scope = IF(is_by_org, 'BY_ORG_MERGE', 'BATCH');

  IF strategy IN ('INCREMENTAL_APPEND', 'AUDIT_APPEND') THEN

    -- Append path is per-project only (BY_ORG append is handled in main proc).
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
        (current_run_ts, dest_table_name, source_scope,
         'Append batch insert failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
    END;

  ELSEIF strategy = 'SNAPSHOT_MERGE' THEN

    IF is_by_org THEN

      -- ── BY_ORG MERGE (no project column) ─────────────────────────────
      -- ON clause: tgt.region = src.region AND tgt.k1 = src.k1 AND ...
      SET on_clause = 'tgt.region = src.region';
      SET on_clause = (
        SELECT on_clause || ' AND ' || STRING_AGG(FORMAT('tgt.%s = src.%s', k, k), ' AND ')
        FROM UNNEST(SPLIT(merge_keys, ', ')) AS k
      );

      -- UPDATE SET: every non-key, non-meta column + ingestion_ts
      SET set_clause = (
        SELECT STRING_AGG(FORMAT('%s = src.%s', c, c), ', ')
        FROM UNNEST(SPLIT(col_list, ', ')) AS c
      );
      SET set_clause = set_clause || ', ingestion_ts = CURRENT_TIMESTAMP()';

      -- INSERT column list and VALUES (no project column for BY_ORG tables)
      SET insert_cols = col_list || ', region, ingestion_ts';
      SET insert_vals = (
        SELECT STRING_AGG(FORMAT('src.%s', c), ', ')
        FROM UNNEST(SPLIT(col_list, ', ')) AS c
      );
      SET insert_vals = insert_vals || ', src.region, CURRENT_TIMESTAMP()';

      -- DELETE-orphans scope: this region only
      SET exec_sql = FORMAT("""
        MERGE `%s.%s` AS tgt
        USING (%s) AS src
        ON %s
        WHEN MATCHED THEN
          UPDATE SET %s
        WHEN NOT MATCHED BY TARGET THEN
          INSERT (%s) VALUES (%s)
        WHEN NOT MATCHED BY SOURCE
          AND tgt.region = '%s'
        THEN DELETE
      """,
      dataset_name, dest_table_name,
      batch_union_sql,
      on_clause,
      set_clause,
      insert_cols, insert_vals,
      region);

      BEGIN
        EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, source_scope,
           'BY_ORG merge failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      END;

    ELSE

      -- ── Per-project MERGE ────────────────────────────────────────────
      -- ON clause: tgt.region=src.region AND tgt.project=src.project AND <keys>
      SET on_clause = 'tgt.region = src.region AND tgt.project = src.project';
      SET on_clause = (
        SELECT on_clause || ' AND ' || STRING_AGG(FORMAT('tgt.%s = src.%s', k, k), ' AND ')
        FROM UNNEST(SPLIT(merge_keys, ', ')) AS k
      );

      -- UPDATE SET clause
      SET set_clause = (
        SELECT STRING_AGG(FORMAT('%s = src.%s', c, c), ', ')
        FROM UNNEST(SPLIT(col_list, ', ')) AS c
      );
      SET set_clause = set_clause || ', ingestion_ts = CURRENT_TIMESTAMP()';

      -- INSERT columns and values
      SET insert_cols = col_list || ', region, project, ingestion_ts';
      SET insert_vals = (
        SELECT STRING_AGG(FORMAT('src.%s', c), ', ')
        FROM UNNEST(SPLIT(col_list, ', ')) AS c
      );
      SET insert_vals = insert_vals || ', src.region, src.project, CURRENT_TIMESTAMP()';

      -- DELETE-orphans scope: region + projects in this batch
      SET exec_sql = FORMAT("""
        MERGE `%s.%s` AS tgt
        USING (%s) AS src
        ON %s
        WHEN MATCHED THEN
          UPDATE SET %s
        WHEN NOT MATCHED BY TARGET THEN
          INSERT (%s) VALUES (%s)
        WHEN NOT MATCHED BY SOURCE
          AND tgt.region = '%s'
          AND tgt.project IN UNNEST(@batch_projects)
        THEN DELETE
      """,
      dataset_name, dest_table_name,
      batch_union_sql,
      on_clause,
      set_clause,
      insert_cols, insert_vals,
      region);

      BEGIN
        EXECUTE IMMEDIATE exec_sql USING batch_projects AS batch_projects;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log`
          (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
        VALUES
          (current_run_ts, dest_table_name, source_scope,
           'Snapshot merge failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      END;

    END IF;

  ELSE

    INSERT INTO `unravel_share_us_new.error_log`
      (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES
      (current_run_ts, dest_table_name, source_scope,
       'Unknown strategy: ' || strategy, NULL, CURRENT_TIMESTAMP());

  END IF;

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



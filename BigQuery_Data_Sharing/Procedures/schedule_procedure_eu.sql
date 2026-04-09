SET @@location = 'EU';

CREATE SCHEMA IF NOT EXISTS unravel_share_EU
  OPTIONS (location = 'EU');

CREATE TABLE IF NOT EXISTS `unravel_share_EU.error_log`
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
-- Procedure to incrementally sync metadata tables
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_incremental_EU(
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
      INSERT INTO `unravel_share_EU.error_log`
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
      INSERT INTO `unravel_share_EU.error_log`
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
      INSERT INTO `unravel_share_EU.error_log`
        (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
      VALUES
        (current_run_ts, dest_table_name, baseline_project,
         'col_list resolution failed: ' || @@error.message, exec_sql, CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, temp_table_name);

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_EU.error_log`
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
        INSERT INTO `unravel_share_EU.error_log`
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
            INSERT INTO `unravel_share_EU.error_log`
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
          INSERT INTO `unravel_share_EU.error_log`
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
          INSERT INTO `unravel_share_EU.error_log`
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
        INSERT INTO `unravel_share_EU.error_log`
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
CREATE OR REPLACE PROCEDURE unravel_share_EU.export_metadata_incremental_EU_all_projects(
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

  CALL unravel_share_EU.export_metadata_incremental_EU(
    dataset_name,
    lookback_days,
    tables,
    region,
    project_ids,
    retention_days,
    batch_size
  );

END;

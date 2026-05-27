SET @@location = 'US';

CREATE SCHEMA IF NOT EXISTS unravel_share_us_new
  OPTIONS (location = 'US');

CREATE SCHEMA IF NOT EXISTS unravel_share_us_projects_list
  OPTIONS (location = 'US');

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


-- ─────────────────────────────────────────────────────────────────────────────
-- migrate_tables_to_new
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_US.migrate_tables_to_new(
  source_dataset  STRING,
  target_dataset  STRING,
  region          STRING
)
BEGIN
  DECLARE exec_sql        STRING;
  DECLARE col_list        STRING;
  DECLARE current_run_ts  TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

  SET exec_sql = FORMAT("""
    CREATE SCHEMA IF NOT EXISTS `%s` OPTIONS (location = 'US')
  """, target_dataset);
  BEGIN EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = 'Failed to create target dataset: ' || @@error.message; END;

  FOR tbl IN (
    SELECT table_id, partition_col, cluster_cols, expiry_days
    FROM UNNEST([
      STRUCT('ASSIGNMENTS_US' AS table_id, CAST(NULL AS STRING) AS partition_col, 'project_id' AS cluster_cols, CAST(180 AS INT64) AS expiry_days),
      STRUCT('ASSIGNMENT_CHANGES_US','DATE(change_timestamp)','project_id',CAST(180 AS INT64)),
      STRUCT('BILLING_TABLE','DATE(export_time)',NULL,CAST(365 AS INT64)),
      STRUCT('COLUMNS_US',CAST(NULL AS STRING),'table_catalog',CAST(NULL AS INT64)),
      STRUCT('JOBS_TIMELINE_US','DATE(job_creation_time)','project_id, user_email',CAST(180 AS INT64)),
      STRUCT('JOBS_US','DATE(creation_time)','project_id, user_email',CAST(180 AS INT64)),
      STRUCT('RESERVATIONS_TIMELINE_US','DATE(period_start)','project_id',CAST(180 AS INT64)),
      STRUCT('RESERVATIONS_US',CAST(NULL AS STRING),'project_id',CAST(NULL AS INT64)),
      STRUCT('RESERVATION_CHANGES_US','DATE(change_timestamp)','project_id',CAST(180 AS INT64)),
      STRUCT('SCHEMATA_OPTIONS_US',CAST(NULL AS STRING),'catalog_name',CAST(NULL AS INT64)),
      STRUCT('TABLES_US',CAST(NULL AS STRING),'table_catalog',CAST(NULL AS INT64)),
      STRUCT('TABLE_OPTIONS_US',CAST(NULL AS STRING),'table_catalog',CAST(NULL AS INT64)),
      STRUCT('TABLE_STORAGE_US',CAST(NULL AS STRING),'table_catalog',CAST(NULL AS INT64)),
      STRUCT('error_log','DATE(logged_at)','project_id',CAST(365 AS INT64))
    ])
  ) DO
    SET exec_sql = FORMAT("""
      SELECT STRING_AGG(column_name, ', ' ORDER BY ordinal_position)
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
      WHERE table_catalog = '%s' AND table_schema = '%s' AND table_name = '%s'
    """, region, @@project_id, source_dataset, tbl.table_id);
    BEGIN EXECUTE IMMEDIATE exec_sql INTO col_list;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,tbl.table_id,@@project_id,'col_list resolution failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP()); CONTINUE;
    END;
    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,tbl.table_id,@@project_id,'col_list is NULL',NULL,CURRENT_TIMESTAMP()); CONTINUE;
    END IF;

    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.%s` %s %s %s AS SELECT %s FROM `%s.%s` WHERE FALSE
    """, target_dataset, tbl.table_id,
      IF(tbl.partition_col IS NOT NULL, FORMAT('PARTITION BY %s',tbl.partition_col),''),
      IF(tbl.cluster_cols IS NOT NULL, FORMAT('CLUSTER BY %s',tbl.cluster_cols),''),
      IF(tbl.partition_col IS NOT NULL AND tbl.expiry_days IS NOT NULL, FORMAT('OPTIONS (partition_expiration_days=%d)',tbl.expiry_days),''),
      col_list, source_dataset, tbl.table_id);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,tbl.table_id,@@project_id,'DDL failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP()); CONTINUE;
    END;

    SET exec_sql = FORMAT("INSERT INTO `%s.%s` (%s) SELECT %s FROM `%s.%s`",
      target_dataset,tbl.table_id,col_list,col_list,source_dataset,tbl.table_id);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,tbl.table_id,@@project_id,'Data copy failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
    END;
  END FOR;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- create_projects_table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_projects_list.create_projects_table(
  dataset_name STRING, billing_export_project STRING, billing_dataset STRING, billing_table STRING
)
BEGIN
  DECLARE table_exists BOOL DEFAULT FALSE;
  DECLARE last_export_ts TIMESTAMP;
  DECLARE current_run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE exec_sql STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN RAISE USING MESSAGE = "ERROR: billing_export_project is empty!"; END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN RAISE USING MESSAGE = "ERROR: billing_dataset is empty!"; END IF;
  IF billing_table IS NULL OR billing_table = '' THEN RAISE USING MESSAGE = "ERROR: billing_table is empty!"; END IF;

  BEGIN
    EXECUTE IMMEDIATE FORMAT("SELECT MAX(last_seen) FROM `%s.projects_table`", dataset_name) INTO last_export_ts;
    SET table_exists = TRUE;
  EXCEPTION WHEN ERROR THEN SET table_exists = FALSE; END;

  IF NOT table_exists THEN
    SET exec_sql = FORMAT("CREATE TABLE IF NOT EXISTS `%s.projects_table` (project_id STRING NOT NULL, first_seen TIMESTAMP, last_seen TIMESTAMP) CLUSTER BY project_id", dataset_name);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to create projects_table – " || @@error.message; END;

    SET exec_sql = FORMAT("""
      INSERT INTO `%s.projects_table` (project_id, first_seen, last_seen)
      SELECT project.id, MIN(export_time), MAX(export_time)
      FROM `%s.%s.%s`
      WHERE service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5') AND project.id IS NOT NULL
      GROUP BY project.id
    """, dataset_name, billing_export_project, billing_dataset, billing_table);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to populate projects_table on first run – " || @@error.message; END;
  ELSE
    EXECUTE IMMEDIATE FORMAT("SELECT MAX(last_seen) FROM `%s.projects_table`", dataset_name) INTO last_export_ts;
    IF last_export_ts IS NULL THEN SET last_export_ts = TIMESTAMP('1970-01-01 00:00:00 UTC'); END IF;

    SET exec_sql = FORMAT("""
      MERGE `%s.projects_table` AS tgt
      USING (
        SELECT project.id AS project_id, MIN(export_time) AS first_seen, MAX(export_time) AS last_seen
        FROM `%s.%s.%s`
        WHERE _PARTITIONDATE >= DATE(TIMESTAMP '%s')
          AND service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5')
          AND export_time > TIMESTAMP '%s' AND export_time <= TIMESTAMP '%s'
          AND project.id IS NOT NULL
        GROUP BY 1
      ) AS src ON tgt.project_id = src.project_id
      WHEN MATCHED AND src.last_seen > tgt.last_seen THEN UPDATE SET last_seen = src.last_seen
      WHEN NOT MATCHED THEN INSERT (project_id, first_seen, last_seen) VALUES (src.project_id, src.first_seen, src.last_seen)
    """, dataset_name, billing_export_project, billing_dataset, billing_table,
      FORMAT_TIMESTAMP('%F',last_export_ts), FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_export_ts), FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to merge incremental project IDs – " || @@error.message; END;
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- export_billing_data_incremental
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_billing_data_incremental(
  dataset_name STRING, look_back_days INT64, billing_export_project STRING,
  billing_dataset STRING, billing_table STRING, retention_days INT64
)
BEGIN
  DECLARE exec_sql STRING;
  DECLARE last_sync_ts TIMESTAMP;
  DECLARE current_run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE dest_table STRING DEFAULT 'BILLING_TABLE';
  DECLARE billing_col_list STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN RAISE USING MESSAGE = "ERROR: billing_export_project is empty!"; END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN RAISE USING MESSAGE = "ERROR: billing_dataset is empty!"; END IF;
  IF billing_table IS NULL OR billing_table = '' THEN RAISE USING MESSAGE = "ERROR: billing_table is empty!"; END IF;

  SET exec_sql = FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.%s` PARTITION BY DATE(export_time) OPTIONS (partition_expiration_days=%d)
    AS SELECT *, CURRENT_TIMESTAMP() AS ingestion_ts FROM `%s.%s.%s` WHERE FALSE
  """, dataset_name,dest_table,retention_days,billing_export_project,billing_dataset,billing_table);
  BEGIN EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
    VALUES (current_run_ts,dest_table,billing_export_project,'Billing DDL failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP()); RETURN;
  END;

  SET exec_sql = FORMAT("""
    SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
    FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS c
    WHERE c.table_name='%s' AND c.column_name != 'ingestion_ts'
      AND c.column_name IN (SELECT column_name FROM `%s`.INFORMATION_SCHEMA.COLUMNS WHERE table_name='%s')
  """, billing_export_project,billing_dataset,billing_table,dataset_name,dest_table);
  BEGIN EXECUTE IMMEDIATE exec_sql INTO billing_col_list;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
    VALUES (current_run_ts,dest_table,billing_export_project,'Billing col_list failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP()); RETURN;
  END;
  IF billing_col_list IS NULL THEN
    INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
    VALUES (current_run_ts,dest_table,billing_export_project,'billing_col_list is NULL',NULL,CURRENT_TIMESTAMP()); RETURN;
  END IF;

  EXECUTE IMMEDIATE FORMAT("SELECT MAX(export_time) FROM `%s.%s`",dataset_name,dest_table) INTO last_sync_ts;
  IF last_sync_ts IS NULL THEN SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL look_back_days DAY); END IF;

  SET exec_sql = FORMAT("""
    INSERT INTO `%s.%s` (%s, ingestion_ts)
    SELECT %s, CURRENT_TIMESTAMP() FROM `%s.%s.%s`
    WHERE export_time > TIMESTAMP '%s' AND export_time <= TIMESTAMP '%s'
      AND service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5')
  """, dataset_name,dest_table,billing_col_list,billing_col_list,
    billing_export_project,billing_dataset,billing_table,
    FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_sync_ts),FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
  BEGIN EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
    VALUES (current_run_ts,dest_table,billing_export_project,'Billing incremental insert failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
  END;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- _build_typed_select
--
-- Uses COLUMN_FIELD_PATHS + COLUMNS from the physical destination table
-- to build a SELECT expression that reconstructs STRUCT columns field-by-field.
--
-- Algorithm (bottom-up iterative):
--   1. Load all field paths from COLUMN_FIELD_PATHS into a work table
--   2. Find the maximum nesting depth
--   3. Starting from the deepest level, group leaf fields by their parent
--      and build STRUCT(...) expressions, replacing the parent row
--   4. Move up one level and repeat
--   5. At the top level, assemble the final SELECT expression using
--      COLUMNS.ordinal_position for ordering
--
-- Handles: STRUCT, nested STRUCT, ARRAY<STRUCT> (via UNNEST/re-ARRAY)
-- Called ONCE per table (not per project).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._build_typed_select(
  dataset_name     STRING,
  dest_table_name  STRING,
  region           STRING,
  col_list         STRING,
  OUT typed_select STRING
)
BEGIN

  DECLARE exec_sql       STRING;
  DECLARE max_depth      INT64;
  DECLARE current_depth  INT64;
  DECLARE work_table     STRING;
  DECLARE run_uuid       STRING DEFAULT REPLACE(GENERATE_UUID(), '-', '_');
  DECLARE col_names      ARRAY<STRING>;

  SET col_names = SPLIT(col_list, ', ');
  SET work_table = CONCAT('_typed_work_', run_uuid);

  -- ── 1. Load all field paths into a physical work table ────────────────
  --    We join with COLUMNS to get ordinal_position for top-level ordering.
  --    For sub-fields, we use field_path alphabetical order (consistent).
  --
  --    depth = number of dots in field_path (0 = top-level)
  --    parent_path = everything before the last dot
  --    field_name = last segment after the last dot (or full path if no dot)
  --    expr = initially the field_path itself (e.g. 'query_info.resource_warning')
  --           gets replaced bottom-up with STRUCT(...) expressions
  --    is_struct = TRUE if data_type starts with STRUCT or ARRAY<STRUCT
  --    is_array_struct = TRUE if data_type starts with ARRAY<STRUCT
  -- Use ROW_NUMBER() to capture the original field ordering from
  -- COLUMN_FIELD_PATHS. This is critical because STRUCT fields must
  -- appear in their original schema order, NOT alphabetical.
  -- COLUMN_FIELD_PATHS returns rows in schema-definition order,
  -- so ROW_NUMBER() OVER (PARTITION BY column_name ORDER BY field_path)
  -- won't work (field_path is alpha). Instead we use a subquery that
  -- preserves the natural row order with ROW_NUMBER() partitioned by
  -- parent_path to get sibling ordering.
  SET exec_sql = FORMAT("""
    CREATE TABLE `%s.%s` AS
    WITH raw_paths AS (
      SELECT
        cfp.column_name,
        cfp.field_path,
        cfp.data_type,
        -- field_order preserves the original schema order within each parent
        -- COLUMN_FIELD_PATHS returns fields in definition order, so we
        -- use the data_type string itself to extract position info.
        -- Actually, we parse the parent's STRUCT<...> definition to get order.
        ROW_NUMBER() OVER () AS global_row_num
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS cfp
      WHERE cfp.table_catalog = '%s'
        AND cfp.table_schema  = '%s'
        AND cfp.table_name    = '%s'
        AND cfp.column_name NOT IN ('region', 'project', 'ingestion_ts')
        AND cfp.column_name IN UNNEST(%s)
    )
    SELECT
      r.column_name,
      r.field_path,
      ARRAY_LENGTH(SPLIT(r.field_path, '.')) - 1 AS depth,
      CASE
        WHEN STRPOS(r.field_path, '.') = 0 THEN CAST(NULL AS STRING)
        ELSE REGEXP_EXTRACT(r.field_path, r'^(.+)\\.[^.]+$')
      END AS parent_path,
      REGEXP_EXTRACT(r.field_path, r'[^.]+$') AS field_name,
      r.field_path AS expr,
      r.data_type,
      (r.data_type LIKE 'STRUCT%%' OR r.data_type LIKE 'ARRAY<STRUCT%%') AS is_struct,
      r.data_type LIKE 'ARRAY<STRUCT%%' AS is_array_struct,
      COALESCE(c.ordinal_position, 999999) AS ordinal_position,
      -- field_order: preserves original schema ordering among siblings
      -- We use global_row_num which reflects COLUMN_FIELD_PATHS natural order
      r.global_row_num AS field_order
    FROM raw_paths r
    LEFT JOIN `region-%s`.INFORMATION_SCHEMA.COLUMNS c
      ON  c.table_catalog = '%s'
      AND c.table_schema  = '%s'
      AND c.table_name    = '%s'
      AND c.column_name   = r.column_name
      AND r.field_path    = r.column_name  -- only join for top-level rows
    WHERE TRUE
  """, dataset_name, work_table,
       region,
       @@project_id, dataset_name, dest_table_name,
       CONCAT("['", ARRAY_TO_STRING(col_names, "','"), "']"),
       region,
       @@project_id, dataset_name, dest_table_name);

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    SET typed_select = NULL;
    RETURN;
  END;

  -- ── 2. Find max depth ─────────────────────────────────────────────────
  EXECUTE IMMEDIATE FORMAT("SELECT MAX(depth) FROM `%s.%s`", dataset_name, work_table)
  INTO max_depth;

  IF max_depth IS NULL OR max_depth = 0 THEN
    -- No nested fields; just use col_list as-is
    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
    SET typed_select = col_list;
    RETURN;
  END IF;

  -- ── 3. Bottom-up: collapse each level into STRUCT(...) expressions ────
  SET current_depth = max_depth;

  WHILE current_depth >= 1 DO

    -- For each parent_path at (current_depth - 1) that has children at current_depth:
    -- Build STRUCT(child1_expr AS child1_name, child2_expr AS child2_name, ...) 
    -- and update the parent row's expr with this STRUCT expression.
    --
    -- For ARRAY<STRUCT> parents, build:
    --   ARRAY(SELECT AS STRUCT child1_expr AS child1_name, ... FROM UNNEST(parent_path) AS _arr_elem)
    -- BUT: children's expr references need to be rewritten from 
    --   parent_path.child to _arr_elem.child
    -- We handle this by checking is_array_struct on the parent.

    SET exec_sql = FORMAT("""
      CREATE OR REPLACE TABLE `%s.%s` AS
      WITH children_at_depth AS (
        -- Get all leaf/already-collapsed children at this depth
        SELECT
          parent_path,
          column_name,
          STRING_AGG(
            CONCAT(expr, ' AS ', field_name)
            ORDER BY field_order  -- preserve original schema order, NOT alphabetical
          ) AS struct_innards,
          parent_path AS lookup_path
        FROM `%s.%s`
        WHERE depth = %d
          AND NOT is_struct
        GROUP BY parent_path, column_name
      ),
      parent_info AS (
        SELECT field_path, is_array_struct, column_name
        FROM `%s.%s`
        WHERE depth = %d - 1
      ),
      collapsed AS (
        SELECT
          c.parent_path AS field_path,
          CASE
            WHEN p.is_array_struct THEN
              CONCAT(
                'ARRAY(SELECT AS STRUCT ',
                -- Replace parent_path references with _arr_elem in the innards
                REPLACE(c.struct_innards, CONCAT(c.parent_path, '.'), '_arr_elem.'),
                ' FROM UNNEST(', c.parent_path, ') AS _arr_elem)'
              )
            ELSE
              CONCAT('STRUCT(', c.struct_innards, ')')
          END AS new_expr
        FROM children_at_depth c
        LEFT JOIN parent_info p ON c.parent_path = p.field_path
      )
      SELECT
        w.column_name,
        w.field_path,
        w.depth,
        w.parent_path,
        w.field_name,
        -- Replace expr for parent rows that got collapsed
        COALESCE(col.new_expr, w.expr) AS expr,
        w.data_type,
        -- Once collapsed, the parent is no longer a struct for processing purposes
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_struct END AS is_struct,
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_array_struct END AS is_array_struct,
        w.ordinal_position,
        w.field_order
      FROM `%s.%s` w
      LEFT JOIN collapsed col ON w.field_path = col.field_path
      -- Remove the children that were just collapsed (they're now part of parent's expr)
      WHERE w.depth != %d OR w.is_struct  -- keep structs at this depth (they might have no children = leaf structs)
    """,
    dataset_name, work_table,
    dataset_name, work_table, current_depth,
    dataset_name, work_table, current_depth,
    dataset_name, work_table,
    current_depth);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      -- If bottom-up collapse fails, bail out with col_list
      EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
      SET typed_select = col_list;
      RETURN;
    END;

    SET current_depth = current_depth - 1;
  END WHILE;

  -- ── 4. Assemble final SELECT from top-level rows (depth = 0) ──────────
  EXECUTE IMMEDIATE FORMAT("""
    SELECT STRING_AGG(
      CASE
        WHEN expr != field_path THEN CONCAT(expr, ' AS ', column_name)
        ELSE column_name
      END,
      ', '
      ORDER BY ordinal_position, column_name
    )
    FROM `%s.%s`
    WHERE depth = 0
  """, dataset_name, work_table)
  INTO typed_select;

  -- ── 5. Cleanup ────────────────────────────────────────────────────────
  EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);

  IF typed_select IS NULL OR typed_select = '' THEN
    SET typed_select = col_list;
  END IF;

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

  DECLARE config ARRAY<STRUCT<
    table_name STRING, strategy STRING, time_col STRING, time_col_type STRING,
    merge_keys STRING, partition_col_expr STRING, cluster_cols STRING, is_by_org BOOL
  >>;
  DECLARE current_table     STRING;
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
  DECLARE batch_count       INT64;
  DECLARE batch_union_sql   STRING;
  DECLARE batch_projects    ARRAY<STRING>;
  DECLARE typed_select      STRING;

  SET config = [
    STRUCT('JOBS' AS table_name,'INCREMENTAL_APPEND' AS strategy,'creation_time' AS time_col,'TIMESTAMP' AS time_col_type,CAST(NULL AS STRING) AS merge_keys,'DATE(creation_time)' AS partition_col_expr,'project_id, user_email' AS cluster_cols,FALSE AS is_by_org),
    STRUCT('JOBS_TIMELINE','INCREMENTAL_APPEND','job_creation_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(job_creation_time)','project_id, user_email',FALSE),
    STRUCT('RESERVATIONS_TIMELINE','INCREMENTAL_APPEND','period_start','TIMESTAMP',CAST(NULL AS STRING),'DATE(period_start)','project_id',FALSE),
    STRUCT('TABLE_STORAGE_USAGE_TIMELINE','INCREMENTAL_APPEND','usage_date','DATE',CAST(NULL AS STRING),'usage_date','table_catalog',FALSE),
    STRUCT('RESERVATION_CHANGES','AUDIT_APPEND','change_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(change_timestamp)','project_id',FALSE),
    STRUCT('CAPACITY_COMMITMENT_CHANGES','AUDIT_APPEND','change_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(change_timestamp)','project_id',FALSE),
    STRUCT('ASSIGNMENT_CHANGES','AUDIT_APPEND','change_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(change_timestamp)','project_id',FALSE),
    STRUCT('SHARED_DATASET_USAGE','AUDIT_APPEND','job_start_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(job_start_time)','project_id, dataset_id',FALSE),
    STRUCT('TABLES','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('VIEWS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('MATERIALIZED_VIEWS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('TABLE_OPTIONS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name, option_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('TABLE_STORAGE','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('COLUMNS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'table_catalog, table_schema, table_name, column_name',CAST(NULL AS STRING),'table_catalog',FALSE),
    STRUCT('SCHEMATA','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, location',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_OPTIONS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, option_name',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_LINKS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, linked_schema_catalog_number, linked_schema_name',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_REPLICAS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, replica_name, location',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_REPLICAS_BY_FAILOVER_RESERVATION','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, replica_name, failover_reservation_name',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('ASSIGNMENTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, assignment_id, job_type',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('RESERVATIONS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, reservation_name',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('CAPACITY_COMMITMENTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, capacity_commitment_id',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('INSIGHTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, subtype, insight_id',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('JOBS_BY_ORGANIZATION','INCREMENTAL_APPEND','creation_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(creation_time)','project_id, user_email',TRUE),
    STRUCT('JOBS_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','job_creation_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(job_creation_time)','project_id, user_email',TRUE),
    STRUCT('STREAMING_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','start_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(start_timestamp)','project_id, dataset_id, table_id',TRUE),
    STRUCT('WRITE_API_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','start_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(start_timestamp)','project_id, dataset_id, table_id',TRUE),
    STRUCT('RECOMMENDATIONS_BY_ORGANIZATION','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, recommender, subtype, recommendation_id',CAST(NULL AS STRING),'project_id, recommender',TRUE)
  ];

  IF region IS NULL THEN RAISE USING MESSAGE = "region is NULL!"; END IF;
  IF dataset_name IS NULL THEN RAISE USING MESSAGE = "dataset_name is NULL!"; END IF;
  IF ARRAY_LENGTH(tables) = 0 THEN RAISE USING MESSAGE = "tables array is empty!"; END IF;
  IF ARRAY_LENGTH(project_ids) = 0 THEN RAISE USING MESSAGE = "project_ids array is empty!"; END IF;

  SET baseline_project = (SELECT p FROM UNNEST(project_ids) AS p WHERE p IS NOT NULL AND p != '' LIMIT 1);
  IF baseline_project IS NULL OR baseline_project = '' THEN RAISE USING MESSAGE = "ERROR: No valid baseline project id found."; END IF;

  -- ═══════════════════════════════════════════════════════════════════
  -- Main loop: one iteration per requested table
  -- ═══════════════════════════════════════════════════════════════════
  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO

    SET current_table = table_row.f0_;
    SET cfg = (SELECT AS STRUCT * FROM UNNEST(config) c WHERE c.table_name = current_table LIMIT 1);

    IF cfg IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,current_table,baseline_project,'No config entry for table: '||current_table,NULL,CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    SET dest_table_name = CONCAT(current_table, '_', region);
    SET partition_clause = IF(cfg.partition_col_expr IS NOT NULL, FORMAT('PARTITION BY %s',cfg.partition_col_expr), '');
    SET cluster_clause = IF(cfg.cluster_cols IS NOT NULL, FORMAT('CLUSTER BY %s',cfg.cluster_cols), '');

    -- ── DDL ──────────────────────────────────────────────────────────────
    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s` %s %s %s AS
        SELECT *, CAST(NULL AS STRING) AS region, CURRENT_TIMESTAMP() AS ingestion_ts
        FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name,dest_table_name,partition_clause,cluster_clause,
        IF(partition_clause!='',FORMAT('OPTIONS (partition_expiration_days=%d)',retention_days),''),
        region,current_table);
    ELSE
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s` %s %s %s AS
        SELECT *, CAST(NULL AS STRING) AS region, CAST(NULL AS STRING) AS project, CURRENT_TIMESTAMP() AS ingestion_ts
        FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name,dest_table_name,partition_clause,cluster_clause,
        IF(partition_clause!='',FORMAT('OPTIONS (partition_expiration_days=%d)',retention_days),''),
        baseline_project,region,current_table);
    END IF;

    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,dest_table_name,baseline_project,'DDL failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    -- ── Resolve col_list ─────────────────────────────────────────────────
    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);

    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("CREATE OR REPLACE TABLE `%s.%s` AS SELECT * FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0",
        dataset_name,temp_table_name,region,current_table);
    ELSE
      SET exec_sql = FORMAT("CREATE OR REPLACE TABLE `%s.%s` AS SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0",
        dataset_name,temp_table_name,baseline_project,region,current_table);
    END IF;

    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,dest_table_name,baseline_project,'col_list temp table failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    SET exec_sql = FORMAT("""
      SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS c
      WHERE c.table_catalog='%s' AND c.table_schema='%s' AND c.table_name='%s'
        AND c.column_name NOT IN ('region','project','ingestion_ts')
        AND c.column_name IN (
          SELECT column_name FROM `region-%s`.INFORMATION_SCHEMA.COLUMNS
          WHERE table_catalog='%s' AND table_schema='%s' AND table_name='%s'
        )
    """, region,@@project_id,dataset_name,dest_table_name,
      region,@@project_id,dataset_name,temp_table_name);

    BEGIN EXECUTE IMMEDIATE exec_sql INTO col_list;
    EXCEPTION WHEN ERROR THEN
      EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",dataset_name,temp_table_name);
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,dest_table_name,baseline_project,'col_list resolution failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",dataset_name,temp_table_name);

    IF col_list IS NULL THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,dest_table_name,baseline_project,'col_list is NULL',NULL,CURRENT_TIMESTAMP());
      CONTINUE;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- Build typed_select ONCE per table from destination schema
    -- ══════════════════════════════════════════════════════════════════════
    CALL unravel_share_us_new._build_typed_select(
      dataset_name, dest_table_name, region, col_list, typed_select
    );

    IF typed_select IS NULL THEN
      SET typed_select = col_list;
    END IF;

    -- ═════════════════════════════════════════════════════════════════════
    -- BY_ORGANIZATION path
    -- ═════════════════════════════════════════════════════════════════════
    IF cfg.is_by_org THEN

      IF cfg.strategy = 'SNAPSHOT_MERGE' THEN
        SET batch_union_sql = FORMAT("SELECT %s, '%s' AS region FROM `region-%s`.INFORMATION_SCHEMA.%s",
          typed_select,region,region,current_table);
        CALL unravel_share_us_new._flush_batch(dataset_name,dest_table_name,col_list,region,
          batch_union_sql,CAST([] AS ARRAY<STRING>),cfg.strategy,cfg.merge_keys,TRUE,current_run_ts);
        CONTINUE;
      END IF;

      IF cfg.time_col IS NOT NULL THEN
        EXECUTE IMMEDIATE FORMAT("SELECT MAX(%s) FROM `%s.%s` WHERE region='%s'",
          cfg.time_col,dataset_name,dest_table_name,region) INTO last_sync_ts;
        IF last_sync_ts IS NULL THEN SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY); END IF;
        SET time_filter = FORMAT("WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
          cfg.time_col,FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_sync_ts),
          cfg.time_col,FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
      ELSE
        SET exec_sql = FORMAT("DELETE FROM `%s.%s` WHERE region='%s'",dataset_name,dest_table_name,region);
        BEGIN EXECUTE IMMEDIATE exec_sql;
        EXCEPTION WHEN ERROR THEN
          INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
          VALUES (current_run_ts,dest_table_name,'BY_ORG','BY_ORG delete failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
          CONTINUE;
        END;
        SET time_filter = 'WHERE TRUE';
      END IF;

      SET exec_sql = FORMAT("""
        INSERT INTO `%s.%s` (%s, region, ingestion_ts)
        SELECT %s, '%s', CURRENT_TIMESTAMP() FROM `region-%s`.INFORMATION_SCHEMA.%s %s
      """, dataset_name,dest_table_name,col_list,typed_select,region,region,current_table,time_filter);
      BEGIN EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
        VALUES (current_run_ts,dest_table_name,'BY_ORG','BY_ORG insert failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      END;
      CONTINUE;
    END IF;

    -- ═════════════════════════════════════════════════════════════════════
    -- Per-project batched path (typed_select reused for all projects)
    -- ═════════════════════════════════════════════════════════════════════
    SET batch_count = 0;
    SET batch_union_sql = '';
    SET batch_projects = [];

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO
      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
        VALUES (current_run_ts,dest_table_name,project_id,'project_id is NULL or empty',NULL,CURRENT_TIMESTAMP());
        CONTINUE;
      END IF;

      IF cfg.strategy IN ('INCREMENTAL_APPEND','AUDIT_APPEND') THEN
        IF cfg.time_col_type = 'DATE' THEN
          EXECUTE IMMEDIATE FORMAT("SELECT MAX(%s) FROM `%s.%s` WHERE project='%s' AND region='%s'",
            cfg.time_col,dataset_name,dest_table_name,project_id,region) INTO last_sync_date;
          IF last_sync_date IS NULL THEN SET last_sync_date = DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days DAY); END IF;
          SET time_filter = FORMAT("WHERE %s > DATE '%s' AND %s <= DATE '%s'",
            cfg.time_col,FORMAT_DATE('%F',last_sync_date),cfg.time_col,FORMAT_DATE('%F',CURRENT_DATE()));
        ELSE
          EXECUTE IMMEDIATE FORMAT("SELECT MAX(%s) FROM `%s.%s` WHERE project='%s' AND region='%s'",
            cfg.time_col,dataset_name,dest_table_name,project_id,region) INTO last_sync_ts;
          IF last_sync_ts IS NULL THEN SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL lookback_days DAY); END IF;
          SET time_filter = FORMAT("WHERE %s > TIMESTAMP '%s' AND %s <= TIMESTAMP '%s'",
            cfg.time_col,FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_sync_ts),
            cfg.time_col,FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
        END IF;
      ELSE
        SET time_filter = 'WHERE TRUE';
      END IF;

      IF batch_union_sql != '' THEN SET batch_union_sql = batch_union_sql || '\nUNION ALL\n'; END IF;
      SET batch_union_sql = batch_union_sql || FORMAT("""
        SELECT %s, '%s' AS region, '%s' AS project FROM `%s.region-%s`.INFORMATION_SCHEMA.%s %s
      """, typed_select,region,project_id,project_id,region,current_table,time_filter);

      SET batch_projects = ARRAY_CONCAT(batch_projects, [project_id]);
      SET batch_count = batch_count + 1;

      IF batch_count >= batch_size THEN
        CALL unravel_share_us_new._flush_batch(dataset_name,dest_table_name,col_list,region,
          batch_union_sql,batch_projects,cfg.strategy,cfg.merge_keys,FALSE,current_run_ts);
        SET batch_union_sql = '';
        SET batch_projects = [];
        SET batch_count = 0;
      END IF;
    END FOR;

    IF batch_count > 0 AND batch_union_sql != '' THEN
      CALL unravel_share_us_new._flush_batch(dataset_name,dest_table_name,col_list,region,
        batch_union_sql,batch_projects,cfg.strategy,cfg.merge_keys,FALSE,current_run_ts);
    END IF;

  END FOR;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- _flush_batch
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._flush_batch(
  dataset_name STRING, dest_table_name STRING, col_list STRING, region STRING,
  batch_union_sql STRING, batch_projects ARRAY<STRING>, strategy STRING,
  merge_keys STRING, is_by_org BOOL, current_run_ts TIMESTAMP
)
BEGIN
  DECLARE exec_sql STRING;
  DECLARE on_clause STRING;
  DECLARE set_clause STRING;
  DECLARE insert_cols STRING;
  DECLARE insert_vals STRING;
  DECLARE source_scope STRING;

  SET source_scope = IF(is_by_org, 'BY_ORG_MERGE', 'BATCH');

  IF strategy IN ('INCREMENTAL_APPEND','AUDIT_APPEND') THEN
    SET exec_sql = FORMAT("""
      INSERT INTO `%s.%s` (%s, region, project, ingestion_ts)
      SELECT batch_rows.*, CURRENT_TIMESTAMP() FROM (%s) AS batch_rows
    """, dataset_name,dest_table_name,col_list,batch_union_sql);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
      VALUES (current_run_ts,dest_table_name,source_scope,'Append batch insert failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
    END;

  ELSEIF strategy = 'SNAPSHOT_MERGE' THEN
    IF is_by_org THEN
      SET on_clause = 'tgt.region = src.region';
      SET on_clause = (SELECT on_clause||' AND '||STRING_AGG(FORMAT('tgt.%s = src.%s',k,k),' AND ') FROM UNNEST(SPLIT(merge_keys,', ')) AS k);
      SET set_clause = (SELECT STRING_AGG(FORMAT('%s = src.%s',c,c),', ') FROM UNNEST(SPLIT(col_list,', ')) AS c);
      SET set_clause = set_clause || ', ingestion_ts = CURRENT_TIMESTAMP()';
      SET insert_cols = col_list || ', region, ingestion_ts';
      SET insert_vals = (SELECT STRING_AGG(FORMAT('src.%s',c),', ') FROM UNNEST(SPLIT(col_list,', ')) AS c);
      SET insert_vals = insert_vals || ', src.region, CURRENT_TIMESTAMP()';
      SET exec_sql = FORMAT("""
        MERGE `%s.%s` AS tgt USING (%s) AS src ON %s
        WHEN MATCHED THEN UPDATE SET %s
        WHEN NOT MATCHED BY TARGET THEN INSERT (%s) VALUES (%s)
        WHEN NOT MATCHED BY SOURCE AND tgt.region='%s' THEN DELETE
      """, dataset_name,dest_table_name,batch_union_sql,on_clause,set_clause,insert_cols,insert_vals,region);
      BEGIN EXECUTE IMMEDIATE exec_sql;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
        VALUES (current_run_ts,dest_table_name,source_scope,'BY_ORG merge failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      END;
    ELSE
      SET on_clause = 'tgt.region = src.region AND tgt.project = src.project';
      SET on_clause = (SELECT on_clause||' AND '||STRING_AGG(FORMAT('tgt.%s = src.%s',k,k),' AND ') FROM UNNEST(SPLIT(merge_keys,', ')) AS k);
      SET set_clause = (SELECT STRING_AGG(FORMAT('%s = src.%s',c,c),', ') FROM UNNEST(SPLIT(col_list,', ')) AS c);
      SET set_clause = set_clause || ', ingestion_ts = CURRENT_TIMESTAMP()';
      SET insert_cols = col_list || ', region, project, ingestion_ts';
      SET insert_vals = (SELECT STRING_AGG(FORMAT('src.%s',c),', ') FROM UNNEST(SPLIT(col_list,', ')) AS c);
      SET insert_vals = insert_vals || ', src.region, src.project, CURRENT_TIMESTAMP()';
      SET exec_sql = FORMAT("""
        MERGE `%s.%s` AS tgt USING (%s) AS src ON %s
        WHEN MATCHED THEN UPDATE SET %s
        WHEN NOT MATCHED BY TARGET THEN INSERT (%s) VALUES (%s)
        WHEN NOT MATCHED BY SOURCE AND tgt.region='%s' AND tgt.project IN UNNEST(@batch_projects) THEN DELETE
      """, dataset_name,dest_table_name,batch_union_sql,on_clause,set_clause,insert_cols,insert_vals,region);
      BEGIN EXECUTE IMMEDIATE exec_sql USING batch_projects AS batch_projects;
      EXCEPTION WHEN ERROR THEN
        INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
        VALUES (current_run_ts,dest_table_name,source_scope,'Snapshot merge failed: '||@@error.message,exec_sql,CURRENT_TIMESTAMP());
      END;
    END IF;
  ELSE
    INSERT INTO `unravel_share_us_new.error_log` (run_ts,dest_table,project_id,error_message,failed_sql,logged_at)
    VALUES (current_run_ts,dest_table_name,source_scope,'Unknown strategy: '||strategy,NULL,CURRENT_TIMESTAMP());
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_metadata_incremental_US_all_projects(
  dataset_name STRING, lookback_days INT64, tables ARRAY<STRING>, region STRING,
  projects_table STRING, retention_days INT64, batch_size INT64
)
BEGIN
  DECLARE project_ids ARRAY<STRING>;
  EXECUTE IMMEDIATE FORMAT("SELECT ARRAY_AGG(project_id IGNORE NULLS) FROM `%s`", projects_table) INTO project_ids;
  IF project_ids IS NULL OR ARRAY_LENGTH(project_ids) = 0 THEN
    RAISE USING MESSAGE = "ERROR: No rows present in: " || projects_table;
  END IF;
  CALL unravel_share_us_new.export_metadata_incremental_US(
    dataset_name,lookback_days,tables,region,project_ids,retention_days,batch_size);
END;

SET @@location = 'US';

CREATE SCHEMA IF NOT EXISTS unravel_share_us_new
  OPTIONS (location = 'US');

CREATE SCHEMA IF NOT EXISTS unravel_share_us_new_projects_list
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
-- UTILITY A: _log_error (Modularized Diagnostic Logger)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._log_error(
  run_ts TIMESTAMP, dest_table STRING, project_id STRING, error_message STRING, failed_sql STRING
)
BEGIN
  INSERT INTO `unravel_share_us_new.error_log` (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
  VALUES (run_ts, dest_table, project_id, error_message, failed_sql, CURRENT_TIMESTAMP());
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- UTILITY B: _update_project_ledger (Modularized Conditional Ledger Evaluator)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._update_project_ledger(
  control_ledger STRING, raw_error STRING, target_project STRING, target_table STRING
)
BEGIN
  DECLARE upper_error STRING DEFAULT UPPER(raw_error);
  DECLARE update_allowed BOOL DEFAULT FALSE;
  
  -- Conditional Check Constraint Rule Core Isolation Unit
  SET update_allowed = (
    upper_error LIKE '%ACCESS DENIED%' 
    OR upper_error LIKE '%VPC%' 
    OR upper_error LIKE '%NOT FOUND%'
  );

  IF update_allowed THEN
    EXECUTE IMMEDIATE FORMAT("""
      UPDATE `%s`
      SET access_allowed = FALSE,
          reason = @reason
      WHERE project_id = @project_id AND table_name = @table_name
    """, control_ledger)
    USING raw_error AS reason, target_project AS project_id, target_table AS table_name;
  END IF;
END;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. create_projects_table (Seeds root entries & handles dynamic project configurations)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new_projects_list.create_projects_table(
  dataset_name STRING, 
  projects_table_name STRING, 
  billing_export_project STRING, 
  billing_dataset STRING, 
  billing_table STRING,
  monitored_tables ARRAY<STRING>
)
BEGIN
  DECLARE table_exists BOOL DEFAULT FALSE;
  DECLARE last_export_ts TIMESTAMP;
  DECLARE current_run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE exec_sql STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN RAISE USING MESSAGE = "ERROR: billing_export_project is empty!"; END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN RAISE USING MESSAGE = "ERROR: billing_dataset is empty!"; END IF;
  IF billing_table IS NULL OR billing_table = '' THEN RAISE USING MESSAGE = "ERROR: billing_table is empty!"; END IF;
  IF monitored_tables IS NULL OR ARRAY_LENGTH(monitored_tables) = 0 THEN RAISE USING MESSAGE = "ERROR: monitored_tables parameter array cannot be empty!"; END IF;

  BEGIN
    EXECUTE IMMEDIATE FORMAT("SELECT MAX(last_seen) FROM `%s.%s`", dataset_name, projects_table_name) INTO last_export_ts;
    SET table_exists = TRUE;
  EXCEPTION WHEN ERROR THEN SET table_exists = FALSE; END;

  IF NOT table_exists THEN
    SET exec_sql = FORMAT("""
      CREATE TABLE IF NOT EXISTS `%s.%s` (
        project_id STRING NOT NULL, 
        table_name STRING NOT NULL,
        access_allowed BOOL DEFAULT TRUE,
        reason STRING,
        first_seen TIMESTAMP, 
        last_seen TIMESTAMP
      ) CLUSTER BY table_name, project_id
    """, dataset_name, projects_table_name);
    BEGIN EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to create projects ledger table – " || @@error.message; END;

    SET exec_sql = FORMAT("""
      INSERT INTO `%s.%s` (project_id, table_name, access_allowed, reason, first_seen, last_seen)
      SELECT 
        IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', 'ORGANIZATION_ROOT', project.id) AS project_id, 
        current_target_table, 
        TRUE, 
        CAST(NULL AS STRING), 
        IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', CAST(NULL AS TIMESTAMP), MIN(export_time)) AS first_seen, 
        IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', CAST(NULL AS TIMESTAMP), MAX(export_time)) AS last_seen
      FROM `%s.%s.%s`
      CROSS JOIN UNNEST(@table_param) AS current_target_table
      WHERE service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5') 
        AND project.id IS NOT NULL
      GROUP BY 1, current_target_table
    """, dataset_name, projects_table_name, billing_export_project, billing_dataset, billing_table);
    
    BEGIN EXECUTE IMMEDIATE exec_sql USING monitored_tables AS table_param;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to populate initial projects ledger – " || @@error.message; END;
  ELSE
    EXECUTE IMMEDIATE FORMAT("SELECT MAX(last_seen) FROM `%s.%s`", dataset_name, projects_table_name) INTO last_export_ts;
    IF last_export_ts IS NULL THEN SET last_export_ts = TIMESTAMP('1970-01-01 00:00:00 UTC'); END IF;

    SET exec_sql = FORMAT("""
      MERGE `%s.%s` AS tgt
      USING (
        SELECT 
          IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', 'ORGANIZATION_ROOT', project.id) AS project_id, 
          current_target_table AS table_name, 
          IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', CAST(NULL AS TIMESTAMP), MIN(export_time)) AS first_seen, 
          IF(current_target_table LIKE '%%_BY_ORGANIZATION%%', CAST(NULL AS TIMESTAMP), MAX(export_time)) AS last_seen
        FROM `%s.%s.%s`
        CROSS JOIN UNNEST(@table_param) AS current_target_table
        WHERE _PARTITIONDATE >= DATE(TIMESTAMP '%s')
          AND service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5')
          AND export_time > TIMESTAMP '%s' AND export_time <= TIMESTAMP '%s'
          AND project.id IS NOT NULL
        GROUP BY 1, 2
      ) AS src ON tgt.project_id = src.project_id AND tgt.table_name = src.table_name
      WHEN MATCHED AND src.last_seen > tgt.last_seen AND tgt.project_id != 'ORGANIZATION_ROOT' THEN 
        UPDATE SET last_seen = src.last_seen
      WHEN NOT MATCHED THEN 
        INSERT (project_id, table_name, access_allowed, reason, first_seen, last_seen) 
        VALUES (src.project_id, src.table_name, TRUE, CAST(NULL AS STRING), src.first_seen, src.last_seen)
    """, dataset_name, projects_table_name, billing_export_project, billing_dataset, billing_table,
      FORMAT_TIMESTAMP('%F',last_export_ts), FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_export_ts), FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
    
    BEGIN EXECUTE IMMEDIATE exec_sql USING monitored_tables AS table_param;
    EXCEPTION WHEN ERROR THEN RAISE USING MESSAGE = "ERROR: Failed to merge incremental project IDs into ledger – " || @@error.message; END;
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. export_billing_data_incremental (Utilizes customized billing selector logic)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_billing_data_incremental(
  dataset_name STRING, 
  look_back_days INT64, 
  billing_export_project STRING,
  billing_dataset STRING, 
  billing_table STRING, 
  retention_days INT64,
  region STRING
)
BEGIN
  DECLARE exec_sql STRING;
  DECLARE last_sync_ts TIMESTAMP;
  DECLARE current_run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE dest_table STRING DEFAULT 'BILLING_TABLE';
  DECLARE billing_col_list STRING;
  DECLARE typed_billing_select STRING;
  DECLARE regional_schema_path STRING;

  IF billing_export_project IS NULL OR billing_export_project = '' THEN RAISE USING MESSAGE = "ERROR: billing_export_project is empty!"; END IF;
  IF billing_dataset IS NULL OR billing_dataset = '' THEN RAISE USING MESSAGE = "ERROR: billing_dataset is empty!"; END IF;
  IF billing_table IS NULL OR billing_table = '' THEN RAISE USING MESSAGE = "ERROR: billing_table is empty!"; END IF;
  IF region IS NULL OR region = '' THEN RAISE USING MESSAGE = "ERROR: region parameter is empty!"; END IF;

  SET exec_sql = FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.%s` PARTITION BY DATE(export_time) OPTIONS (partition_expiration_days=%d)
    AS SELECT *, CURRENT_TIMESTAMP() AS ingestion_ts FROM `%s.%s.%s` WHERE FALSE
  """, dataset_name,dest_table,retention_days,billing_export_project,billing_dataset,billing_table);
  BEGIN EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    CALL unravel_share_us_new._log_error(current_run_ts, dest_table, billing_export_project, 'Billing DDL failed: '||@@error.message, exec_sql); RETURN;
  END;

  SET regional_schema_path = FORMAT("region-%s", LOWER(region));

  SET exec_sql = FORMAT("""
    SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
    FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS c
    WHERE c.table_schema='%s' AND c.table_name='%s' AND c.column_name != 'ingestion_ts'
  """, @@project_id, regional_schema_path, dataset_name, dest_table);
  
  BEGIN EXECUTE IMMEDIATE exec_sql INTO billing_col_list;
  EXCEPTION WHEN ERROR THEN
    CALL unravel_share_us_new._log_error(current_run_ts, dest_table, billing_export_project, 'Billing col_list failed: '||@@error.message, exec_sql); RETURN;
  END;
  
  IF billing_col_list IS NULL THEN
    CALL unravel_share_us_new._log_error(current_run_ts, dest_table, billing_export_project, 'billing_col_list resolves to NULL', NULL); RETURN;
  END IF;

  CALL unravel_share_us_new._build_billing_typed_select(
    dataset_name, dest_table, region, billing_col_list, typed_billing_select
  );

  IF typed_billing_select IS NULL OR typed_billing_select = '' THEN 
    SET typed_billing_select = billing_col_list; 
  END IF;

  EXECUTE IMMEDIATE FORMAT("SELECT MAX(export_time) FROM `%s.%s`",dataset_name,dest_table) INTO last_sync_ts;
  IF last_sync_ts IS NULL THEN SET last_sync_ts = TIMESTAMP_SUB(current_run_ts, INTERVAL look_back_days DAY); END IF;

  SET exec_sql = FORMAT("""
    INSERT INTO `%s.%s` (%s, ingestion_ts)
    SELECT %s, CURRENT_TIMESTAMP() AS ingestion_ts FROM `%s.%s.%s`
    WHERE export_time > TIMESTAMP '%s' AND export_time <= TIMESTAMP '%s'
      AND service.id IN ('650B-3C82-34DB','16B8-3DDA-9F10','DCC9-8DB9-673F','24E6-581D-38E5')
  """, dataset_name, dest_table, billing_col_list, typed_billing_select,
    billing_export_project, billing_dataset, billing_table,
    FORMAT_TIMESTAMP('%F %H:%M:%E6S',last_sync_ts), FORMAT_TIMESTAMP('%F %H:%M:%E6S',current_run_ts));
    
  BEGIN EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    CALL unravel_share_us_new._log_error(current_run_ts, dest_table, billing_export_project, 'Billing incremental insert failed: '||@@error.message, exec_sql);
  END;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. _build_typed_select
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

  SET exec_sql = FORMAT("""
    CREATE TABLE `%s.%s` AS
    WITH raw_paths AS (
      SELECT
        cfp.column_name,
        cfp.field_path,
        cfp.data_type,
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
      r.global_row_num AS field_order
    FROM raw_paths r
    LEFT JOIN `region-%s`.INFORMATION_SCHEMA.COLUMNS c
      ON  c.table_catalog = '%s'
      AND c.table_schema  = '%s'
      AND c.table_name    = '%s'
      AND c.column_name   = r.column_name
      AND r.field_path    = r.column_name
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

  EXECUTE IMMEDIATE FORMAT("SELECT MAX(depth) FROM `%s.%s`", dataset_name, work_table) INTO max_depth;

  IF max_depth IS NULL OR max_depth = 0 THEN
    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
    SET typed_select = col_list;
    RETURN;
  END IF;

  SET current_depth = max_depth;

  WHILE current_depth >= 1 DO
    SET exec_sql = FORMAT("""
      CREATE OR REPLACE TABLE `%s.%s` AS
      WITH children_at_depth AS (
        SELECT
          parent_path,
          column_name,
          STRING_AGG(
            CONCAT(expr, ' AS ', field_name)
            ORDER BY field_order
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
        COALESCE(col.new_expr, w.expr) AS expr,
        w.data_type,
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_struct END AS is_struct,
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_array_struct END AS is_array_struct,
        w.ordinal_position,
        w.field_order
      FROM `%s.%s` w
      LEFT JOIN collapsed col ON w.field_path = col.field_path
      WHERE w.depth != %d OR w.is_struct
    """, dataset_name, work_table,
        dataset_name, work_table, current_depth,
        dataset_name, work_table, current_depth,
        dataset_name, work_table, current_depth);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
      SET typed_select = col_list;
      RETURN;
    END;

    SET current_depth = current_depth - 1;
  END WHILE;

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
  """, dataset_name, work_table) INTO typed_select;

  EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);

  IF typed_select IS NULL OR typed_select = '' THEN
    SET typed_select = col_list;
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4b. _build_billing_typed_select (Decoupled Billing Struct Field Map Sub-Routine)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._build_billing_typed_select(
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
  SET work_table = CONCAT('_typed_billing_work_', run_uuid);

  SET exec_sql = FORMAT("""
    CREATE TABLE `%s.%s` AS
    WITH raw_paths AS (
      SELECT
        cfp.column_name,
        cfp.field_path,
        cfp.data_type,
        ROW_NUMBER() OVER () AS global_row_num
      FROM `region-%s`.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS cfp
      WHERE cfp.table_catalog = '%s'
        AND cfp.table_schema  = '%s'
        AND cfp.table_name    = '%s'
        AND cfp.column_name NOT IN ('region', 'ingestion_ts') 
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
      r.global_row_num AS field_order
    FROM raw_paths r
    LEFT JOIN `region-%s`.INFORMATION_SCHEMA.COLUMNS c
      ON  c.table_catalog = '%s'
      AND c.table_schema  = '%s'
      AND c.table_name    = '%s'
      AND c.column_name   = r.column_name
      AND r.field_path    = r.column_name
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

  EXECUTE IMMEDIATE FORMAT("SELECT MAX(depth) FROM `%s.%s`", dataset_name, work_table) INTO max_depth;

  IF max_depth IS NULL OR max_depth = 0 THEN
    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
    SET typed_select = col_list;
    RETURN;
  END IF;

  SET current_depth = max_depth;

  WHILE current_depth >= 1 DO
    SET exec_sql = FORMAT("""
      CREATE OR REPLACE TABLE `%s.%s` AS
      WITH children_at_depth AS (
        SELECT
          parent_path,
          column_name,
          STRING_AGG(
            CONCAT(expr, ' AS ', field_name)
            ORDER BY field_order
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
        COALESCE(col.new_expr, w.expr) AS expr,
        w.data_type,
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_struct END AS is_struct,
        CASE WHEN col.new_expr IS NOT NULL THEN FALSE ELSE w.is_array_struct END AS is_array_struct,
        w.ordinal_position,
        w.field_order
      FROM `%s.%s` w
      LEFT JOIN collapsed col ON w.field_path = col.field_path
      WHERE w.depth != %d OR w.is_struct
    """, dataset_name, work_table,
        dataset_name, work_table, current_depth,
        dataset_name, work_table, current_depth,
        dataset_name, work_table, current_depth);

    BEGIN
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);
      SET typed_select = col_list;
      RETURN;
    END;

    SET current_depth = current_depth - 1;
  END WHILE;

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
  """, dataset_name, work_table) INTO typed_select;

  EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`", dataset_name, work_table);

  IF typed_select IS NULL OR typed_select = '' THEN
    SET typed_select = col_list;
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. export_metadata_incremental_US (Utilizes project fallback loops + modular ledger evaluating)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_metadata_incremental_US(
  dataset_name   STRING,
  lookback_days  INT64,
  tables         ARRAY<STRING>,
  region         STRING,
  project_ids    ARRAY<STRING>,
  retention_days INT64,
  batch_size     INT64,
  control_ledger STRING
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
  
  -- Fallback loop parameters
  DECLARE ddl_success       BOOL;
  DECLARE ddl_project_idx   INT64;
  DECLARE total_ddl_projects INT64;
  DECLARE test_project      STRING;

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
    STRUCT('SCHEMATA_LINKS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, linked_schema_catalog_number, linked_schema_name, shared_asset_id',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_REPLICAS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, replica_name, location',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('SCHEMATA_REPLICAS_BY_FAILOVER_RESERVATION','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'catalog_name, schema_name, replica_name, failover_reservation_name',CAST(NULL AS STRING),'catalog_name',FALSE),
    STRUCT('ASSIGNMENTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, assignment_id, job_type',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('RESERVATIONS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, reservation_name',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('CAPACITY_COMMITMENTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, capacity_commitment_id',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('INSIGHTS','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, subtype, insight_id',CAST(NULL AS STRING),'project_id',FALSE),
    STRUCT('JOBS_BY_ORGANIZATION','INCREMENTAL_APPEND','creation_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(creation_time)' AS partition_col_expr,'project_id, user_email' AS cluster_cols,TRUE AS is_by_org),
    STRUCT('JOBS_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','job_creation_time','TIMESTAMP',CAST(NULL AS STRING),'DATE(job_creation_time)','project_id, user_email',TRUE),
    STRUCT('STREAMING_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','start_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(start_timestamp)','project_id, dataset_id, table_id',TRUE),
    STRUCT('WRITE_API_TIMELINE_BY_ORGANIZATION','INCREMENTAL_APPEND','start_timestamp','TIMESTAMP',CAST(NULL AS STRING),'DATE(start_timestamp)','project_id, dataset_id, table_id',TRUE),
    STRUCT('RECOMMENDATIONS_BY_ORGANIZATION','SNAPSHOT_MERGE',CAST(NULL AS STRING),CAST(NULL AS STRING),'project_id, recommender, subtype, recommendation_id',CAST(NULL AS STRING),'project_id, recommender',TRUE)
  ];

  IF region IS NULL THEN RAISE USING MESSAGE = "region is NULL!"; END IF;
  IF dataset_name IS NULL THEN RAISE USING MESSAGE = "dataset_name is NULL!"; END IF;
  IF ARRAY_LENGTH(tables) = 0 THEN RAISE USING MESSAGE = "tables array is empty!"; END IF;
  IF ARRAY_LENGTH(project_ids) = 0 THEN RAISE USING MESSAGE = "project_ids array is empty!"; END IF;

  FOR table_row IN (SELECT * FROM UNNEST(tables)) DO
    SET current_table = table_row.f0_;
    SET cfg = (SELECT AS STRUCT * FROM UNNEST(config) c WHERE c.table_name = current_table LIMIT 1);

    IF cfg IS NULL THEN
      SET cfg = STRUCT(current_table AS table_name, 'SNAPSHOT_MERGE' AS strategy, CAST(NULL AS STRING) AS time_col, CAST(NULL AS STRING) AS time_col_type, 'table_catalog' AS merge_keys, CAST(NULL AS STRING) AS partition_col_expr, 'table_catalog' AS cluster_cols, FALSE AS is_by_org);
    END IF;

    SET dest_table_name = CONCAT(current_table, '_', region);
    SET partition_clause = IF(cfg.partition_col_expr IS NOT NULL, FORMAT('PARTITION BY %s',cfg.partition_col_expr), '');
    SET cluster_clause = IF(cfg.cluster_cols IS NOT NULL, FORMAT('CLUSTER BY %s',cfg.cluster_cols), '');

    SET ddl_success = FALSE;
    SET ddl_project_idx = 0;
    SET total_ddl_projects = ARRAY_LENGTH(project_ids);
    SET baseline_project = NULL;

    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("""
        CREATE TABLE IF NOT EXISTS `%s.%s` %s %s %s AS
        SELECT *, CAST(NULL AS STRING) AS region, CURRENT_TIMESTAMP() AS ingestion_ts
        FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
      """, dataset_name,dest_table_name,partition_clause,cluster_clause,
        IF(partition_clause!='',FORMAT('OPTIONS (partition_expiration_days=%d)',retention_days),''),
        region,current_table);
        
      BEGIN 
        EXECUTE IMMEDIATE exec_sql;
        SET ddl_success = TRUE;
        SET baseline_project = 'ORGANIZATION_ROOT';
      EXCEPTION WHEN ERROR THEN
        CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, 'BY_ORG', 'Org DDL layout schema configuration collapsed: '||@@error.message, exec_sql);
      END;
    ELSE
      -- Dynamic DDL Loop Fallback Routine
      WHILE ddl_project_idx < total_ddl_projects AND NOT ddl_success DO
        SET test_project = project_ids[OFFSET(ddl_project_idx)];
        SET ddl_project_idx = ddl_project_idx + 1;

        SET exec_sql = FORMAT("""
          CREATE TABLE IF NOT EXISTS `%s.%s` %s %s %s AS
          SELECT *, CAST(NULL AS STRING) AS region, CAST(NULL AS STRING) AS project, CURRENT_TIMESTAMP() AS ingestion_ts
          FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0
        """, dataset_name, dest_table_name, partition_clause, cluster_clause,
          IF(partition_clause!='', FORMAT('OPTIONS (partition_expiration_days=%d)', retention_days), ''),
          test_project, region, current_table);

        BEGIN
          EXECUTE IMMEDIATE exec_sql;
          SET ddl_success = TRUE;
          SET baseline_project = test_project; 
        EXCEPTION WHEN ERROR THEN
          -- Route error evaluations through specialized utility components
          CALL unravel_share_us_new._update_project_ledger(control_ledger, @@error.message, test_project, current_table);
          CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, test_project, 'DDL trial block exception intercept: '||@@error.message, exec_sql);
        END;
      END WHILE;
    END IF;

    IF NOT ddl_success OR baseline_project IS NULL THEN
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, 'GLOBAL_FALLBACK', 'All candidate trace components threw DDL errors. Table iteration terminated.', NULL);
      CONTINUE;
    END IF;

    SET temp_table_name = CONCAT('src_cols_temp_', run_uuid);
    IF cfg.is_by_org THEN
      SET exec_sql = FORMAT("CREATE OR REPLACE TABLE `%s.%s` AS SELECT * FROM `region-%s`.INFORMATION_SCHEMA.%s LIMIT 0",
        dataset_name,temp_table_name,region,current_table);
    ELSE
      SET exec_sql = FORMAT("CREATE OR REPLACE TABLE `%s.%s` AS SELECT * FROM `%s.region-%s`.INFORMATION_SCHEMA.%s LIMIT 0",
        dataset_name,temp_table_name,baseline_project,region,current_table);
    END IF;

    BEGIN 
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, baseline_project, 'col_list matrix dynamic table build collapsed: '||@@error.message, exec_sql);
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
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, baseline_project, 'col_list metric string aggregated output trace collapse: '||@@error.message, exec_sql);
      CONTINUE;
    END;

    EXECUTE IMMEDIATE FORMAT("DROP TABLE IF EXISTS `%s.%s`",dataset_name,temp_table_name);

    IF col_list IS NULL THEN
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, baseline_project, 'col_list aggregated resolution mapped exclusively to NULL components.', NULL);
      CONTINUE;
    END IF;

    CALL unravel_share_us_new._build_typed_select(dataset_name, dest_table_name, region, col_list, typed_select);
    IF typed_select IS NULL THEN SET typed_select = col_list; END IF;

    IF cfg.is_by_org THEN
      IF cfg.strategy = 'SNAPSHOT_MERGE' THEN
        SET batch_union_sql = FORMAT("SELECT %s, '%s' AS region FROM `region-%s`.INFORMATION_SCHEMA.%s",
          typed_select,region,region,current_table);
        CALL unravel_share_us_new._flush_batch(dataset_name,dest_table_name,col_list,region,
          batch_union_sql,CAST([] AS ARRAY<STRING>),cfg,current_run_ts,typed_select,lookback_days,control_ledger,'WHERE TRUE');
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
          CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, 'BY_ORG', 'BY_ORG clear operations exception hit: '||@@error.message, exec_sql);
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
        CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, 'BY_ORG', 'BY_ORG batch insertion operation collapsed: '||@@error.message, exec_sql);
      END;
      CONTINUE;
    END IF;

    SET batch_count = 0;
    SET batch_union_sql = '';
    SET batch_projects = [];

    FOR project_row IN (SELECT * FROM UNNEST(project_ids)) DO
      SET project_id = project_row.f0_;

      IF project_id IS NULL OR project_id = '' THEN
        CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, project_id, 'project_id value validated as NULL or clean empty string context.', NULL);
        CONTINUE;
      END IF;

      IF cfg.strategy IN ('INCREMENTAL_APPEND','AUDIT_APPEND') AND cfg.time_col IS NOT NULL THEN
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
          batch_union_sql,batch_projects,cfg,current_run_ts,typed_select,lookback_days,control_ledger,time_filter);
        SET batch_union_sql = '';
        SET batch_projects = [];
        SET batch_count = 0;
      END IF;
    END FOR;

    IF batch_count > 0 AND batch_union_sql != '' THEN
      CALL unravel_share_us_new._flush_batch(dataset_name,dest_table_name,col_list,region,
        batch_union_sql,batch_projects,cfg,current_run_ts,typed_select,lookback_days,control_ledger,time_filter);
    END IF;

  END FOR;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. _flush_batch (Utilizes new utility logging and ledger updates functions)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new._flush_batch(
  dataset_name STRING, dest_table_name STRING, col_list STRING, region STRING,
  batch_union_sql STRING, batch_projects ARRAY<STRING>, 
  cfg STRUCT<table_name STRING, strategy STRING, time_col STRING, time_col_type STRING, merge_keys STRING, partition_col_expr STRING, cluster_cols STRING, is_by_org BOOL>,
  current_run_ts TIMESTAMP, typed_select STRING, lookback_days INT64, control_ledger STRING,
  batch_time_filter STRING
)
BEGIN
  DECLARE exec_sql STRING;
  DECLARE on_clause STRING;
  DECLARE set_clause STRING;
  DECLARE insert_cols STRING;
  DECLARE insert_vals STRING;
  DECLARE source_scope STRING;
  
  -- Fallback loop parameters
  DECLARE fallback_project STRING;
  DECLARE fallback_sql STRING;
  DECLARE fallback_time_clause STRING;

  SET source_scope = IF(cfg.is_by_org, 'BY_ORG_MERGE', 'BATCH');

  -- ── Happy Path Output Dispatches ───────────────────────────────────────────
  IF cfg.strategy IN ('INCREMENTAL_APPEND','AUDIT_APPEND') THEN
    SET exec_sql = FORMAT("""
      INSERT INTO `%s.%s` (%s, region, project, ingestion_ts)
      SELECT batch_rows.*, CURRENT_TIMESTAMP() FROM (%s) AS batch_rows
    """, dataset_name,dest_table_name,col_list,batch_union_sql);
    
    BEGIN 
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      -- Log macro batch error via centralized module anyway
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, source_scope, 'Macro batch append failed. Unnesting loop: '||@@error.message, exec_sql);

      IF cfg.is_by_org THEN
        RETURN;
      ELSE
        FOR idx IN (SELECT p FROM UNNEST(batch_projects) AS p) DO
          SET fallback_project = idx.p;
          
          IF batch_time_filter IS NOT NULL AND UPPER(batch_time_filter) LIKE 'WHERE %' THEN
            SET fallback_time_clause = CONCAT("AND ", SUBSTRING(batch_time_filter, 7));
          ELSE
            SET fallback_time_clause = "AND TRUE";
          END IF;

          SET fallback_sql = FORMAT("""
            INSERT INTO `%s.%s` (%s, region, project, ingestion_ts)
            SELECT %s, '%s' AS region, '%s' AS project, CURRENT_TIMESTAMP()
            FROM `%s.region-%s`.INFORMATION_SCHEMA.%s 
            WHERE TRUE %s
          """, dataset_name, dest_table_name, col_list, typed_select, region, fallback_project, fallback_project, region, cfg.table_name, fallback_time_clause);
          
          BEGIN
            EXECUTE IMMEDIATE fallback_sql;
          EXCEPTION WHEN ERROR THEN
            -- Route checks and writes securely through modularized logic paths
            CALL unravel_share_us_new._update_project_ledger(control_ledger, @@error.message, fallback_project, cfg.table_name);
            CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, fallback_project, 'Isolated fallback copy failed: '||@@error.message, fallback_sql);
          END;
        END FOR;
      END IF;
    END;

  ELSEIF cfg.strategy = 'SNAPSHOT_MERGE' AND cfg.is_by_org THEN
    SET on_clause = 'tgt.region = src.region';
    SET on_clause = (SELECT on_clause||' AND '||STRING_AGG(FORMAT('tgt.%s = src.%s',k,k),' AND ') FROM UNNEST(SPLIT(cfg.merge_keys,', ')) AS k);
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
    
    BEGIN 
      EXECUTE IMMEDIATE exec_sql;
    EXCEPTION WHEN ERROR THEN
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, source_scope, 'BY_ORG snapshot merge failed: '||@@error.message, exec_sql);
    END;

  ELSEIF cfg.strategy = 'SNAPSHOT_MERGE' AND NOT cfg.is_by_org THEN
    SET on_clause = 'tgt.region = src.region AND tgt.project = src.project';
    SET on_clause = (SELECT on_clause||' AND '||STRING_AGG(FORMAT('tgt.%s = src.%s',k,k),' AND ') FROM UNNEST(SPLIT(cfg.merge_keys,', ')) AS k);
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
    
    BEGIN 
      EXECUTE IMMEDIATE exec_sql USING batch_projects AS batch_projects;
    EXCEPTION WHEN ERROR THEN
      -- Log macro batch error via centralized module anyway
      CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, source_scope, 'Batch merge identity conflict hit. Initiating loops fallback: '||@@error.message, exec_sql);

      FOR idx IN (SELECT p FROM UNNEST(batch_projects) AS p) DO
        SET fallback_project = idx.p;
        
        SET fallback_sql = FORMAT("""
          MERGE `%s.%s` AS tgt 
          USING (SELECT %s, '%s' AS region, '%s' AS project FROM `%s.region-%s`.INFORMATION_SCHEMA.%s) AS src ON %s
          WHEN MATCHED THEN UPDATE SET %s
          WHEN NOT MATCHED BY TARGET THEN INSERT (%s) VALUES (%s)
          WHEN NOT MATCHED BY SOURCE AND tgt.region='%s' AND tgt.project = '%s' THEN DELETE
        """, dataset_name, dest_table_name, typed_select, region, fallback_project, fallback_project, region, cfg.table_name, on_clause, set_clause, insert_cols, insert_vals, region, fallback_project);
        
        BEGIN
          EXECUTE IMMEDIATE fallback_sql;
        EXCEPTION WHEN ERROR THEN
          -- Route checks and writes securely through modularized logic paths
          CALL unravel_share_us_new._update_project_ledger(control_ledger, @@error.message, fallback_project, cfg.table_name);
          CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, fallback_project, 'Isolated fallback merge collapsed: '||@@error.message, fallback_sql);
        END;
      END FOR;
    END;
    
  ELSE
    CALL unravel_share_us_new._log_error(current_run_ts, dest_table_name, source_scope, 'Unknown strategy context detected: '||cfg.strategy, NULL);
  END IF;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Wrapper
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_metadata_incremental_US_all_projects(
  dataset_name STRING, 
  lookback_days INT64, 
  tables ARRAY<STRING>, 
  region STRING,
  projects_table STRING, 
  retention_days INT64, 
  batch_size INT64
)
BEGIN
  DECLARE project_ids ARRAY<STRING>;
  DECLARE current_loop_table STRING;
  DECLARE ledger_lookup_sql STRING;
  
  FOR t_row IN (SELECT * FROM UNNEST(tables)) DO
    SET current_loop_table = t_row.f0_;
    
    SET ledger_lookup_sql = FORMAT("""
      SELECT ARRAY_AGG(project_id IGNORE NULLS) 
      FROM `%s` 
      WHERE table_name = '%s' 
        AND access_allowed = TRUE
    """, projects_table, current_loop_table);
    
    EXECUTE IMMEDIATE ledger_lookup_sql INTO project_ids;
    
    IF project_ids IS NULL OR ARRAY_LENGTH(project_ids) = 0 THEN
      CALL unravel_share_us_new._log_error(CURRENT_TIMESTAMP(), current_loop_table, 'WRAPPER', 'Sequence tracking skipped. Zero allowed entries tracked inside control schema.', ledger_lookup_sql);
      CONTINUE;
    END IF;
    
    CALL unravel_share_us_new.export_metadata_incremental_US(
      dataset_name, lookback_days, [current_loop_table], region, project_ids, retention_days, batch_size, projects_table);
  END FOR;
END;

CREATE OR REPLACE PROCEDURE unravel_share_us_new.export_org_structure(
  look_back_days         INT64,
  source_project         STRING,
  source_dataset         STRING,
  source_table           STRING,
  des_dataset_name       STRING,
  dest_table             STRING,
  retention_days         INT64
)
BEGIN
  -- Variables for Schema Detection
  DECLARE has_service_id   BOOL DEFAULT FALSE;
  DECLARE time_col         STRING;
  DECLARE partition_col    STRING;
  DECLARE time_type        STRING;

  -- Variables for Execution
  DECLARE exec_sql         STRING;
  DECLARE col_list         STRING;
  DECLARE last_sync_val    STRING;
  DECLARE current_run_ts   TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
  DECLARE filter_clause    STRING DEFAULT '';

  -- 1. DETECT SCHEMA CHARACTERISTICS
  -- Identifies if it's Table 1 (Billing) or Table 2 (Jobs) based on service_id
  EXECUTE IMMEDIATE FORMAT("""
    SELECT
      EXISTS(SELECT 1 FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS WHERE table_name='%s' AND column_name='service_id') as has_sid,
      CASE
        WHEN EXISTS(SELECT 1 FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS WHERE table_name='%s' AND column_name='service_id') THEN 'usage_date'
        WHEN EXISTS(SELECT 1 FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS WHERE table_name='%s' AND column_name='creation_time') THEN 'creation_time'
        ELSE 'export_time'
      END as t_col,
      CASE
        WHEN EXISTS(SELECT 1 FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS WHERE table_name='%s' AND column_name='creation_date') THEN 'creation_date'
        ELSE 'usage_date'
      END as p_col
  """, source_project, source_dataset, source_table,
       source_project, source_dataset, source_table,
       source_project, source_dataset, source_table,
       source_project, source_dataset, source_table)
  INTO has_service_id, time_col, partition_col;

  -- Detect the data type (DATE or TIMESTAMP) to ensure correct SQL casting
  EXECUTE IMMEDIATE FORMAT("""
    SELECT data_type FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS
    WHERE table_name='%s' AND column_name='%s'
  """, source_project, source_dataset, source_table, time_col)
  INTO time_type;

  -- 2. RESOLVE OVERLAPPING COLUMNS
  -- We exclude 'ingestion_ts' from the source scan to avoid conflicts
  SET exec_sql = FORMAT("""
    SELECT STRING_AGG(c.column_name, ', ' ORDER BY c.ordinal_position)
    FROM `%s.%s`.INFORMATION_SCHEMA.COLUMNS c
    WHERE c.table_name = '%s'
      AND c.column_name != 'ingestion_ts'
  """, source_project, source_dataset, source_table);

  EXECUTE IMMEDIATE exec_sql INTO col_list;

  -- 3. CREATE DESTINATION TABLE WITH ingestion_ts
  -- We add the ingestion_ts column here during the initial creation
  SET exec_sql = FORMAT("""
    CREATE TABLE IF NOT EXISTS `%s.%s`
    PARTITION BY %s
    OPTIONS (partition_expiration_days = %d)
    AS SELECT *, CURRENT_TIMESTAMP() AS ingestion_ts FROM `%s.%s.%s` WHERE FALSE
  """, des_dataset_name, dest_table, partition_col, retention_days, source_project, source_dataset, source_table);

  EXECUTE IMMEDIATE exec_sql;

  -- 4. FIND WATERMARK
  EXECUTE IMMEDIATE FORMAT("SELECT CAST(MAX(%s) AS STRING) FROM `%s.%s` ", time_col, des_dataset_name, dest_table)
  INTO last_sync_val;

  IF last_sync_val IS NULL THEN
    IF time_type = 'DATE' THEN
      SET last_sync_val = CAST(DATE_SUB(CURRENT_DATE(), INTERVAL look_back_days DAY) AS STRING);
    ELSE
      SET last_sync_val = CAST(TIMESTAMP_SUB(current_run_ts, INTERVAL look_back_days DAY) AS STRING);
    END IF;
  END IF;

  -- 5. CONSTRUCT DYNAMIC FILTER (Table 1 Only)
  IF has_service_id THEN
    SET filter_clause = """
      AND service_id IN (
        '650B-3C82-34DB',
        '16B8-3DDA-9F10',
        'DCC9-8DB9-673F',
        '24E6-581D-38E5'
      )
    """;
  END IF;

  -- 6. RUN INCREMENTAL INSERT WITH ingestion_ts
  -- CURRENT_TIMESTAMP() is used to tag the exact moment of insertion
  SET exec_sql = FORMAT("""
    INSERT INTO `%s.%s` (%s, ingestion_ts)
    SELECT %s, CURRENT_TIMESTAMP()
    FROM `%s.%s.%s`
    WHERE %s > %s('%s')
      AND %s <= %s('%s')
      %s
  """,
  des_dataset_name, dest_table, col_list, col_list,
  source_project, source_dataset, source_table,
  time_col, time_type, last_sync_val,
  time_col, time_type, IF(time_type='DATE', CAST(CURRENT_DATE() AS STRING), CAST(current_run_ts AS STRING)),
  filter_clause);

  BEGIN
    EXECUTE IMMEDIATE exec_sql;
  EXCEPTION WHEN ERROR THEN
    INSERT INTO `unravel_share_us_new.error_log` (run_ts, dest_table, project_id, error_message, failed_sql, logged_at)
    VALUES (current_run_ts, dest_table, source_project, @@error.message, exec_sql, CURRENT_TIMESTAMP());
  END;

END;
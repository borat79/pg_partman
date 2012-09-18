CREATE OR REPLACE FUNCTION part.create_parent(p_parent_table text, p_control text, p_type part.partition_type, p_interval text, p_premake int DEFAULT 3, p_debug boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_current_id            bigint;
v_datetime_string       text;
v_id_interval           bigint;
v_job_id                bigint;
v_jobmon_schema         text;
v_last_partition_name   text;
v_old_search_path       text;
v_partition_time        timestamp[];
v_partition_id          bigint[];
v_max                   text;
v_step_id               bigint;
v_tablename             text;
v_time_interval         interval;

BEGIN

SELECT tablename INTO v_tablename FROM pg_tables WHERE schemaname || '.' || tablename = p_parent_table;
    IF v_tablename IS NULL THEN
        RAISE EXCEPTION 'Please create given parent table first: %', p_parent_table;
    END IF;

EXECUTE 'LOCK TABLE '||p_parent_table||' IN ACCESS EXCLUSIVE MODE';

SELECT nspname INTO v_jobmon_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;
IF v_jobmon_schema IS NOT NULL THEN
    SELECT current_setting('search_path') INTO v_old_search_path;
    EXECUTE 'SELECT set_config(''search_path'',''part,'||v_jobmon_schema||''',''false'')';
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job('PARTMON SETUP PARENT: '||p_parent_table);
    v_step_id := add_step(v_job_id, 'Creating initial partitions on new parent table: '||p_parent_table);
END IF;

CASE
    WHEN p_interval = 'yearly' THEN
        v_time_interval = '1 year';
        v_datetime_string := 'YYYY';
    WHEN p_interval = 'monthly' THEN
        v_time_interval = '1 month';
        v_datetime_string := 'YYYY_MM';
    WHEN p_interval = 'weekly' THEN
        v_time_interval = '1 week';
        v_datetime_string := 'IYYY"w"IW';
    WHEN p_interval = 'daily' THEN
        v_time_interval = '1 day';
        v_datetime_string := 'YYYY_MM_DD';
    WHEN p_interval = 'hourly' THEN
        v_time_interval = '1 hour';
        v_datetime_string := 'YYYY_MM_DD_HH24MI';
    WHEN p_interval = 'half-hour' THEN
        v_time_interval = '30 mins';
        v_datetime_string := 'YYYY_MM_DD_HH24MI';
    WHEN p_interval = 'quarter-hour' THEN
        v_time_interval = '15 mins';
        v_datetime_string := 'YYYY_MM_DD_HH24MI';
    ELSE
        IF p_type = 'id-static' OR p_type = 'id-dynamic' THEN
            v_id_interval := p_interval::bigint;
        ELSE
            RAISE EXCEPTION 'Invalid interval for time based partitioning: %', p_interval;
        END IF;
END CASE;

IF p_type = 'time-static' OR p_type = 'time-dynamic' THEN
    FOR i IN 0..p_premake LOOP
        v_partition_time := array_append(v_partition_time, quote_literal(CURRENT_TIMESTAMP + (v_time_interval*i))::timestamp);
    END LOOP;

    EXECUTE 'SELECT part.create_time_partition('||quote_literal(p_parent_table)||','||quote_literal(p_control)||','
        ||quote_literal(v_time_interval)||','||quote_literal(v_datetime_string)||','||quote_literal(v_partition_time)||')' INTO v_last_partition_name;

    INSERT INTO part.part_config (parent_table, type, part_interval, control, premake, datetime_string, last_partition) VALUES
        (p_parent_table, p_type, v_time_interval, p_control, p_premake, v_datetime_string, v_last_partition_name);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Time partitions premade: '||p_premake);
    END IF;
END IF;

IF p_type = 'id-static' OR p_type = 'id-dynamic' THEN
  --  EXECUTE 'SELECT COALESCE(max('||p_control||')::text, '0') FROM '||p_parent_table||' LIMIT 1' INTO v_max;
  --  v_max := v_max::bigint;
    FOR i IN 0..p_premake LOOP
        v_partition_id = array_append(v_partition_id, v_id_interval*i);
    END LOOP;

    EXECUTE 'SELECT part.create_id_partition('||quote_literal(p_parent_table)||','||quote_literal(p_control)||','
        ||v_id_interval||','||quote_literal(v_partition_id)||')' INTO v_last_partition_name;

    INSERT INTO part.part_config (parent_table, type, part_interval, control, premake, last_partition) VALUES
        (p_parent_table, p_type, v_id_interval, p_control, p_premake, v_last_partition_name);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'ID partitions premade: '||p_premake);
    END IF;
    
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Creating partition function');
END IF;

IF p_type = 'time-static' OR p_type = 'time-dynamic' THEN
    EXECUTE 'SELECT part.create_time_function('||quote_literal(p_parent_table)||')';

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Time function created');
    END IF;
ELSIF p_type = 'id-static' OR p_type = 'id-dynamic' THEN
    IF v_max IS NOT NULL THEN
        v_current_id := v_max::bigint;
    ELSE
        v_current_id := 0;
    END IF;
    EXECUTE 'SELECT part.create_id_function('||quote_literal(p_parent_table)||','||v_current_id||')';  

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'ID function created');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Creating partition trigger');
END IF;

EXECUTE 'SELECT part.create_trigger('||quote_literal(p_parent_table)||')';

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', 'Done');
END IF;

PERFORM close_job(v_job_id);

EXCEPTION
    WHEN OTHERS THEN
        IF v_jobmon_schema IS NOT NULL THEN
            EXECUTE 'SELECT set_config(''search_path'',''part,'||v_jobmon_schema||''',''false'')';
            IF v_job_id IS NULL THEN
                v_job_id := add_job('PARTMAN CREATE PARENT: '||p_parent_table);
                v_step_id := add_step(v_job_id, 'Partition creation for table '||p_parent_table||' failed');
            ELSIF v_step_id IS NULL THEN
                v_step_id := add_step(v_job_id, 'EXCEPTION before first step logged');
            END IF;
            PERFORM update_step(v_step_id, 'BAD', 'ERROR: '||coalesce(SQLERRM,'unknown'));
            PERFORM fail_job(v_job_id);
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        END IF;
END
$$;

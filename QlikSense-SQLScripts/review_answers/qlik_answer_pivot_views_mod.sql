CREATE OR REPLACE FUNCTION qlik_build_answer_pivot_views(
    _delta_date character varying,
    _entry_exit_date character varying,
    _types VARCHAR[])
  RETURNS void AS
$BODY$
DECLARE
    _type VARCHAR;
    _dsql TEXT;
    _question_query TEXT;
    _inner_query TEXT;
    _final_query TEXT;
    _ee_limit VARCHAR;
    _primary_key VARCHAR := 'ee.entry_exit_id';
BEGIN
    _types := CASE WHEN ($3 IS NULL) THEN ARRAY['entry', 'exit', 'review'] ELSE $3 END;

    CREATE TEMP TABLE tmp_relevant_ees AS
    SELECT entry_exit_id, client_id, entry_date, exit_date, provider_id,
    ROW_NUMBER() OVER(PARTITION BY client_id ORDER BY client_id, entry_date DESC, entry_exit_id DESC) AS entry_row,
    ROW_NUMBER() OVER(PARTITION BY client_id ORDER BY client_id, exit_date DESC, entry_exit_id DESC) AS exit_row
    FROM sp_entry_exit tee 
    JOIN (SELECT DISTINCT uat.provider_id FROM qlik_user_access_tier_view uat WHERE uat.user_access_tier != 1) u USING (provider_id)
    WHERE active AND (exit_date IS NULL OR exit_date::DATE >= $2::DATE);

    FOREACH _type IN ARRAY _types LOOP
        IF _type = 'review' THEN
            _ee_limit := ''; -- Probably join to the sp_entry_exit_review table?????
            _primary_key := 'eer.entry_exit_review_id';
        ELSIF _type = 'exit' THEN
            _ee_limit := 'AND (ee.exit_date IS NULL OR qaa.date_effective::DATE <= ee.exit_date::DATE)';
        ELSE
            _ee_limit := 'AND qaa.date_effective::DATE <= ee.entry_date::DATE';
        END IF;

        _question_query := 'SELECT DISTINCT virt_field_name FROM qlik_'||_type||'_answers 
        UNION SELECT DISTINCT virt_field_name FROM qlik_answer_access qaa ORDER BY 1';

        _inner_query := 'SELECT DISTINCT ON (tier_link, '||_primary_key||', virt_field_name) tier_link||''''|''''||'||_primary_key||' AS sec_key, virt_field_name, answer_val
                 FROM (
                 SELECT '||_primary_key||', tier_link, virt_field_name, answer_val, date_effective 
                 FROM qlik_'||_type||'_answers qea
                 JOIN sp_entry_exit ee ON (qea.entry_exit_id = ee.entry_exit_id) -- TODO should probably change this???????
                 JOIN qlik_user_access_tier_view uat ON (ee.provider_id = uat.provider_id AND uat.user_access_tier = 1)
                 UNION
                 SELECT DISTINCT '||_primary_key||', uat.tier_link, virt_field_name, answer_val, date_effective
                 FROM qlik_answer_access qaa 
                 JOIN tmp_relevant_ees ee ON (ee.client_id = qaa.client_id '||_ee_limit||')
                 JOIN qlik_user_access_tier_view uat ON (uat.user_access_tier != 1)
                 WHERE ee.provider_id = uat.provider_id 
                   OR (qaa.visibility_id IS NOT NULL 
                       AND EXISTS (SELECT 1 FROM qlik_answer_vis_provider qap WHERE qap.visibility_id = qaa.visibility_id AND qap.provider_id = ee.provider_id))
                 ) t
                 ORDER BY '||_primary_key||', tier_link, virt_field_name, date_effective DESC';

        _dsql := 'SELECT FORMAT(
        $$
          SELECT * FROM crosstab('''||_inner_query||''', '''||_question_query||''')
        AS
        (
            sec_key VARCHAR,
            %s
        )
        $$,
        string_agg(FORMAT(''%I %s'', upper(virt_field_name)||''_'||_type||''', ''TEXT''), '', '' ORDER BY virt_field_name)
    )
    FROM (
        '||_question_query||'
    )
        AS t';

        RAISE NOTICE 'Creating the pivot query %',clock_timestamp();
        EXECUTE _dsql INTO _final_query;
        RAISE NOTICE 'Finished creating pivot query %: %', _type, clock_timestamp();

        EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS qlik_'||_type||'_answer_pivot_view';
        EXECUTE 'CREATE MATERIALIZED VIEW qlik_'||_type||'_answer_pivot_view AS '||_final_query;
        RAISE NOTICE 'Finished creating pivot view %: %', _type, clock_timestamp();
        
        EXECUTE 'ALTER TABLE qlik_'||_type||'_answer_pivot_view OWNER TO sp5user';
    END LOOP;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

-- select qlik_build_answer_pivot_views('2015-01-01', '2015-01-01', null);


select * from qlik_entry_answer_pivot_view
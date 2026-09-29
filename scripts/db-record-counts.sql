-- Hitung record per tabel CompreFace + embedding per model (calculator).
-- Read-only. Dipakai untuk validasi migrasi/restore (docs/MIGRATION.md, docs/RUNBOOK.md):
--   psql -U <user> -d frs -At -F '|' < scripts/db-record-counts.sql > counts.txt
select 'table:' || t, n from (
            select 'user' as t, count(*) as n from "user"
  union all select 'app', count(*) from app
  union all select 'model', count(*) from model
  union all select 'subject', count(*) from subject
  union all select 'img', count(*) from img
  union all select 'embedding', count(*) from embedding
  union all select 'user_app_role', count(*) from user_app_role
  union all select 'model_statistic', count(*) from model_statistic
  union all select 'install_info', count(*) from install_info
  union all select 'databasechangelog', count(*) from databasechangelog
) c
union all
select 'embedding:' || coalesce(calculator, '<null>'), count(*) from embedding group by calculator
order by 1;

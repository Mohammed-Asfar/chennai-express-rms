-- print_jobs is branch-local: print state is meaningless in the cloud, and the
-- sync worker never pushes it (SCHEMA.md section 5).
--
-- It was included in 0001 by mistake. 0001 has been applied, and migrations are
-- append-only, so this fixes forward rather than editing history.

DROP TABLE IF EXISTS print_jobs;

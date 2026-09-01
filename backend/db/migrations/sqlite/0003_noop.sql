-- Reserved. 0003 drops print_jobs from Postgres only; the table is branch-local
-- and must stay in SQLite.
--
-- The number is held in both dialects so migration 0003 means the same change
-- everywhere, and the two folders stay aligned.
SELECT 1;

-- Reserved. 0006 adds a 'cancelled' print job status to SQLite only.
--
-- print_jobs was dropped from Postgres in 0003: print state is branch-local and
-- meaningless in the cloud. The number is held in both dialects so migration
-- 0006 means the same change everywhere, and the two folders stay aligned.
SELECT 1;

-- Counterpart to sqlite/0005.

ALTER TABLE bills ADD COLUMN IF NOT EXISTS bill_period TEXT NOT NULL DEFAULT '';
ALTER TABLE bills ADD COLUMN IF NOT EXISTS bill_number TEXT NOT NULL DEFAULT '';

UPDATE bills SET bill_period = business_date::text WHERE bill_period = '';
UPDATE bills SET bill_number = bill_no::text WHERE bill_number = '';

DROP INDEX IF EXISTS idx_bills_no;
CREATE UNIQUE INDEX idx_bills_no ON bills(branch_id, bill_period, bill_no);
CREATE INDEX IF NOT EXISTS idx_bills_period ON bills(branch_id, bill_period);

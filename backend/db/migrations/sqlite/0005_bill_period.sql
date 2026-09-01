-- Configurable bill numbering.
--
-- The sequence resets per period (daily, monthly, yearly, financial year, or
-- never), so uniqueness must key on the period rather than the date: with
-- monthly reset, bill 47 recurs on many dates within the month.
--
-- `bill_number` is the formatted string as printed, stored so a reprint always
-- shows what the original showed even if the format is changed later.

ALTER TABLE bills ADD COLUMN bill_period TEXT NOT NULL DEFAULT '';
ALTER TABLE bills ADD COLUMN bill_number TEXT NOT NULL DEFAULT '';

-- Existing rows were numbered daily, so their period is their business date.
UPDATE bills SET bill_period = business_date WHERE bill_period = '';
UPDATE bills SET bill_number = CAST(bill_no AS TEXT) WHERE bill_number = '';

DROP INDEX IF EXISTS idx_bills_no;
CREATE UNIQUE INDEX idx_bills_no ON bills(branch_id, bill_period, bill_no);
CREATE INDEX idx_bills_period ON bills(branch_id, bill_period);

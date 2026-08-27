.open combo.db
DROP TABLE IF EXISTS gpu_test;
CREATE TABLE gpu_test (
    id INTEGER PRIMARY KEY,
    age INTEGER,
    score INTEGER,
    category INTEGER,
    value INTEGER
);
.print Inserting 500,000,000 rows into combo.db...
BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 500000000
)
INSERT INTO gpu_test (id, age, score, category, value)
SELECT
    x,
    20 + (x % 60),
    (x * 17) % 100,
    (x % 10),
    (x * 13) % 10000
FROM cnt;
COMMIT;
.print Done!
SELECT COUNT(*) AS total FROM gpu_test;

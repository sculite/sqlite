.print ========================================
.print Pipelining Test (>10M rows, multiple batches)
.print ========================================
.print

DROP TABLE IF EXISTS pip_test;
CREATE TABLE pip_test (
    id INTEGER PRIMARY KEY,
    age INTEGER,
    score INTEGER
);

.print Inserting 30,000,000 rows...
BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 30000000
)
INSERT INTO pip_test (id, age, score)
SELECT x, x % 100, (x * 7) % 50
FROM cnt;
COMMIT;
.print Done!
.print

SELECT COUNT(*) FROM pip_test;
.print

.print Test 1: COUNT WHERE age = 50 (300037)
.timer ON
SELECT COUNT(*) FROM pip_test WHERE age = 50;
.timer OFF
.print

.print Test 2: COUNT WHERE score > 25 (expect ~15M)
.timer ON
SELECT COUNT(*) FROM pip_test WHERE score > 25;
.timer OFF
.print

.print Test 3: COUNT WHERE age >= 90 (expect ~300037)
.timer ON
SELECT COUNT(*) FROM pip_test WHERE age >= 90;
.timer OFF
.print

.print Test 4: COUNT WHERE score >= 0 (expect 30M all)
.timer ON
SELECT COUNT(*) FROM pip_test WHERE score >= 0;
.timer OFF
.print

.print ========================================
.print Done!

.print ========================================
.print CPU-Only Baseline (10M rows)
.print ========================================
.print

DROP TABLE IF EXISTS gpu_test;
CREATE TABLE gpu_test (
    id INTEGER PRIMARY KEY,
    age INTEGER,
    score INTEGER,
    category INTEGER,
    value INTEGER
);

.print Inserting 10,000,000 rows...
BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 10000000
)
INSERT INTO gpu_test (id, age, score, category, value)
SELECT x, 20 + (x % 60), (x * 17) % 100, (x % 10), (x * 13) % 10000
FROM cnt;
COMMIT;
.print Done!
.print

SELECT COUNT(*) AS total_rows FROM gpu_test;
.print

.print ========================================
.print Test 1: Simple Equality WHERE
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age = 30;
.timer OFF
.print

.print ========================================
.print Test 2: Greater Than WHERE
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score > 50;
.timer OFF
.print

.print ========================================
.print Test 3: Multiple AND Conditions
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age >= 25 AND score <= 75;
.timer OFF
.print

.print ========================================
.print Test 4: Three AND Conditions
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print

.print ========================================
.print Test 5: Complex Range
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value >= 1000 AND value < 5000;
.timer OFF
.print

.print ========================================
.print Test 6: Return Rows
.print ========================================
.timer ON
SELECT id, age, score FROM gpu_test WHERE age = 25 LIMIT 10;
.timer OFF
.print

-- CPU-Only: 500M Row Benchmark
-- Creates table, inserts, then queries
.print ========================================
.print CPU-Only 500M Row Benchmark
.print ========================================
.print

DROP TABLE IF EXISTS bench500;
CREATE TABLE bench500 (
    id INTEGER PRIMARY KEY,
    age INTEGER,
    score INTEGER,
    category INTEGER,
    value INTEGER
);

.print Inserting 500,000,000 rows...
BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 500000000
)
INSERT INTO bench500 (id, age, score, category, value)
SELECT
    x,
    20 + (x % 60),
    (x * 17) % 100,
    (x % 10),
    (x * 13) % 10000
FROM cnt;
COMMIT;
.print Done!
.print
SELECT COUNT(*) FROM bench500;
.print

.print ========================================
.print Test 1: Simple Equality WHERE
.print Query: SELECT COUNT(*) FROM bench500 WHERE age = 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age = 30;
.timer OFF
.print

.print ========================================
.print Test 2: Greater Than WHERE
.print Query: SELECT COUNT(*) FROM bench500 WHERE score > 50
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE score > 50;
.timer OFF
.print

.print ========================================
.print Test 3: Multiple AND Conditions
.print Query: SELECT COUNT(*) FROM bench500 WHERE age >= 25 AND score <= 75
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age >= 25 AND score <= 75;
.timer OFF
.print

.print ========================================
.print Test 4: Three AND Conditions
.print Query: SELECT COUNT(*) FROM bench500 WHERE age > 30 AND score < 80 AND category = 5
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print

.print ========================================
.print Test 5: Complex Range
.print Query: SELECT COUNT(*) FROM bench500 WHERE value >= 1000 AND value < 5000
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE value >= 1000 AND value < 5000;
.timer OFF
.print

-- Quick correctness test for aggregate shortcut
.print ========================================
.print Aggregate Shortcut Correctness Test
.print ========================================

DROP TABLE IF EXISTS agg_test;
CREATE TABLE agg_test (
    id INTEGER PRIMARY KEY,
    a INTEGER,
    b INTEGER
);

-- Insert 1000 rows
BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 1000
)
INSERT INTO agg_test (id, a, b)
SELECT x, x % 100, x * 3 FROM cnt;
COMMIT;

SELECT COUNT(*) AS total FROM agg_test;
.print

-- Test 1: ~50% match
.print Test 1: COUNT WHERE a > 50
SELECT COUNT(*) FROM agg_test WHERE a > 50;
.print Expected: ~495

-- Test 2: ~25% match
.print Test 2: COUNT WHERE a >= 75
SELECT COUNT(*) FROM agg_test WHERE a >= 75;
.print Expected: ~250

-- Test 3: Very selective
.print Test 3: COUNT WHERE a = 50
SELECT COUNT(*) FROM agg_test WHERE a = 50;
.print Expected: 10

-- Test 4: AND conditions
.print Test 4: COUNT WHERE a > 20 AND b < 2000
SELECT COUNT(*) FROM agg_test WHERE a > 20 AND b < 2000;
.print

-- Test 5: No matches
.print Test 5: COUNT WHERE a > 999 (no matches)
SELECT COUNT(*) FROM agg_test WHERE a > 999;
.print Expected: 0

-- Test 6: All match
.print Test 6: COUNT WHERE a >= 0
SELECT COUNT(*) FROM agg_test WHERE a >= 0;
.print Expected: 1000

-- Test 7: Non-aggregate (should use normal GPU path)
.print Test 7: Non-aggregate SELECT
SELECT id, a, b FROM agg_test WHERE a = 50 LIMIT 5;

.print ========================================
.print Done!

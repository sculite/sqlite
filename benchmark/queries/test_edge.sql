-- Edge case + non-COUNT aggregate test
.print ========================================
.print Edge Case & Aggregate Type Tests
.print ========================================

DROP TABLE IF EXISTS edge_test;
CREATE TABLE edge_test (
    id INTEGER PRIMARY KEY,
    a INTEGER,
    b INTEGER
);

BEGIN TRANSACTION;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 500
)
INSERT INTO edge_test (id, a, b)
SELECT x, 
  CASE WHEN x % 5 = 0 THEN NULL ELSE x % 100 END,
  x * 2
FROM cnt;
COMMIT;

SELECT COUNT(*) FROM edge_test;
.print

-- Test 1: COUNT with NULLs
.print Test 1: COUNT(*) WHERE a > 50 (has NULLs)
SELECT COUNT(*) FROM edge_test WHERE a > 50;
.print

-- Test 2: COUNT with no matches
.print Test 2: COUNT(*) WHERE a > 999
SELECT COUNT(*) FROM edge_test WHERE a > 999;
.print

-- Test 3: COUNT with all match
.print Test 3: COUNT(*) WHERE a >= 0
SELECT COUNT(*) FROM edge_test WHERE a >= 0;
.print

-- Test 4: Non-aggregate SELECT (row returning)
.print Test 4: Row-returning SELECT
SELECT id, a, b FROM edge_test WHERE a = 50 LIMIT 5;
.print

-- Test 5: COUNT with multiple AND
.print Test 5: COUNT(*) WHERE a > 20 AND b < 200
SELECT COUNT(*) FROM edge_test WHERE a > 20 AND b < 200;
.print

-- CRITICAL: Test 6 - SUM aggregate (non-COUNT)
.print Test 6: SUM(b) WHERE a > 50 (NON-COUNT AGGREGATE)
SELECT SUM(b) FROM edge_test WHERE a > 50;
.print

-- CRITICAL: Test 7 - AVG aggregate
.print Test 7: AVG(a) WHERE a > 50 (NON-COUNT AGGREGATE)  
SELECT AVG(a) FROM edge_test WHERE a > 50;
.print

-- CRITICAL: Test 8 - MAX aggregate
.print Test 8: MAX(b) WHERE a > 50 (NON-COUNT AGGREGATE)
SELECT MAX(b) FROM edge_test WHERE a > 50;
.print

-- CRITICAL: Test 9 - MIN aggregate
.print Test 9: MIN(b) WHERE a > 50 (NON-COUNT AGGREGATE)
SELECT MIN(b) FROM edge_test WHERE a > 50;
.print

.print ========================================
.print Done!

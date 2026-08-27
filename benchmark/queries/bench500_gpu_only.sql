-- GPU queries on existing 500M table (already inserted by CPU run)
.print ========================================
.print GPU 500M Row Benchmark
.print ========================================
.print

SELECT COUNT(*) AS total FROM bench500;
.print

.print ========================================
.print Test 1: SELECT COUNT(*) FROM bench500 WHERE age = 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age = 30;
.timer OFF
.print

.print ========================================
.print Test 2: SELECT COUNT(*) FROM bench500 WHERE score > 50
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE score > 50;
.timer OFF
.print

.print ========================================
.print Test 3: SELECT COUNT(*) FROM bench500 WHERE age >= 25 AND score <= 75
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age >= 25 AND score <= 75;
.timer OFF
.print

.print ========================================
.print Test 4: SELECT COUNT(*) FROM bench500 WHERE age > 30 AND score < 80 AND category = 5
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print

.print ========================================
.print Test 5: SELECT COUNT(*) FROM bench500 WHERE value >= 1000 AND value < 5000
.print ========================================
.timer ON
SELECT COUNT(*) FROM bench500 WHERE value >= 1000 AND value < 5000;
.timer OFF
.print

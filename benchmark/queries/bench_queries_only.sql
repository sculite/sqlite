-- Queries only on existing 500M table
.print ========================================
.print GPU 500M Batch=20M
.print ========================================
.print

SELECT COUNT(*) AS total_rows FROM gpu_test;
.print

.print Test 1: age = 30
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age = 30;
.timer OFF
.print

.print Test 2: score > 50
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score > 50;
.timer OFF
.print

.print Test 3: age >= 25 AND score <= 75
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age >= 25 AND score <= 75;
.timer OFF
.print

.print Test 4: age > 30 AND score < 80 AND category = 5
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print

.print Test 5: value >= 1000 AND value < 5000
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value >= 1000 AND value < 5000;
.timer OFF
.print

.print Test 6: Return Rows
.timer ON
SELECT id, age, score FROM gpu_test WHERE age = 25 LIMIT 10;
.timer OFF
.print

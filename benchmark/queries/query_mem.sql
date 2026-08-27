.open combo.db
ATTACH ':memory:' AS mem;
CREATE TABLE mem.gpu_test AS SELECT * FROM main.gpu_test;
SELECT COUNT(*) AS total FROM mem.gpu_test;
.print ============ IN-MEMORY 500M TESTS ============
.print

.print S1: age = 30
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age = 30;
.timer OFF
.print
.print S2: score > 50
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE score > 50;
.timer OFF
.print
.print S3: age >= 25 AND score <= 75
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age >= 25 AND score <= 75;
.timer OFF
.print
.print S4: age > 30 AND score < 80 AND category = 5
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print
.print S5: value >= 1000 AND value < 5000
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE value >= 1000 AND value < 5000;
.timer OFF
.print
.print E1: age > 999 (0 match)
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age > 999;
.timer OFF
.print
.print E2: age >= 0 (all)
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age >= 0;
.timer OFF
.print
.print E10: category = 7
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE category = 7;
.timer OFF
.print
.print E12: 6 conditions
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age>=20 AND age<80 AND score>=0 AND score<100 AND category>=0 AND category<10 AND id>=0;
.timer OFF
.print
.print Done!

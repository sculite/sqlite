.open combo_250m.db
ATTACH ':memory:' AS mem;
CREATE TABLE mem.gpu_test AS SELECT * FROM main.gpu_test;
SELECT COUNT(*) AS total FROM mem.gpu_test;
.print ============ 250M IN-MEMORY ALL TESTS ============
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
.print E1: age > 999
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age > 999;
.timer OFF
.print
.print E2: age >= 0
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age >= 0;
.timer OFF
.print
.print E3: value = 0
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE value = 0;
.timer OFF
.print
.print E4: value = 9999
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE value = 9999;
.timer OFF
.print
.print E5: age < 30
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age < 30;
.timer OFF
.print
.print E6: age <= 29
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age <= 29;
.timer OFF
.print
.print E7: age <= 30
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age <= 30;
.timer OFF
.print
.print E8: score = 0
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE score = 0;
.timer OFF
.print
.print E9: score > 99
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE score > 99;
.timer OFF
.print
.print E10: category = 7
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE category = 7;
.timer OFF
.print
.print E11: age = 30 AND score = 30
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age = 30 AND score = 30;
.timer OFF
.print
.print E12: 6 conditions
.timer ON
SELECT COUNT(*) FROM mem.gpu_test WHERE age>=20 AND age<80 AND score>=0 AND score<100 AND category>=0 AND category<10 AND id>=0;
.timer OFF
.print
.print Done!

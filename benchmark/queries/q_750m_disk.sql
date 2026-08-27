.open combo_750m.db
.print ========================================
.print 750M Comprehensive Test (queries only)
.print ========================================
.print
SELECT COUNT(*) AS total FROM gpu_test;
.print

-- ============ STD TESTS (COUNT) ============
.print ========================================
.print S1: age = 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age = 30;
.timer OFF
.print
.print ========================================
.print S2: score > 50
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score > 50;
.timer OFF
.print
.print ========================================
.print S3: age >= 25 AND score <= 75
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age >= 25 AND score <= 75;
.timer OFF
.print
.print ========================================
.print S4: age > 30 AND score < 80 AND category = 5
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age > 30 AND score < 80 AND category = 5;
.timer OFF
.print
.print ========================================
.print S5: value >= 1000 AND value < 5000
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value >= 1000 AND value < 5000;
.timer OFF
.print

-- ============ EDGE CASES ============
.print ========================================
.print E1: no matches (age > 999) -> 0
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age > 999;
.timer OFF
.print
.print ========================================
.print E2: all match (age >= 0) -> <all rows>
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age >= 0;
.timer OFF
.print
.print ========================================
.print E3: value = 0
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value = 0;
.timer OFF
.print
.print ========================================
.print E4: value = 9999
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value = 9999;
.timer OFF
.print
.print ========================================
.print E5: age < 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age < 30;
.timer OFF
.print
.print ========================================
.print E6: age <= 29
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age <= 29;
.timer OFF
.print
.print ========================================
.print E7: age <= 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age <= 30;
.timer OFF
.print
.print ========================================
.print E8: score = 0
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score = 0;
.timer OFF
.print
.print ========================================
.print E9: score > 99
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score > 99;
.timer OFF
.print
.print ========================================
.print E10: category = 7
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE category = 7;
.timer OFF
.print
.print ========================================
.print E11: age = 30 AND score = 30
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age = 30 AND score = 30;
.timer OFF
.print
.print ========================================
.print E12: 6 conditions all-pass
.print ========================================
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age>=20 AND age<80 AND score>=0 AND score<100 AND category>=0 AND category<10 AND id>=0;
.timer OFF
.print
.print ========================================
.print Done!

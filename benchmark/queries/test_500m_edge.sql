-- Edge case correctness tests on the 500M gpu_test table
-- Data: id=x, age=20+(x%60), score=(x*17)%100, category=x%10, value=(x*13)%10000
.print ========================================
.print 500M Edge Case Correctness Tests
.print ========================================
.print
SELECT COUNT(*) AS total FROM gpu_test;
.print

-- Test A: no matches
.print A: COUNT WHERE age > 999 (expect 0)
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age > 999;
.timer OFF
.print

-- Test B: all match
.print B: COUNT WHERE age >= 0 (expect 500M)
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age >= 0;
.timer OFF
.print

-- Test C: equality boundary
.print C: COUNT WHERE value = 0 (value=(x*13)%10000, 0 when x*13 mod 10000=0)
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value = 0;
.timer OFF
.print

-- Test D: value = 9999 (near max)
.print D: COUNT WHERE value = 9999
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE value = 9999;
.timer OFF
.print

-- Test E: adjacent comparison (< vs <=)
.print E1: COUNT WHERE age < 30
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age < 30;
.timer OFF
.print
.print E2: COUNT WHERE age <= 29
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age <= 29;
.timer OFF
.print
.print E3: COUNT WHERE age <= 30
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age <= 30;
.timer OFF
.print

-- Test F: score boundaries (score=(x*17)%100)
.print F1: COUNT WHERE score = 0
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score = 0;
.timer OFF
.print
.print F2: COUNT WHERE score > 99
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE score > 99;
.timer OFF
.print

-- Test G: category single residue
.print G: COUNT WHERE category = 7 (expect 50M, x%10==7)
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE category = 7;
.timer OFF
.print

-- Test H: multi-condition tight
.print H: COUNT WHERE age = 30 AND score = 30
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age = 30 AND score = 30;
.timer OFF
.print

-- Test I: many AND conditions (4)
.print I: COUNT WHERE age>=20 AND age<80 AND score>=0 AND score<100 AND category>=0 AND category<10
.timer ON
SELECT COUNT(*) FROM gpu_test WHERE age>=20 AND age<80 AND score>=0 AND score<100 AND category>=0 AND category<10;
.timer OFF
.print

.print ========================================
.print Done!

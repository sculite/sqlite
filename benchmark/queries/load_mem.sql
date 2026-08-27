.open combo.db
ATTACH ':memory:' AS mem;
.print Loading main.gpu_test into :memory:...
CREATE TABLE mem.gpu_test AS SELECT * FROM main.gpu_test;
.print Loaded!
SELECT COUNT(*) AS total FROM mem.gpu_test;
.print Done loading

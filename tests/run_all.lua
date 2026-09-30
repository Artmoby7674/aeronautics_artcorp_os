-- Runs every repo test. From repo root:
--   lua5.4 tests/run_all.lua      (or lua5.3 / luajit)
dofile("tests/pid_test.lua")
dofile("tests/vertical_test.lua")
dofile("tests/ap_test.lua")
dofile("tests/hud_test.lua")
print("ALL TESTS PASSED")

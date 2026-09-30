-- Unit tests for lib/pid.lua — pure logic, no CC APIs (runs on CC too).
-- Run from repo root: lua5.4 tests/pid_test.lua

local PID = dofile("lib/pid.lua")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL: %s%s", name,
            detail ~= nil and (" -- got " .. tostring(detail)) or ""))
    end
end

-- P-only: output is exactly kp * error
local p = PID.new({ kp = 2, ki = 0, kd = 0, output_limit = 100 })
check("P proportional", math.abs(p:update(10, 7, 0.05) - 6) < 1e-9,
    p:update(10, 7, 0.05))

-- Saturation at output_limit, both signs
local s = PID.new({ kp = 2, ki = 0, kd = 0, output_limit = 7 })
check("saturation +", s:update(0, -10, 0.05) == 7, s:update(0, -10, 0.05))
check("saturation -", s:update(0, 10, 0.05) == -7, s:update(0, 10, 0.05))

-- Integral accumulates over ticks and clamps at integral_limit
local i = PID.new({ kp = 0, ki = 1, kd = 0, integral_limit = 0.2, output_limit = 100 })
local acc
for _ = 1, 100 do acc = i:update(1, 0, 0.05) end -- would be 5.0 unclamped
check("integral clamp", math.abs(acc - 0.2) < 1e-9, acc)

-- integral_separation: no integration outside the band
local sep = PID.new({ kp = 0, ki = 1, kd = 0, integral_limit = 10,
    integral_separation = 2, output_limit = 100 })
sep:update(10, 0, 0.05) -- error 10, band 2 -> must not integrate
check("integral separation", math.abs(sep.integral) < 1e-12, sep.integral)

-- D on measurement: d = -kd * rate (climb-rate feedback)
local dm = PID.new({ kp = 0, ki = 0, kd = 1, d_on_measurement = true, output_limit = 100 })
check("D on measurement sign", math.abs(dm:update(0, 0, 0.05, 4) - (-4)) < 1e-9,
    dm:update(0, 0, 0.05, 4))

-- D from error derivative: zero on the first tick (no previous error)
local de = PID.new({ kp = 0, ki = 0, kd = 5, output_limit = 100 })
check("D first tick zero", de:update(3, 0, 0.05) == 0, de:update(3, 0, 0.05))

-- dt <= 0 is a no-op
check("dt guard", p:update(1, 0, 0) == 0, p:update(1, 0, 0))

-- reset() clears integral / derivative memory
local r = PID.new({ kp = 0, ki = 1, kd = 0, integral_limit = 10, output_limit = 100 })
r:update(1, 0, 0.05)
r:update(1, 0, 0.05)
r:reset()
check("reset clears integral", r.integral == 0 and r.prev_time == nil,
    r.integral)

print(string.format("pid_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("pid_test FAILED", 0) end

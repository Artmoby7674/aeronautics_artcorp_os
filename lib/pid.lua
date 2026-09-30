local PID = {}
PID.__index = PID

function PID.new(cfg)
    local self = setmetatable({}, PID)
    self.kp = cfg.kp or 1.0
    self.ki = cfg.ki or 0.0
    self.kd = cfg.kd or 0.0
    self.integral_limit = cfg.integral_limit or 10
    self.output_limit = cfg.output_limit or 15
    -- Derivative on measurement (e.g. climb rate) avoids setpoint-step kicks
    self.d_on_measurement = not not cfg.d_on_measurement
    -- Only integrate while |error| is within this band (anti-windup); nil = always
    self.integral_separation = cfg.integral_separation

    self.integral = 0
    self.prev_error = 0
    self.prev_time = nil

    return self
end

function PID:update(setpoint, current, dt, meas_rate)
    if dt <= 0 then return 0 end

    local error = setpoint - current

    local p = self.kp * error

    local sep = self.integral_separation
    if not sep or math.abs(error) <= sep then
        self.integral = self.integral + error * dt
        self.integral = math.max(-self.integral_limit, math.min(self.integral_limit, self.integral))
    end
    local i = self.ki * self.integral

    local d
    if self.d_on_measurement and meas_rate then
        -- d(error)/dt = -d(current)/dt when setpoint is held
        d = -self.kd * meas_rate
    else
        local derivative = 0
        if self.prev_time then
            derivative = (error - self.prev_error) / dt
        end
        d = self.kd * derivative
    end

    self.prev_error = error
    self.prev_time = os.clock()

    local output = p + i + d
    output = math.max(-self.output_limit, math.min(self.output_limit, output))

    return output, { p = p, i = i, d = d, error = error }
end

function PID:reset()
    self.integral = 0
    self.prev_error = 0
    self.prev_time = nil
end

function PID:setGains(kp, ki, kd)
    self.kp = kp
    self.ki = ki
    self.kd = kd
end

function PID:getGains()
    return { kp = self.kp, ki = self.ki, kd = self.kd }
end

return PID

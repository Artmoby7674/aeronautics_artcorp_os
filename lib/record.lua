-- Flight recorder: armed from the NAV tab REC button, samples the ship's
-- world position every REC_INTERVAL seconds. Memory only - a reboot clears
-- it, so print the report (lib/report.lua) before shutting down.

local Rec = {}

local REC_INTERVAL = 10 -- seconds between samples
local REC_CAP = 3600    -- max samples (10 h at 10 s)

local active = false
local t0 = 0
local last_sample = 0
local samples = {} -- { t, x, y, z } with t = seconds since recording start

local function addSample(pos)
    if not pos then return end
    samples[#samples + 1] = {
        os.clock() - t0,
        pos.x or 0,
        pos.y or 0,
        pos.z or 0,
    }
end

function Rec.start(pos)
    active = true
    t0 = os.clock()
    last_sample = t0
    samples = {}
    addSample(pos) -- anchor point at t = 0
end

function Rec.stop()
    active = false
end

function Rec.toggle(pos)
    if active then
        Rec.stop()
    else
        Rec.start(pos)
    end
    return active
end

function Rec.isActive() return active end
function Rec.count() return #samples end
function Rec.data() return samples end

function Rec.duration()
    if #samples == 0 then return 0 end
    return samples[#samples][1]
end

function Rec.clear()
    active = false
    samples = {}
end

-- Called from the control tick while recording.
function Rec.tick(now, pos)
    if not active then return end
    if now - last_sample < REC_INTERVAL then return end
    last_sample = now
    addSample(pos)
    if #samples >= REC_CAP then
        active = false -- hit the cap: stop, data kept for printing
    end
end

-- Summary for the report header: duration, sample count, per-axis min/max,
-- 3D path length.
function Rec.stats()
    local st = {
        count = #samples,
        duration = Rec.duration(),
        path = 0,
        min = { x = 0, y = 0, z = 0 },
        max = { x = 0, y = 0, z = 0 },
    }
    if #samples == 0 then return st end
    local first = samples[1]
    st.min = { x = first[2], y = first[3], z = first[4] }
    st.max = { x = first[2], y = first[3], z = first[4] }
    local prev = first
    for i = 2, #samples do
        local s = samples[i]
        st.min.x = math.min(st.min.x, s[2])
        st.min.y = math.min(st.min.y, s[3])
        st.min.z = math.min(st.min.z, s[4])
        st.max.x = math.max(st.max.x, s[2])
        st.max.y = math.max(st.max.y, s[3])
        st.max.z = math.max(st.max.z, s[4])
        local dx, dy, dz = s[2] - prev[2], s[3] - prev[3], s[4] - prev[4]
        st.path = st.path + math.sqrt(dx * dx + dy * dy + dz * dz)
        prev = s
    end
    return st
end

Rec.INTERVAL = REC_INTERVAL
Rec.CAP = REC_CAP

return Rec

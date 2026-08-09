local Device = require("device")

-- SDL's Emulator device advertises color support. The Paperwhite 4 does not,
-- so force the capability used by WeUI/KOReader without impersonating a Kindle
-- device (which would call Kindle-only system interfaces on macOS).
Device.hasColorScreen = function() return false end

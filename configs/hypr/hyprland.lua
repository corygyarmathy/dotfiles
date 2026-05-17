-- Hyprland Lua Configuration
-- Modular config split into separate files for error isolation.
-- Each require() runs in its own scope, so a failure in one file
-- won't take down binds or settings defined in other files.

require("env")
require("monitors")
require("settings")
require("animations")
require("rules")
require("binds")
require("autostart")

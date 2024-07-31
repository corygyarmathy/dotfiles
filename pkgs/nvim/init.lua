-- Set up the required lua files (in the 'Lua' folder)
require 'options'
require 'keymap'
require 'autocommands'
require 'lazy-bootstrap' -- Install Lazy (plugin manager)
require 'lazy-plugins' -- Install the required plugins through Lazy

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et

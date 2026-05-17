-- Animation curves and animations
-- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/

hl.config({ animations = { enabled = true } })

-- Curves
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })

-- Window animations
hl.animation({ leaf = "global",     enabled = true, speed = 10,   bezier = "default"      })
hl.animation({ leaf = "border",     enabled = true, speed = 2,    bezier = "default"      })
hl.animation({ leaf = "fade",       enabled = true, speed = 4,    bezier = "quick"        })
hl.animation({ leaf = "windows",    enabled = true, speed = 3,    bezier = "easeOutQuint", style = "popin 80%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.5,  bezier = "linear",       style = "popin 80%" })

-- Workspace animations
hl.animation({ leaf = "workspaces",    enabled = true, speed = 2,    bezier = "almostLinear", style = "slide" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 1.2,  bezier = "almostLinear", style = "slide" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.9,  bezier = "almostLinear", style = "slide" })

-- Layer (overlay/panel) animations
hl.animation({ leaf = "layers",        enabled = true, speed = 3.8,  bezier = "easeOutQuint"                   })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade"   })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade"   })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.8,  bezier = "almostLinear"                   })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.4,  bezier = "almostLinear"                   })

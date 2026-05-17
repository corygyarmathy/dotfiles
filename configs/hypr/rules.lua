-- Window rules
-- https://wiki.hypr.land/Configuring/Basics/Window-Rules/

-- App → workspace assignments
hl.window_rule({
    name  = "youtube-to-ws1",
    match = { title = "(.*)(- Youtube)$" },
    workspace = 1,
})

hl.window_rule({
    name  = "obsidian-to-ws3",
    match = { class = "^(obsidian)$" },
    workspace = 3,
})

hl.window_rule({
    name  = "discord-to-ws6",
    match = { class = "^(discord)$" },
    workspace = 6,
})

hl.window_rule({
    name  = "zotero-to-ws7",
    match = { class = "^(Zotero)$" },
    workspace = 7,
})

-- Suppress maximize requests from apps (avoids unexpected fullscreen grabs)
hl.window_rule({
    name  = "suppress-maximize",
    match = { class = ".*" },
    suppress_event = "maximize",
})

-- Fix drag-and-drop issues with some XWayland windows
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})

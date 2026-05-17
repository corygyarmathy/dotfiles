-- Environment variables
-- Required for Nvidia compatibility on Wayland

hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("GBM_BACKEND", "nvidia-drm")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")

-- Disable color management auto-HDR (may fix modeset failures on older monitors)
hl.env("AQ_NO_MODIFIERS", "1")

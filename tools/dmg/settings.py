# dmgbuild settings for the release dmg (tools/release.sh). The window shows the app, an arrow and Applications.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background_tiff = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (160, 196), "Applications": (480, 196)}
background = background_tiff
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13

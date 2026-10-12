# dmgbuild settings for the SmartShot installer.
# Build:  dmgbuild -s Resources/DMG/dmg_settings.py -D app=path/to/SmartShot.app "SmartShot" SmartShot.dmg
import os.path

app = defines.get('app', 'SmartShot.app')  # noqa: F821 (provided by dmgbuild)
here = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else 'Resources/DMG'

format = 'ULFO'                      # LZFSE compressed, macOS 10.11+
filesystem = 'HFS+'
size = None
files = [app]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(app, 'Contents', 'Resources', 'AppIcon.icns')   # the disk icon is the app icon

background = os.path.join(here, 'background.tiff')   # 660x420 with an @2x layer
window_rect = ((200, 160), (660, 420))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
label_pos = 'bottom'
icon_locations = {
    os.path.basename(app): (165, 228),   # standing on the ledge, left of the arrow
    'Applications': (495, 228),
}

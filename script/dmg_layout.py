"""Write a Finder layout without launching Finder or the packaged app."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

volume = Path(sys.argv[1])
app_name = sys.argv[2]
background = Alias.for_file(str(volume / '.background' / 'installer.png'))
with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
        'WindowBounds': '{{180, 160}, {720, 480}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': background.to_bytes(),
        'iconSize': 96.0, 'textSize': 13.0, 'gridSpacing': 100.0,
        'arrangeBy': 'none', 'labelOnBottom': True,
        'showIconPreview': True, 'showItemInfo': False,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['.']['icvl'] = ('type', b'icnv')
    store[app_name]['Iloc'] = (190, 245)
    store['Applications']['Iloc'] = (530, 245)

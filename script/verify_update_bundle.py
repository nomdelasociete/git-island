#!/usr/bin/env python3
"""Verify distribution separation in actual built bundles, without credentials."""
import plistlib
from pathlib import Path
import sys

bundle = Path(sys.argv[1])
channel = sys.argv[2]
with (bundle / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
framework = bundle / 'Contents/Frameworks/Sparkle.framework'
assert info['CFBundleShortVersionString'] and info['CFBundleVersion']
assert info['LSUIElement'] is True
if channel == 'direct':
    assert framework.is_dir(), 'Missing embedded updater'
    assert info['SUFeedURL'] == 'https://gitis.land/appcast.xml'
    assert info['SUPublicEDKey'] == 'KSSnb4UT84hhhYlq55Icrcn4oMUGbyObjmfDVCZhyJ4='
    if len(sys.argv) > 3 and sys.argv[3] != info['SUPublicEDKey']:
        raise ValueError('Signing account public key does not match the app update key')
    for key in ('SUEnableInstallerLauncherService', 'SUEnableAutomaticChecks',
                'SUAutomaticallyUpdate', 'SUVerifyUpdateBeforeExtraction'):
        assert info[key] is True, f'{key} must be a plist boolean'
    assert info['SUEnableSystemProfiling'] is False
    assert (framework / 'XPCServices/Installer.xpc').is_dir()
elif channel == 'apple':
    assert not framework.exists(), 'Apple distribution must not embed Sparkle'
    assert not any(key.startswith('SU') for key in info), 'Unexpected updater configuration'
else:
    raise ValueError('Expected direct or apple')
print(f'{channel} distribution bundle verified')

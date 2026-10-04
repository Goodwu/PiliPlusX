#!/usr/bin/env python3
"""Reject an Intel replacement not produced from the pinned build inputs."""
import json
import pathlib
import sys
from build_macos_mpv_x86 import sha256, MPV_SHA, FFMPEG_SHA, ASS_SHA, ARCHIVE_SHA

slice_path = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
try:
    manifest = json.loads(slice_path.with_suffix('.json').read_text())
    expected = dict(schema=1, mpv='0.41.0', mpv_source_sha256=MPV_SHA,
                    ffmpeg_source_sha256=FFMPEG_SHA, libass_source_sha256=ASS_SHA,
                    reviewed_archive_sha256=ARCHIVE_SHA,
                    slice_sha256=sha256(slice_path),
                    ass_binary_sha256=sha256(app / 'Contents/Frameworks/Ass.framework/Versions/A/Ass'),
                    ass_install_name='@rpath/Ass.framework/Versions/A/Ass')
    if manifest != expected:
        raise ValueError('Intel mpv build identity mismatch')
except (OSError, ValueError) as error:
    sys.exit(f'FAIL: {error}')
print('PASS: pinned Intel mpv slice identity')

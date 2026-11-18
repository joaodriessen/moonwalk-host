#!/usr/bin/env python3
"""Render every Skylight icon from macos-dist/AppIcon.icon, the Icon Composer document.

The document's leather is baked from the mark; after changing macos-dist/AppIcon-mark.svg, run

    scripts/icons/press-app-icon.py macos-dist/AppIcon-mark.svg macos-dist/AppIcon.icon

Needs Pillow, and Xcode 26 or later for Icon Composer's renderer. Off a Mac, name one:

    scripts/icons/generate-app-icons.py --mac user@host
"""
import argparse, io, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageCms, ImageFilter

REPO = Path(__file__).resolve().parent.parent.parent
DOC = REPO / 'macos-dist/AppIcon.icon'
ICTOOL = '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'
SRGB = ImageCms.createProfile('sRGB')


class Renderer:
    def __init__(self, mac, work):
        self.mac, self.work, self.remote = mac, Path(work), None
        if mac:
            self.remote = self.ssh('mktemp -d').strip()
            subprocess.run(['scp', '-q', '-r', str(DOC), f'{mac}:{self.remote}/AppIcon.icon'], check=True)

    def ssh(self, command):
        return subprocess.run(['ssh', '-o', 'BatchMode=yes', self.mac, command], check=True, capture_output=True, text=True).stdout

    def close(self):
        if self.remote:
            self.ssh(f'rm -rf {shlex.quote(self.remote)}')

    def body(self, size):
        """The icon's own shape at exactly this size, in sRGB. Icon Composer renders Display P3."""
        name = f'body-{size}.png'
        args = ['--export-image', '--platform', 'macOS', '--rendition', 'Default', '--width', str(size),
                '--height', str(size), '--scale', '1', '--design-generation', '27', '--output-file']
        if self.mac:
            target = f'{self.remote}/{name}'
            self.ssh(shlex.join([ICTOOL, f'{self.remote}/AppIcon.icon', *args, target]))
            subprocess.run(['scp', '-q', f'{self.mac}:{target}', str(self.work / name)], check=True)
        else:
            subprocess.run([ICTOOL, str(DOC), *args, str(self.work / name)], check=True, capture_output=True)
        image = Image.open(self.work / name)
        profile = image.info.get('icc_profile')
        if profile:
            image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(profile)), SRGB, outputMode='RGBA')
        return image.convert('RGBA')

    def iconutil(self, iconset, output):
        if self.mac:
            subprocess.run(['scp', '-q', '-r', str(iconset), f'{self.mac}:{self.remote}/AppIcon.iconset'], check=True)
            self.ssh(f'iconutil -c icns -o {self.remote}/AppIcon.icns {self.remote}/AppIcon.iconset')
            subprocess.run(['scp', '-q', f'{self.mac}:{self.remote}/AppIcon.icns', str(output)], check=True)
        else:
            subprocess.run(['iconutil', '-c', 'icns', '-o', str(output), str(iconset)], check=True)


def framed(renderer, size):
    """Apple's grid: the shape takes 824/1024 of the canvas, over a soft shadow.

    Below 48 pixels a margin and shadow only cost legibility, so the shape nearly fills it."""
    if size < 48:
        body = renderer.body(max(size - 2 * max(1, size // 24), 1))
        canvas = Image.new('RGBA', (size, size))
        offset = (size - body.width) // 2
        canvas.alpha_composite(body, (offset, offset))
        return canvas
    side = round(size * 824 / 1024)
    side += (size - side) % 2
    body = renderer.body(side)
    offset = (size - side) // 2
    shadow = Image.new('RGBA', (size, size))
    shadow.paste((0, 0, 0, 255), (offset, offset + round(size * .012)), body.getchannel('A'))
    shadow.putalpha(shadow.getchannel('A').point(lambda a: a * .32))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * .014))
    shadow.alpha_composite(body, (offset, offset))
    return shadow


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mac', help='ssh destination of a Mac with Xcode, when not running on one')
    args = parser.parse_args()
    if not args.mac and sys.platform != 'darwin':
        parser.error('Icon Composer only runs on a Mac; pass --mac user@host')

    with tempfile.TemporaryDirectory() as work:
        renderer = Renderer(args.mac, work)
        try:
            icons = {size: framed(renderer, size) for size in (16, 24, 32, 48, 64, 128, 180, 256, 512, 1024)}
            images = REPO / 'src_assets/common/assets/web/public/images'
            icons[512].save(REPO / 'sunshine.png', optimize=True)
            icons[256].save(REPO / 'docs/assets/skylight-icon.png', optimize=True)
            icons[16].save(images / 'logo-sunshine-16.png', optimize=True)
            # Shown at 45 points on screens up to 4x.
            icons[180].save(images / 'logo-sunshine-45.png', optimize=True)
            icons[256].save(images / 'sunshine.ico', sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)],
                            append_images=[icons[n] for n in (16, 24, 32, 48, 64, 128)])

            iconset = Path(work) / 'AppIcon.iconset'
            iconset.mkdir()
            for size, name in ((16, '16x16'), (32, '16x16@2x'), (32, '32x32'), (64, '32x32@2x'), (128, '128x128'),
                               (256, '128x128@2x'), (256, '256x256'), (512, '256x256@2x'), (512, '512x512'), (1024, '512x512@2x')):
                icons[size].save(iconset / f'icon_{name}.png')
            renderer.iconutil(iconset, REPO / 'sunshine.icns')
        finally:
            renderer.close()


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Press AppIcon-mark.svg into Indigo leather and write the Icon Composer document around it.

White in the mark is cut into the leather; black is untouched. Needs numpy, Pillow and rsvg-convert.
The grain is seeded, so the same mark always gives the same bitmap.

    press-app-icon.py MARK.svg OUTPUT.icon
"""
import json, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image

N = 1024
TOP, BOTTOM, FLOOR = '#A3A7F2', '#6E73D2', '#3A3E96'
LIGHT = np.array([-.38, -.80, .46])
LIGHT = LIGHT / np.linalg.norm(LIGHT)


def blur(a, sigma):
    """Gaussian blur in the frequency domain; the edges wrap, and nothing important touches them."""
    fy = np.fft.fftfreq(a.shape[0])[:, None]
    fx = np.fft.rfftfreq(a.shape[1])[None, :]
    return np.fft.irfft2(np.fft.rfft2(a) * np.exp(-2 * (np.pi * sigma) ** 2 * (fx * fx + fy * fy)), s=a.shape)


def grain(seed, cell):
    """Pebbled leather: flat-topped cells with sharp creases between them, and a slow drift so it isn't regular."""
    rng = np.random.default_rng(seed)
    g = int(N / cell) + 2
    jx, jy = rng.random((g, g)), rng.random((g, g))
    y, x = np.mgrid[0:N, 0:N].astype(np.float32)
    cx, cy = (x / cell).astype(int), (y / cell).astype(int)
    d = []
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            ix, iy = (cx + dx) % g, (cy + dy) % g
            d.append(np.hypot((cx + dx + jx[iy, ix]) * cell - x, (cy + dy + jy[iy, ix]) * cell - y))
    d = np.sort(np.stack(d), axis=0)
    pebble = np.clip((d[1] - d[0]) / (cell * .42), 0, 1)
    pebble = pebble * pebble * (3 - 2 * pebble)
    drift = blur(rng.standard_normal((N, N)), 42)
    return pebble, drift / np.abs(drift).max()


def rgb(hex_):
    return np.array([int(hex_[i:i + 2], 16) for i in (1, 3, 5)], float) / 255


def to_linear(c):
    return np.where(c <= .04045, c / 12.92, ((c + .055) / 1.055) ** 2.4)


def to_srgb(c):
    return np.where(c <= .0031308, c * 12.92, 1.055 * np.clip(c, 0, None) ** (1 / 2.4) - .055)


def shift(a, dy):
    return np.roll(a, int(round(dy)), 0)


def press(mark, depth=1.2):
    fine, _ = grain(7, 8.5)
    broad, drift = grain(11, 21.0)
    pebble = .72 * fine + .28 * broad
    # the leather: lit grain, ironed flat and sunk a little where the mark is cut
    wall = blur(mark, 3.0)
    h = pebble * (1 - .8 * wall) * .84 + drift * 2 - wall * 3.0
    gy, gx = np.gradient(blur(h, .8))
    length = np.sqrt(gx * gx + gy * gy + 1)
    shade = (-gx * LIGHT[0] - gy * LIGHT[1] + LIGHT[2]) / length / LIGHT[2]
    shade = 1 + np.tanh((shade - 1) * .9) * .55
    t = np.linspace(0, 1, N)[:, None, None]
    lin = (to_linear(rgb(TOP)) * (1 - t) + to_linear(rgb(BOTTOM)) * t)
    lin = lin * (shade * (1 - .10 * (1 - pebble) * (1 - wall)) * (1 - .30 * wall))[..., None]
    # the cut: a dark floor, a shadow thrown down from the top lip, light on the bottom lip
    lin = lin * (1 - .40 * mark[..., None]) + to_linear(rgb(FLOOR)) * .40 * mark[..., None]
    lin *= (1 - .70 * np.clip(blur(shift(1 - mark, 12 * depth), 12 * depth) * mark, 0, 1))[..., None]
    rim = np.clip(blur(shift(mark, 3.5 * depth), 1.4) - mark, 0, 1)
    lin = lin + (1 - lin) * (.62 * .55 * rim)[..., None]
    roll = np.clip(blur(shift(mark, -2.5 * depth), 1.6) - mark, 0, 1)
    lin *= (1 - .35 * roll)[..., None]
    return (np.clip(to_srgb(lin), 0, 1) * 255 + .5).astype(np.uint8)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    mark_svg, doc = Path(sys.argv[1]), Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as work:
        png = Path(work) / 'mark.png'
        subprocess.run(['rsvg-convert', '-w', str(N), '-h', str(N), str(mark_svg), '-o', str(png)], check=True)
        mark = np.asarray(Image.open(png).convert('L'), float) / 255
    image = press(mark)
    (doc / 'Assets').mkdir(parents=True, exist_ok=True)
    for old in (doc / 'Assets').iterdir():
        old.unlink()
    Image.fromarray(image, 'RGB').save(doc / 'Assets/leather.png', optimize=True)
    average = image.reshape(-1, 3).mean(0) / 255
    json.dump({'fill': {'solid': 'srgb:%.3f,%.3f,%.3f,1' % tuple(average)},
               'groups': [{'lighting': 'combined', 'shadow': {'kind': 'none', 'opacity': 0}, 'specular': False,
                           'layers': [{'image-name': 'leather.png', 'name': 'leather'}]}],
               'supported-platforms': {'squares': 'shared'}}, open(doc / 'icon.json', 'w'), indent=1)


if __name__ == '__main__':
    main()

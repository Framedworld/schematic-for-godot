"""Joins the frames tests/shot_readme_gif.gd recorded into docs/images/live_flow.gif.

Run from the project folder, after the recording:  python tools/make_gif.py
Needs Pillow.
"""
import glob
from PIL import Image

FRAMES = sorted(glob.glob('tests/out/gif_frames/f*.png'))
TIMES = [int(t) for t in open('tests/out/gif_frames/times.txt').read().split()]
assert FRAMES and len(FRAMES) == len(TIMES), 'record the frames first (tests/shot_readme_gif.gd)'

images = [Image.open(f).convert('RGB') for f in FRAMES]
# one palette for every frame, so colours do not flicker from frame to frame
sheet = Image.new('RGB', (images[0].width, images[0].height * 4))
for i, im in enumerate(images[::max(1, len(images) // 4)][:4]):
    sheet.paste(im, (0, i * im.height))
# octree keeps the few strongly coloured pixels (wires, pins) that a median cut of a mostly dark picture averages away
palette = sheet.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
frames = [im.quantize(palette=palette, dither=Image.Dither.NONE) for im in images]
durations = [max(20, b - a) for a, b in zip(TIMES, TIMES[1:])]
durations.append(durations[-1])
frames[0].save('docs/images/live_flow.gif', save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True)
print(len(frames), 'frames,', sum(durations), 'ms, size', images[0].size)

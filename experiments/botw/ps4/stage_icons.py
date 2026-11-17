#!/usr/bin/env python3
"""Build and verify a private BotW 1.6.0 PlayStation overlay without touching the running game."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
from tempfile import TemporaryDirectory
import zipfile
import zlib

HERE = Path(__file__).resolve().parent
MNG = 'bad89a8c82d1e1cd1e0bbd6e4308b2992c17d76c'
DONOR_SHA = '52541bcccf7637f40c5af5b880cecf4250dc2a29fd873f79db5ee729dbad5224'
UPSTREAM_SHA = {
    'games/totk/scripts/make_botw_button_icons.py': '921cfe1ddc900101deaf20c74461a61048a85b6898c19b5a77c547ca23e2553a',
    'games/totk/scripts/botw_playstation_icons.py': '19038cc9a667c5ffa5b3f3955654b1d91eebee4f9549c39d270ed6f62c033bed',
    'games/totk/scripts/make_mod_manifest.py': '303960cc6ac3de95a0137946f97e8629d64dbbcbbab6d89e0d56d02be62c323a',
    'games/totk/scripts/prepare_shader_seed.py': 'ff3f6de6c267731b83012293b988171db9daf0490415f937b19e1aa8b5ddcf9b',
    'games/totk/scripts/shader_list.py': '4fda811eddfe70ac3d66b7ec58a3347755c5b9ad19ea006ee5df54ede6fd858e',
    'tools/builder/controls_file.py': 'd1ee49762b006336aed701e20aef074e65c006ee476c52fa2b1c47a6cbced1a0',
    'tools/builder/icons_plan.py': '05113cdd2f4f16188cb33a6985f4296abb00385ad387b288d0bbe41ec5a7e63f',
}

for path, expected in UPSTREAM_SHA.items():
    if hashlib.sha256((HERE / 'upstream' / path).read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Unexpected upstream source: {path}')
sys.path.insert(0, str(HERE / 'upstream/games/totk/scripts'))
import botw_playstation_icons as ps
import make_botw_button_icons as mng
import make_mod_manifest as manifests

FACE = dict(zip(range(0xE040, 0xE044), ('circle', 'cross', 'triangle', 'square')))
CONTROLLER_SLOTS = {'a': 'right', 'b': 'bottom', 'x': 'top', 'y': 'left'}
EXPECTED_REMAP = {0xE040: 0xE041, 0xE041: 0xE040, 0xE042: 0xE043, 0xE043: 0xE042}
REGIONS = ('CN', 'EU', 'JP', 'KR', 'TW', 'US')
TABLE = 'System/Resource/ResourceSizeTable.product.srsizetable'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def member(archive, name):
    return archive[slice(*mng.sarc_member(archive, name))]


def stock_except(before, after, spans):
    """Check the length and every byte outside the allowed member or pixel spans."""
    require(len(before) == len(after), 'Uncompressed size changed')
    end = 0
    for start, stop in sorted(spans):
        require(end <= start <= stop <= len(before), 'Invalid or overlapping allowed ranges')
        require(before[end:start] == after[end:start], 'Change outside the allowed ranges')
        end = stop
    require(before[end:] == after[end:], 'Change beyond the allowed ranges')


def font_sheet(font):
    sheet = ps.Sheet(font)
    require((sheet.w, sheet.h, sheet.columns, sheet.texture.width, sheet.texture.height, len(sheet.index))
            == (44, 39, 2, 128, 1024, 49), 'Unsupported BotW 1.6.0 glyph geometry')
    return sheet


def glyph_image(font, sheet):
    at, size = sheet.image()
    return font[at:at + size]


def glyph_width(font, index):
    table = font.index(b'CWDH')
    first, last, following = struct.unpack_from('<HHI', font, table + 8)
    require(first <= index <= last and following == 0, 'Unsupported glyph width table')
    return font[table + 17 + (index - first) * 3]


def glyph_blocks(sheet, image, code):
    x0, y0, x1, y1 = sheet.box(code)
    for by in range(y0 // 4, (y1 + 3) // 4):
        for bx in range(x0 // 4, (x1 + 3) // 4):
            offset, block = sheet._block(image, bx, by)
            indices = [i for i in range(16)
                       if x0 <= bx * 4 + i % 4 < x1 and y0 <= by * 4 + i // 4 < y1]
            yield offset, block, indices


def preserve_neighbors(sheet, original, pixels, symbols):
    # A 4×4 BC4 block can straddle the 44-pixel cells. Keep its original
    # palette and neighbors' exact indices. Apply the edit only inside the target cell.
    untouched = {offset for code in sheet.index.keys() - symbols.keys()
                 for offset, _, _ in glyph_blocks(sheet, original, code)}
    palette_indices = sum(i << (3 * i) for i in range(8)).to_bytes(6, 'little')
    for code in symbols:
        for offset, original_block, indices in glyph_blocks(sheet, original, code):
            if offset not in untouched:
                continue
            desired = ps.bc4_decode(pixels[offset:offset + 8])
            palette = ps.bc4_decode(original_block[:2] + palette_indices)[:8]
            selectors = int.from_bytes(original_block[2:], 'little')
            for i in indices:
                best = min(range(8), key=lambda j: abs(palette[j] - desired[i]))
                require(abs(palette[best] - desired[i]) <= 24, f'Unrepresentable shared BC4 pixels in U+{code:04X}')
                selectors = (selectors & ~(7 << (3 * i))) | best << (3 * i)
            pixels[offset:offset + 8] = original_block[:2] + selectors.to_bytes(6, 'little')


def donor_controls(path, stock):
    require(sha(path.read_bytes()) == DONOR_SHA, 'Unexpected donor archive hash')
    with zipfile.ZipFile(path) as archive:
        name, = (name for name in archive.namelist() if name.endswith('/romfs/Font/Font_EU.sbfarc'))
        font = member(mng.yaz0(archive.read(name)), mng.MEMBER)
    sheet = font_sheet(font)
    stock_except(stock, font, [ps.sheet_span(stock)])
    image = glyph_image(font, sheet)
    share = sheet.cell(image, 0xE04C)
    # The donor's OPTIONS left edge is cut. Keep its DS4 key silhouette,
    # center it above a compact seven-letter label within the verified cell.
    options = sheet.cell(image, 0xE04B)
    letters = {
        'O': ('010', '101', '101', '101', '010'),
        'P': ('110', '101', '110', '100', '100'),
        'T': ('111', '010', '010', '010', '010'),
        'I': ('1', '1', '1', '1', '1'),
        'N': ('101', '111', '111', '111', '101'),
        'S': ('011', '100', '010', '001', '110'),
    }
    width = glyph_width(font, sheet.index[0xE04B])
    require(width == glyph_width(font, sheet.index[0xE04C]) == 26, 'Unsupported Options/Share width')
    share = [row[:width] + bytearray(44 - width) for row in share]
    options = options[:31] + [bytearray(44) for _ in range(8)]
    left = 1
    for letter in 'OPTIONS':
        for y, bits in enumerate(letters[letter], 31):
            for x, bit in enumerate(bits, left):
                if bit == '1':
                    options[y][x] = 255
        left += len(letters[letter][0]) + 1
    require(left - 1 <= width, 'OPTIONS does not fit the visible glyph')
    return {0xE04B: options, 0xE04C: share}


def render_font(stock, special, remap):
    old = font_sheet(stock)
    old_image = glyph_image(stock, old)
    at, size = old.image()
    pixels = bytearray(old_image)
    symbols = {**ps.GLYPH_SYMBOL, **special}
    for code, symbol in symbols.items():
        rows = old.cell(old_image, code)
        ps_rows = ps.redraw(rows, symbol) if isinstance(symbol, str) else symbol
        old.put(pixels, code, ps_rows)
    preserve_neighbors(old, old_image, pixels, symbols)
    patched = mng.remap(stock[:at] + pixels + stock[at + size:], remap)
    sheet = font_sheet(patched)
    table, low, _ = mng.cmap_table(stock)
    stock_except(stock, patched, [(at, at + size)] +
                 [(table + (code - low) * 2, table + (code - low) * 2 + 2) for code in remap])
    new_image = glyph_image(patched, sheet)
    stock_rows = {code: old.cell(old_image, code) for code in old.index}
    new_rows = {code: sheet.cell(new_image, code) for code in sheet.index}
    require(old.index.keys() == sheet.index.keys(), 'Code point set changed')
    require(all(sheet.index[code] == old.index[remap.get(code, code)] for code in old.index), 'Wrong CMAP')
    changed = {code for code in old.index if stock_rows[code] != new_rows[code]}
    require(changed == symbols.keys(), f'Unexpected glyph changes: {[hex(code) for code in sorted(changed ^ symbols.keys())]}')
    require(all(any(any(row) for row in new_rows[code]) for code in symbols), 'Empty PlayStation glyph')
    for code in special:
        width = glyph_width(patched, sheet.index[code])
        require(not any(max(row[width:]) > 24 for row in new_rows[code]), f'Side button clips at U+{code:04X}')
    return patched, stock_rows, new_rows


def rstb_sizes(table, names):
    require(table[:4] == b'RSTB', 'Unexpected resource size table signature')
    count, named = struct.unpack_from('<II', table, 4)
    require(len(table) == 12 + count * 8 + named * 132, 'Unexpected resource size table layout')
    entries = dict(struct.iter_unpack('<II', table[12:12 + count * 8]))
    overrides = {name.split(b'\0', 1)[0].decode(): size for name, size in
                 struct.iter_unpack('<128sI', table[12 + count * 8:])}
    return {name: overrides.get(name, entries.get(zlib.crc32(name.encode()))) for name in names}


def pack_layout(pack, remap, slots):
    old_packed = member(pack, mng.LAYOUT)
    old = mng.yaz0(old_packed)
    new = mng.layout_remap(old, slots, 'playstation', remap)
    allowed = [*mng.PARTS.values(), ps.BNTX]
    stock_except(old, new, [mng.sarc_member(old, name) for name in allowed])
    old_bntx, new_bntx = member(old, ps.BNTX), member(new, ps.BNTX)
    textures = ps.textures(old_bntx)
    names = [*ps.TEXTURE_SYMBOL, *ps.SHOULDER_TEXTURE]
    spans = []
    for name in names:
        texture = textures[name]
        texture.check(ps.R8_UNORM)
        require((texture.width, texture.height) == (48, 48), f'Wrong size for {name}')
        spans.append((texture.offset, texture.offset + texture.image_size))
        require(ps.r8_read(old_bntx, texture) != ps.r8_read(new_bntx, texture), f'Unchanged texture: {name}')
    stock_except(old_bntx, new_bntx, spans)
    for code, position in slots.items():
        old_part, new_part = (member(layout, mng.PARTS[code]) for layout in (old, new))
        expected = f'Nt_KeyTex{mng.LABEL[position]}_00^'.encode()
        require(new_part != old_part and expected in new_part, f'Wrong action guide for {code}')
    packed = mng.yaz0_patch(old_packed, old, new)
    require(mng.yaz0(packed) == new, 'Action guide Yaz0 round-trip failed')
    result = mng.sarc_put(pack, mng.LAYOUT, packed)
    names_before = mng.pack_names(pack)
    require(mng.pack_names(result) == names_before, 'Bootup member inventory changed')
    require({name for name in names_before if member(pack, name) != member(result, name)} == {mng.LAYOUT},
            'Unrelated Bootup member changed')
    preview = [[ps.r8_read(bntx, textures[name]) for name in names] for bntx in (old_bntx, new_bntx)]
    return result, {'original_packed': len(old_packed), 'staged_packed': len(packed), 'decoded': len(new),
                    'modified_members': allowed, 'modified_textures': names, 'bootup_members': len(names_before)}, preview


def preview_png(path, rows):
    """Two grayscale strips with nearest-neighbor scaling: original, then staged."""
    scale, gap = 4, 12
    cell_h = max(len(cell) for row in rows for cell in row)
    cell_w = max(len(cell[0]) for row in rows for cell in row)
    width = len(rows[0]) * (cell_w * scale + gap) + gap
    height = len(rows) * (cell_h * scale + gap) + gap
    canvas = [bytearray([25]) * width for _ in range(height)]
    for i, row in enumerate(rows):
        for j, cell in enumerate(row):
            x, y = gap + j * (cell_w * scale + gap), gap + i * (cell_h * scale + gap)
            for line in cell:
                data = bytes(max(25, p) for p in line for _ in range(scale))
                for _ in range(scale):
                    canvas[y][x:x + len(data)] = data
                    y += 1
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(b''.join(b'\0' + line for line in canvas))) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--donor', type=Path, required=True)
    parser.add_argument('--app', type=Path, default=Path.home() / 'Applications/Breath of the Wild.app')
    parser.add_argument('--controls', type=Path,
                        default=Path.home() / 'Library/Application Support/MacNativeGames/BotW/controls.txt')
    parser.add_argument('--output', type=Path, default=HERE / 'derived')
    args = parser.parse_args()
    output = args.output.resolve()
    require(output.parent == HERE and output.name.startswith('derived') and not output.exists(),
            'Choose a new output directory starting with derived directly in this stage')
    controls = args.controls.read_bytes()
    controller_type = args.controls.with_name('controller-type.txt')
    kind = controller_type.read_bytes()
    remap, slots = mng.layout_plan(controls, 'botw160')
    from tools.builder import controls_file
    parsed = controls_file.parse(controls)
    physical = controls_file.layout(parsed, False)[0]
    touchpad = parsed.map[controls_file.PHYSICAL.index('touchpad')]
    require(remap == EXPECTED_REMAP and slots == CONTROLLER_SLOTS and
            touchpad == controls_file.SWITCH.index('minus') and physical.get('view') == 'minus' and
            controls_file.read_type(kind) == 'playstation', 'Active control map differs')
    romfs = args.app / 'Contents/Resources/totk/extracted/botw160/romfs'
    index = manifests.read_index(romfs / 'runtime-index.bin')
    files = {region: f'Font/Font_{region}.sbfarc' for region in REGIONS}
    pack_path = mng.LAYOUT_PACK
    with (romfs / 'romfs.bin').open('rb') as original, TemporaryDirectory(prefix='.staging-', dir=HERE) as temp:
        stage = Path(temp) / 'output'
        overlay = stage / 'overlay'
        preview = stage / 'preview'
        preview.mkdir(parents=True)
        def read(name):
            offset, size = index[name]
            original.seek(offset)
            data = original.read(size)
            require(len(data) == size, f'Short original resource: {name}')
            return data
        report = {'mng_commit': MNG, 'donor_sha256': DONOR_SHA, 'controls_sha256': sha(controls),
                  'controller_type_sha256': sha(kind), 'controller_type_exists': True, 'position_mapping': True,
                  'version': 'botw160', 'physical_face': FACE, 'action_slots': slots, 'files': {},
                  'offline_only': True, 'minus': ['DualShock 4 SHARE', 'touchpad click']}
        def store(name, source, staged, decoded):
            target = overlay / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(staged)
            report['files'][name] = {'original_size': len(source), 'original_sha256': sha(source),
                                     'staged_size': len(staged), 'staged_sha256': sha(staged), 'decoded': decoded}
        regions = {region: (data, mng.yaz0(data)) for region, name in files.items() if (data := read(name))}
        stock = member(regions['EU'][1], mng.MEMBER)
        special = donor_controls(args.donor, stock)
        new_font, before, after = render_font(stock, special, remap)
        for region, (source, decoded) in regions.items():
            start, end = mng.sarc_member(decoded, mng.MEMBER)
            require(decoded[start:end] == stock, f'Unexpected icon font for region {region}')
            staged = decoded[:start] + new_font + decoded[end:]
            stock_except(decoded, staged, [(start, end)])
            compressed = mng.yaz0_patch(source, decoded, staged)
            require(mng.yaz0(compressed) == staged, f'Font round-trip failed for {region}')
            store(files[region], source, compressed, len(staged))
        font_order = list(FACE) + list(range(0xE044, 0xE048)) + list(special)
        preview_png(preview / 'font.png', [[row[code] for code in font_order] for row in (before, after)])
        pack = read(pack_path)
        new_pack, layout, layout_preview = pack_layout(pack, remap, slots)
        store(pack_path, pack, new_pack, len(new_pack))
        preview_png(preview / 'action-guide.png', layout_preview)
        canonical = {f'Font/Font_{region}.bfarc': report['files'][path]['decoded'] for region, path in files.items()}
        canonical['Layout/Common.blarc'] = layout['decoded']
        sizes = rstb_sizes(mng.yaz0(read(TABLE)), [*canonical, pack_path])
        require(all(sizes[name] is not None and sizes[name] >= size for name, size in canonical.items()),
                'A decoded resource exceeds its stock RSTB allocation')
        require(sizes[pack_path] is None, 'Unexpected direct Bootup RSTB allocation')
        report.update({'rstb': sizes, 'action_guide': layout, 'changed_glyphs': [f'U+{c:04X}' for c in font_order]})
        conflicts = manifests.app_overlays(args.app, 'botw160')
        found = manifests.write_manifest(overlay, romfs, app_replaced=conflicts)
        require(len(found.lines) == 7 and not found.added and not found.misspelt and not found.taken,
                'Unexpected manifest paths or a collision with the app')
        for line in found.lines:
            path, size, new_sha, old_sha = line.split('\t')
            file = report['files'][path]
            require((int(size), new_sha, old_sha) ==
                    (file['staged_size'], file['staged_sha256'], file['original_sha256']), 'Manifest mismatch')
        report['manifest_sha256'] = sha((overlay / 'manifest.tsv').read_bytes())
        (stage / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        stage.rename(output)
    print(f'Staged and verified {len(found.lines)} replacements in {output}')


if __name__ == '__main__':
    main()

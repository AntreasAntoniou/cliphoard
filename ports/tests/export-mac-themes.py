"""Export the shipping Swift theme tokens; --check detects Windows palette drift."""
import argparse
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / 'Sources/Cliphoard/UI/Theme.swift').read_text()

def split_fields(text):
    fields, start, depth = [], 0, 0
    for i, c in enumerate(text):
        if c == '(': depth += 1
        if c == ')': depth -= 1
        if c == ',' and depth == 0:
            fields.append(text[start:i].strip()); start = i + 1
    fields.append(text[start:].strip())
    return dict(field.split(':', 1) for field in fields if ':' in field)

def color(expr):
    expr = expr.strip()
    hex_value = re.search(r'fromHex: "(#[A-Fa-f0-9]+)"', expr)
    if hex_value: return hex_value[1].upper()
    opacity = re.search(r'\.opacity\(([\d.]+)\)', expr)
    alpha = float(opacity[1]) if opacity else 1
    def packed(r, g, b, a=alpha):
        parts = [int(float(v) * 255 + .5) for v in (r, g, b)]
        return '#' + (f'{int(a * 255 + .5):02X}' if a != 1 else '') + ''.join(f'{v:02X}' for v in parts)
    rgb = re.search(r'red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)', expr)
    if rgb: return packed(*rgb.groups())
    white = re.search(r'white: ([\d.]+)', expr)
    if white: return packed(*([white[1]] * 3))
    if 'white' in expr: return packed(1, 1, 1)
    if 'black' in expr: return packed(0, 0, 0)
    if 'clear' in expr: return '#00000000'
    raise ValueError(expr)

titles = dict(re.findall(r'case \.(\w+):\s*return "([^"]+)"', source.split('private static func lightEditor')[0]))
body = source.split('var tokens: ThemeTokens {', 1)[1].split('/// How the bar', 1)[0]
parts = re.split(r'case \.(\w+):', body)
result = []
for key, block in zip(parts[1::2], parts[2::2]):
    if key == 'system':
        result.append(dict(Id=key, Title=titles[key])); continue
    editor = re.search(r'Self\.(lightEditor|editor)\((.*?)\)', block, re.S)
    if editor:
        args = {k.strip(): v.strip().strip('"').upper() for k, v in split_fields(editor[2]).items()}
        dark = editor[1] == 'editor'
        theme = dict(Bar=args['bg'], Card=args['panel'], Accent=args['accent'], Pin=args['pin'], Muted=args['muted'], Border='#1AFFFFFF' if dark else '#1A000000', Hover='#33FFFFFF' if dark else '#38000000', Tag='#12FFFFFF' if dark else '#0D000000', Radius=12 if dark else 10, SelectedWidth=2, Dark=dark, Material=False, Serif=False)
    else:
        start = block.index('ThemeTokens(') + len('ThemeTokens(')
        depth, end = 1, start
        while depth:
            if block[end] == '(': depth += 1
            if block[end] == ')': depth -= 1
            end += 1
        # Comments explain the Swift source but are not fields.
        fields = {k.strip(): v.strip() for k, v in split_fields(re.sub(r'//[^\n]*', '', block[start:end-1])).items()}
        dark = fields.get('scheme') == '.dark'
        material = fields.get('usesMaterials', 'true') == 'true'
        theme = dict(Bar='#D921222C' if material else color(fields['barFill']), Card='#CC282A36' if material else color(fields['cardFill']), Accent=color(fields['accent']), Pin=color(fields['pin']), Border=color(fields['border']), Hover=color(fields['borderHover']), Tag=color(fields['tagFill']), Muted=color(fields['tagText']), Radius=float(fields.get('cornerRadius', '12')), SelectedWidth=float(fields.get('selectedBorderWidth', '2.5')), Dark=dark, Material=material, Serif=fields.get('fontDesign') == '.serif')
    result.append(dict(Id=key, Title=titles[key], **theme))
enum_header = source.split('enum ThemePreset:', 1)[1].split('var id:', 1)[0]
order = [key.strip() for line in re.findall(r'^    case ([^\n]+)', enum_header, re.M) for key in line.split(',')]
result.sort(key=lambda theme: order.index(theme['Id']))
assert len(result) == 18 and set(titles) == {t['Id'] for t in result}
output = json.dumps(dict(Source='Sources/Cliphoard/UI/Theme.swift', SourceSha256=hashlib.sha256(source.encode()).hexdigest(), Themes=result), indent=2, ensure_ascii=False) + '\n'
path = root / 'ports/windows/Cliphoard.Windows/ThemePresets.json'
parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
if args.check:
    assert path.read_text() == output, 'Windows theme tokens differ from the shipping Swift source'
    print('18 Mac theme presets match their Windows palette export')
else:
    path.write_text(output); print('Exported 18 shipping Mac themes')

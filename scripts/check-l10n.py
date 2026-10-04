#!/usr/bin/env python3
"""翻訳の抜けを確認する。

ソース中の L("日本語") / LK("キー", ...) のキーが、すべて
Resources/en.lproj/Localizable.strings にあるかを調べる。
抜けがあれば一覧を表示して終了コード 1 で終わる (CI でも実行)。
"""
import glob, re, sys, os

os.chdir(os.path.join(os.path.dirname(__file__), '..'))
KEY = re.compile(r'\bLK?\("((?:[^"\\]|\\.)*)"')
used = {}
for f in sorted(glob.glob('Sources/**/*.swift', recursive=True)):
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        if line.lstrip().startswith('//'):
            continue
        for k in KEY.findall(line):
            used.setdefault(k, f'{f}:{n}')

strings = open('Resources/en.lproj/Localizable.strings', encoding='utf-8').read()
have = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', strings, re.M))

missing = sorted(k for k in used if k not in have)
unused = sorted(k for k in have if k not in used)
for k in missing:
    print(f'❌ 英語訳がありません: "{k}"  ({used[k]})')
for k in unused:
    print(f'ℹ️  使われていない英語訳: "{k}"')
if missing:
    sys.exit(1)
print(f'✅ 翻訳 OK ({len(used)} 件)')

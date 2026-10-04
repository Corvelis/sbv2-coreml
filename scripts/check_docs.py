#!/usr/bin/env python3
"""Check local Markdown links; optionally build SDK and type-check Swift examples.

No model download, inference, remote publishing, or third-party Python package is required.
Swift fences in one Markdown page are compiled together, in their displayed order.
"""
from __future__ import annotations
import argparse
import platform
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
FENCES = re.compile(r"^```([^\n]*)\n(.*?)^```\s*$", re.MULTILINE | re.DOTALL)
LINKS = re.compile(r"\[[^\]\n]+\]\(([^)\s]+)\)")


def run(arguments):
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, arguments))}\n{result.stdout[-4000:]}\n{result.stderr[-8000:]}")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', action='store_true', help='Build SDK and type-check Swift code blocks (macOS/Xcode)')
    args = parser.parse_args()
    pages = [*sorted(ROOT.glob('README*.md')), *sorted(ROOT.glob('THIRD_PARTY_NOTICES*.md')),
             *sorted((ROOT/'docs').glob('*.md')), ROOT/'Examples/Apple/ICON.md',
             *sorted((ROOT/'scripts/model-cards').rglob('*.md'))]
    missing, snippets = [], []
    link_count = 0
    for page in pages:
        content = page.read_text()
        for destination in LINKS.findall(FENCES.sub('', content)):
            url = urlsplit(destination.strip('<>'))
            if url.scheme or url.netloc or not url.path:
                continue
            link_count += 1
            if not (page.parent / unquote(url.path)).exists():
                missing.append(f'{page.relative_to(ROOT)}: {destination}')
        blocks = [match.group(2) for match in FENCES.finditer(content) if match.group(1).strip() == 'swift']
        if blocks:
            snippets.append((page, '\n'.join(blocks)))
    if missing:
        raise RuntimeError('Missing local links:\n' + '\n'.join(missing))
    print(f'Checked {len(pages)} Markdown pages and {link_count} local links')
    if args.swift:
        if platform.system() != 'Darwin':
            raise RuntimeError('--swift requires macOS with Xcode')
        # Xcode 27 selects the Swift Build engine by default. Use SwiftPM's
        # native layout consistently for the explicit module-map type check.
        build = ['swift', 'build', '--build-system', 'native', '-c', 'debug']
        run(build)
        binary_path = Path(run([*build, '--show-bin-path']))
        with tempfile.TemporaryDirectory(prefix='sbv2-docs-') as temporary:
            for index, (page, content) in enumerate(snippets):
                source = Path(temporary)/f'example_{index}.swift'
                source.write_text(content)
                run(['xcrun', 'swiftc', '-typecheck', '-parse-as-library',
                     '-target', f'{platform.machine()}-apple-macosx15.0',
                     '-I', str(binary_path/'Modules'),
                     '-Xcc', '-fmodule-map-file='+str(binary_path/'SBV2Native.build/module.modulemap'),
                     '-Xcc', '-I'+str(ROOT/'Sources/SBV2Native/include'), str(source)])
                print(f'Swift examples type-checked: {page.relative_to(ROOT)}')


if __name__ == '__main__':
    main()

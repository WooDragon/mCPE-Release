#!/usr/bin/env python3
"""Extract complete, uniquely defined C functions without changing their bodies."""
import argparse
import hashlib
import json
import re
from pathlib import Path

TOKEN = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|[^\s]', re.S)


def tokens(text):
    """Keep original positions; omit comments, not string or character literals."""
    return [(match.group(), match.start(), match.end()) for match in TOKEN.finditer(text)
            if not match.group().startswith(('/*', '//'))]


def closing(items, start, opening, end):
    """Return the matching delimiter; unterminated source is an error."""
    depth = 0
    for index in range(start, len(items)):
        token = items[index][0]
        if token == opening:
            depth += 1
        elif token == end:
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f'unterminated {opening} at byte {items[start][1]}')


def function(text, name):
    """Return the entire original declaration and body of one defined function."""
    items = tokens(text)
    matches = []
    for index, (token, start, _) in enumerate(items[:-1]):
        if token != name or items[index + 1][0] != '(':
            continue
        right = closing(items, index + 1, '(', ')')
        body = right + 1
        # Sparse lock annotations are part of the original declaration, not calls.
        while body + 1 < len(items) and items[body][0] in ('__acquires', '__releases', '__must_hold'):
            if items[body + 1][0] != '(':
                raise ValueError(f'{name}: malformed lock annotation')
            body = closing(items, body + 1, '(', ')') + 1
        if body >= len(items) or items[body][0] != '{':
            continue
        finish = closing(items, body, '{', '}')
        line_start = text.rfind('\n', 0, start) + 1
        while line_start:
            previous_start = text.rfind('\n', 0, line_start - 1) + 1
            previous = text[previous_start:line_start].strip()
            if not previous or previous.startswith(('#', '/*', '*', '//')) or previous.endswith((';', '}')):
                break
            line_start = previous_start
        matches.append(text[line_start:items[finish][2]])
    if len(matches) != 1:
        raise ValueError(f'{name}: expected one complete definition, found {len(matches)}')
    return matches[0]


def state_enum(text):
    """Keep the original state numbering instead of duplicating constants."""
    matches = re.findall(r'enum\s*\{[^{}]*\bMT76_STATE_INITIALIZED\b[^{}]*\};', text)
    if len(matches) != 1:
        raise ValueError('expected one original mt76 state enum')
    return matches[0]


def verify_fixture(root):
    """Reject missing, changed, or wrong-version original sources."""
    manifest = json.loads((root / 'source-manifest.json').read_text())
    if manifest['mt76_revision'] != 'eb567bc7f9b692bbf1ddfe31dd740861c58ec85b':
        raise ValueError('wrong mt76 fixture revision')
    if (manifest['base_kernel'], manifest['backports_version']) != ('6.6.133', '6.12.61'):
        raise ValueError('wrong framework layer')
    for record in manifest['files']:
        data = (root / record['file']).read_bytes()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f"fixture SHA mismatch: {record['file']}")
    return manifest


def emit(tree, specifications, destination):
    """Write only complete source functions and their byte-for-byte hashes."""
    chunks = [state_enum((tree / 'mt76.h').read_text()), '#include "kernel-double.h"']
    records = []
    for path, names in specifications.items():
        text = (tree / path).read_text()
        for name in names:
            extracted = function(text, name)
            chunks.append(extracted)
            records.append({'file': path, 'function': name,
                            'sha256': hashlib.sha256(extracted.encode()).hexdigest()})
    destination.write_text('\n\n'.join(chunks) + '\n')
    destination.with_suffix('.json').write_text(json.dumps(records, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tree', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--selection', type=Path, required=True)
    args = parser.parse_args()
    verify_fixture(args.fixture)
    emit(args.tree, json.loads(args.selection.read_text()), args.output)


if __name__ == '__main__':
    main()

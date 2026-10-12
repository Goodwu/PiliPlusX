#!/usr/bin/env python3
"""Read routing's exact, unquoted environment.flutter pin without a YAML dependency."""
from __future__ import annotations

import argparse
from pathlib import Path
import re


def flutter_version(pubspec: Path) -> str:
    """Accept the existing block-style contract; reject missing or ambiguous pins."""
    lines = pubspec.read_text(encoding='utf-8').splitlines()
    headers = []
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        # No multiline scalar/flow may hide apparent top-level keys. Validate
        # every line, including nested entries, against this restricted form.
        item = line.lstrip(' ')
        is_list = item.startswith('- ')
        if is_list:
            item = item[2:]
        key = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$', item)
        if key is None and not is_list:
            raise ValueError('App pubspec requires bare block mapping keys')
        value = (key[2] or '') if key else item
        if value and not value.startswith('#'):
            if value.startswith('"'):
                valid = re.fullmatch(r'"(?:[^"\\]|\\.)*"[ \t]*(?:#.*)?', value)
            elif value.startswith("'"):
                valid = re.fullmatch(r"'(?:[^']|'')*'[ \t]*(?:#.*)?", value)
            elif value.startswith('['):
                # pubspec uses inline platform lists; only closed bare-word
                # lists are in this subset, never nested/multiline flow values.
                valid = re.fullmatch(r'\[(?:[A-Za-z0-9_-]+(?:,[ \t]*[A-Za-z0-9_-]+)*)?\][ \t]*(?:#.*)?', value)
            else:
                plain = re.split(r'[ \t]+#', value, maxsplit=1)[0]
                valid = (plain[0] not in '[]{}&*!|>%@`' and not plain.startswith('- ')
                         and not re.search(r':[ \t]', plain))
            if not valid:
                raise ValueError('App pubspec requires single-line scalar values')
        if line[0].isspace():
            continue
        # This is the repository's restricted block contract, not a YAML parser.
        # Reject quoted/escaped keys instead of overlooking another environment.
        if key is None or is_list:
            raise ValueError('App pubspec requires bare top-level mapping keys')
        if key[1] == 'environment':
            headers.append(index)
    if len(headers) != 1 or not re.fullmatch(r'environment:[ \t]*(?:#.*)?', lines[headers[0]]):
        raise ValueError('App pubspec must have one block-style environment mapping')
    block = []
    for line in lines[headers[0] + 1:]:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if not line[0].isspace():
            break
        block.append(line)
    entries = {}
    for line in block:
        entry = re.fullmatch(r'  (sdk|flutter): ([^\r\n]+)', line)
        if entry is None or entry[1] in entries:
            raise ValueError('App environment requires unique single-line sdk/flutter entries')
        entries[entry[1]] = entry[2]
    match = re.fullmatch(r'([0-9]+\.[0-9]+\.[0-9]+)[ \t]*', entries.get('flutter', ''))
    if match is None:
        raise ValueError('App environment.flutter must have one exact unquoted X.Y.Z pin')
    return match[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pubspec', type=Path)
    args = parser.parse_args()
    try:
        version = flutter_version(args.pubspec)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print(version)


if __name__ == '__main__':
    main()

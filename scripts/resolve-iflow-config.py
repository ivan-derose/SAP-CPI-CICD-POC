#!/usr/bin/env python3
"""Resolve CPI externalized parameters from artifact ZIP tree and target policy.
JSON policy: {"parameters": {"Key": "target value"}, "inherit": ["SafeCommonKey"]}.
Fail closed: every source parameter must be explicitly overridden or inherited.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def read_properties(path):
    # Java properties: ISO-8859-1 by default, \u escapes and continued lines.
    raw = path.read_bytes().decode('iso-8859-1')
    logical = []
    current = ''
    for line in raw.splitlines():
        if current:
            line = line.lstrip(' \t\f')
        current += line
        trailing = len(current) - len(current.rstrip('\\'))
        if trailing % 2:
            current = current[:-1]
        else:
            logical.append(current)
            current = ''
    if current:
        logical.append(current)

    def unesc(value):
        def transform(m):
            token = m.group(1)
            if token.startswith('u'):
                return chr(int(token[1:], 16))
            return {'t': '\t', 'r': '\r', 'n': '\n', 'f': '\f'}.get(token, token)
        return re.sub(r'\\(u[0-9a-fA-F]{4}|.)', transform, value)

    props = {}
    for rawline in logical:
        line = rawline.lstrip(' \t\f')
        if not line or line[0] in '#!':
            continue
        i = 0
        escaped = False
        while i < len(line):
            c = line[i]
            if not escaped and (c in '=:' or c.isspace()):
                break
            if c == '\\' and not escaped:
                escaped = True
            else:
                escaped = False
            i += 1
        key = unesc(line[:i])
        rest = line[i:].lstrip(' \t\f')
        if rest.startswith(('=', ':')):
            rest = rest[1:]
        value = unesc(rest.lstrip(' \t\f'))
        if key in props:
            raise ValueError(f'Duplicate property: {key}')
        props[key] = value
    return props


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact_dir', type=Path)
    parser.add_argument('policy_json', type=Path)
    parser.add_argument('output_json', type=Path)
    args = parser.parse_args()
    resource = args.artifact_dir / 'src/main/resources'
    prop = resource / 'parameters.prop'
    propdef = resource / 'parameters.propdef'
    if not prop.is_file() or not propdef.is_file():
        raise ValueError('parameters.prop and parameters.propdef are both required')
    values = read_properties(prop)
    root = ET.parse(propdef).getroot()
    definitions = {}
    for element in root.findall('./parameter'):
        name = element.findtext('name')
        dtype = element.findtext('type')
        if not name or not dtype or name in definitions:
            raise ValueError('Invalid or duplicate parameter definition')
        definitions[name] = {'type': dtype, 'required': element.findtext('isRequired') == 'true'}
    if set(values) != set(definitions):
        raise ValueError('Parameter definitions and values differ: ' + str(sorted(set(values) ^ set(definitions))))
    policy = json.loads(args.policy_json.read_text(encoding='utf-8'))
    if not isinstance(policy, dict) or set(policy) - {'parameters', 'inherit'}:
        raise ValueError('Policy requires an object with only parameters and inherit')
    overrides = policy.get('parameters', {})
    inherit = policy.get('inherit', [])
    if not isinstance(overrides, dict) or not isinstance(inherit, list) or len(inherit) != len(set(inherit)):
        raise ValueError('parameters must be object and inherit a duplicate-free list')
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in overrides.items()):
        raise ValueError('Parameter names and target values must be strings')
    if not all(isinstance(k, str) for k in inherit):
        raise ValueError('inherit must be a list of strings')
    unknown = (set(overrides) | set(inherit)) - set(definitions)
    overlap = set(overrides) & set(inherit)
    missing = set(definitions) - set(overrides) - set(inherit)
    if unknown or overlap or missing:
        raise ValueError(f'Unknown={sorted(unknown)}; conflicting={sorted(overlap)}; unclassified={sorted(missing)}')
    result = []
    for key, definition in definitions.items():
        val = overrides[key] if key in overrides else values[key]
        if definition['required'] and not val:
            raise ValueError(f'Missing mandatory value for {key}')
        result.append({'key': key, 'value': val, 'dataType': definition['type'], 'origin': 'override' if key in overrides else 'explicit inherit'})
    args.output_json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Validati {len(result)} parametri: {len(overrides)} override, {len(inherit)} ereditati esplicitamente. Valori omessi dal log.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, ET.ParseError, OSError, json.JSONDecodeError) as exc:
        print(f'CONFIG ERROR: {exc}', file=sys.stderr)
        sys.exit(1)

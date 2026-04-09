#!/usr/bin/env python3

import re
import sys

import yaml

PLACEHOLDER = "SECRET_VALUE_HERE"
PRESERVE_SCALAR_KEYS = {"user"}


def get_line_offsets(content):
    offsets = [0]
    total = 0
    for line in content.splitlines(keepends=True):
        total += len(line)
        offsets.append(total)
    if not content:
        return offsets
    if offsets[-1] != len(content):
        offsets.append(len(content))
    return offsets


def get_offset(offsets, line, column):
    return offsets[line] + column


def get_node_slice(content, offsets, node):
    start = get_offset(offsets, node.start_mark.line, node.start_mark.column)
    end = get_offset(offsets, node.end_mark.line, node.end_mark.column)
    return start, end, content[start:end]


def detect_newline(source):
    if "\r\n" in source:
        return "\r\n"
    if "\n" in source:
        return "\n"
    if "\r" in source:
        return "\r"
    return "\n"


def detect_block_indent(body_lines):
    indent_candidates = []
    for line in body_lines:
        stripped = line.rstrip("\r\n")
        if not stripped.strip():
            continue
        indent_candidates.append(re.match(r"^[ \t]*", line).group(0))

    if indent_candidates:
        return min(indent_candidates, key=len)

    return "  "


def render_placeholder(node_source, node_style):
    if node_style == "'":
        return "'" + PLACEHOLDER.replace("'", "''") + "'"

    if node_style in {"|", ">"}:
        source_lines = node_source.splitlines(keepends=True)
        header = source_lines[0].rstrip("\r\n") if source_lines else node_style
        newline = detect_newline(node_source)
        body_indent = detect_block_indent(source_lines[1:])
        trailing_newlines = ""
        trailing_match = re.search(r"((?:\r?\n)+)$", node_source)
        if trailing_match:
            trailing_newlines = trailing_match.group(1)
        return header + newline + body_indent + PLACEHOLDER + trailing_newlines

    return '"' + PLACEHOLDER + '"'


def collect_replacements(node, content, offsets, replacements, parent_key=None, seen_spans=None):
    if seen_spans is None:
        seen_spans = set()

    if isinstance(node, yaml.MappingNode):
        for key_node, value_node in node.value:
            key_name = key_node.value if isinstance(key_node, yaml.ScalarNode) else None
            collect_replacements(
                value_node,
                content,
                offsets,
                replacements,
                parent_key=key_name,
                seen_spans=seen_spans,
            )
        return

    if isinstance(node, yaml.SequenceNode):
        for item_node in node.value:
            collect_replacements(
                item_node,
                content,
                offsets,
                replacements,
                parent_key=parent_key,
                seen_spans=seen_spans,
            )
        return

    if not isinstance(node, yaml.ScalarNode):
        return

    if parent_key in PRESERVE_SCALAR_KEYS:
        return

    start, end, node_source = get_node_slice(content, offsets, node)
    span = (start, end)
    if span in seen_spans:
        return

    seen_spans.add(span)
    replacements.append((start, end, render_placeholder(node_source, node.style)))


def sanitize_yaml(content):
    if not content.strip():
        return ""

    root = yaml.compose(content, Loader=yaml.SafeLoader)
    if root is None:
        return ""

    offsets = get_line_offsets(content)
    replacements = []
    collect_replacements(root, content, offsets, replacements)

    # Replace only scalar spans so the source YAML layout stays intact.
    sanitized = content
    for start, end, replacement in sorted(replacements, reverse=True):
        sanitized = sanitized[:start] + replacement + sanitized[end:]

    return sanitized.rstrip("\r\n")


def main():
    content = sys.stdin.read()
    sys.stdout.write(sanitize_yaml(content))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read this workflow's YAML/Actions subset, rejecting unsupported syntax.

This is a local contract model, not a YAML implementation or Actions runner.
Run blocks are passed unchanged to Bash; external actions are never invoked.
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path


class ContractError(ValueError):
    """The workflow or an assertion is outside the tested contract."""


def require(condition, message):
    """Raise a diagnostic rather than allow a missing assertion to pass."""
    if not condition:
        raise ContractError(message)


def scalar(text):
    """Decode the supported YAML scalar forms; return booleans as booleans."""
    text = text.strip()
    if text.startswith("'"):
        require(text.endswith("'"), f"unterminated scalar: {text}")
        return text[1:-1].replace("''", "'")
    if text.startswith('"'):
        return json.loads(text)
    text = re.split(r"\s+#", text, maxsplit=1)[0].rstrip()
    if text in ("true", "false"):
        return text == "true"
    require(not text.startswith(("&", "*", "!", "[", "{")),
            f"unsupported YAML scalar: {text}")
    return text


class WorkflowReader:
    """Read indentation-based mappings/lists and literal blocks, not arbitrary YAML."""

    def __init__(self, text):
        self.lines = text.splitlines()
        self.index = 0

    def skip(self):
        while self.index < len(self.lines):
            line = self.lines[self.index]
            if line.strip() and not line.lstrip().startswith("#"):
                break
            self.index += 1

    def location(self):
        self.skip()
        if self.index == len(self.lines):
            return -1, ""
        line = self.lines[self.index]
        require("\t" not in line[:len(line) - len(line.lstrip())], "tab indentation")
        return len(line) - len(line.lstrip()), line.lstrip()

    def value(self, text, indent):
        if text in ("|", "|-"):
            start = self.index
            end = start
            while end < len(self.lines):
                line = self.lines[end]
                if line.strip() and len(line) - len(line.lstrip()) <= indent:
                    break
                end += 1
            nonempty = [len(line) - len(line.lstrip()) for line in self.lines[start:end]
                        if line.strip()]
            width = min(nonempty) if nonempty else indent + 2
            block = "\n".join(line[width:] if line.strip() else ""
                              for line in self.lines[start:end]).rstrip("\n")
            self.index = end
            return block + ("\n" if text == "|" else "")
        if text:
            return scalar(text)
        child_indent, child = self.location()
        if child_indent > indent or (child_indent == indent and child.startswith("- ")):
            return self.node(child_indent)
        return {}

    def pair(self, mapping, line, indent):
        match = re.fullmatch(r"([A-Za-z_][\w-]*):(?:\s+(.*))?", line)
        require(match, f"unsupported YAML mapping: {line}")
        key, value = match.groups()
        require(key not in mapping, f"duplicate YAML key: {key}")
        mapping[key] = self.value(value or "", indent)

    def node(self, indent):
        _, first = self.location()
        result = [] if first.startswith("- ") else {}
        while True:
            width, line = self.location()
            if width < indent:
                break
            require(width == indent, f"unexpected indentation at line {self.index + 1}")
            if isinstance(result, list):
                if not line.startswith("- "):
                    break  # The current workflow also uses indentless step lists.
                self.index += 1
                item = line[2:]
                if re.match(r"[A-Za-z_][\w-]*:", item):
                    mapping = {}
                    self.pair(mapping, item, indent + 2)
                    if self.location()[0] > indent:
                        rest = self.node(indent + 2)
                        require(isinstance(rest, dict), "step continuation is not a mapping")
                        require(not mapping.keys() & rest.keys(), "duplicate step property")
                        mapping.update(rest)
                    result.append(mapping)
                else:
                    result.append(scalar(item))
            else:
                if line.startswith("- "):
                    break
                self.index += 1
                self.pair(result, line, indent)
        return result

    def read(self):
        result = self.node(0)
        require(self.location()[0] == -1, "unread YAML content")
        require(isinstance(result, dict), "workflow is not a mapping")
        return result


def truth(value):
    """Actions treats nonempty strings (including 'false') as truthy."""
    if value is None or value is False or value == "":
        return False
    if isinstance(value, (int, float)):
        return value != 0
    return True


def number(value):
    """Apply Actions numeric coercion for mixed-type equality."""
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return value
    if value == "":
        return 0
    try:
        parsed = json.loads(value)
        return parsed if type(parsed) in (int, float) else math.nan
    except (ValueError, TypeError):
        return math.nan


def equal(left, right):
    """Actions string comparisons ignore case; mixed types compare as numbers."""
    if type(left) is type(right):
        return left.casefold() == right.casefold() if isinstance(left, str) else left == right
    return number(left) == number(right)


class Expression:
    """Evaluate only property/literal, comparison, boolean and status expressions."""
    TOKEN = re.compile(r"\s*(==|!=|&&|\|\||[!()]|'(?:[^']|'')*'|[A-Za-z_][\w.-]*)")

    def __init__(self, source, context):
        source = source.strip()
        if source.startswith("${{"):
            require(source.endswith("}}"), "unterminated expression")
            source = source[3:-2].strip()
        self.tokens = []
        while source:
            match = self.TOKEN.match(source)
            require(match, f"unsupported expression syntax: {source}")
            self.tokens.append(match[1])
            source = source[match.end():].strip()
        self.index, self.context = 0, context
        self.has_status = False

    def accept(self, token):
        if self.index < len(self.tokens) and self.tokens[self.index] == token:
            self.index += 1
            return True
        return False

    def atom(self):
        if self.accept("!"):
            return not truth(self.atom())
        if self.accept("("):
            result = self.binary(0)
            require(self.accept(")"), "missing closing parenthesis")
            return result
        require(self.index < len(self.tokens), "missing expression operand")
        token = self.tokens[self.index]
        self.index += 1
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[token]
        if self.accept("("):
            require(token in ("success", "failure", "cancelled", "always"),
                    f"unsupported function: {token}")
            require(self.accept(")"), "status function takes no arguments")
            self.has_status = True
            return token == "always" or self.context.get(token, False)
        require(re.fullmatch(r"(?:github|env|steps|inputs)\.[\w.-]+", token),
                f"unsupported operand: {token}")
        return self.context.get(token)  # Missing Actions properties are null.

    def binary(self, level):
        if level == 3:
            return self.atom()
        operators = (("||",), ("&&",), ("==", "!="))[level]
        result = self.binary(level + 1)
        while self.index < len(self.tokens) and self.tokens[self.index] in operators:
            operator = self.tokens[self.index]
            self.index += 1
            right = self.binary(level + 1)  # Parse both sides even if one is short-circuited.
            if operator in ("==", "!="):
                result = equal(result, right) == (operator == "==")
            elif operator == "&&":
                result = right if truth(result) else result
            else:
                result = result if truth(result) else right
        return result

    def evaluate(self, step=False):
        result = self.binary(0)
        require(self.index == len(self.tokens), "trailing expression tokens")
        if step and not self.has_status:
            return truth(result) and self.context.get("success", False)
        return result


def evaluate(source, context, step=False):
    """Evaluate a scalar/expression with optional implicit step success()."""
    if isinstance(source, bool):
        return source and (context.get("success", False) if step else True)
    return Expression(source, context).evaluate(step)


class Workflow:
    """Expose unique steps and the four real side-effect boundaries."""
    EFFECTS = ("Generate release tag", "Upload firmware to release",
               "Delete workflow runs", "Remove old Releases by device")

    def __init__(self, text):
        self.data = WorkflowReader(text).read()
        self.build = self.data["jobs"]["build"]["steps"]
        self.steps = {}
        for step in self.build:
            require(isinstance(step, dict) and "name" in step, "unnamed build step")
            require(step["name"] not in self.steps, f"duplicate step: {step['name']}")
            self.steps[step["name"]] = step
        for name in self.EFFECTS:
            self.get(name)

    def get(self, name):
        require(name in self.steps, f"missing step: {name}")
        return self.steps[name]

    def context(self, publish="false", **overrides):
        result = {"success": True, "cancelled": False, "failure": False,
                  "github.sha": "fixture-sha", "github.event.inputs.publish": publish,
                  "inputs.publish": publish == "true" if publish in ("true", "false") else None}
        for key, value in self.data["env"].items():
            if key.startswith("UPLOAD_") or key == "PUBLISH":
                value = evaluate(value, result)
                result[f"env.{key}"] = str(value).lower() if isinstance(value, bool) else value
        for name in ("compile", "organize", "source", "provenance", "tag"):
            result[f"steps.{name}.outputs.status"] = "success"
        result.update(overrides)
        return result

    def eligible(self, name, context):
        return truth(evaluate(self.get(name).get("if", "success()"), context, step=True))

    def effects(self, context):
        return [name for name in self.EFFECTS if self.eligible(name, context)]


def main():
    """Run disk-backed scenarios and require the declared case count."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", type=Path, required=True)
    parser.add_argument("--red-baseline", action="store_true")
    options = parser.parse_args()
    from scenarios import run_cases
    return run_cases(options.workflow, options.red_baseline)


if __name__ == "__main__":
    sys.exit(main())

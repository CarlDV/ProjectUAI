"""Validate the public site without a browser, network, or image decoding."""
from __future__ import annotations

from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
VOID = set("area base br col embed hr img input link meta param source track wbr".split())
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


@dataclass
class Element:
    tag: str
    attrs: dict
    children: list = field(default_factory=list)

    @property
    def text(self):
        return "".join(child if isinstance(child, str) else child.text for child in self.children)

    def has_class(self, name):
        return name in self.attrs.get("class", "").split()


class Document(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.root = Element("document", {})
        self.stack = [self.root]
        self.elements = []
        self.ids = {}
        self.feed(source)
        self.close()
        check(len(self.stack) == 1, "Unclosed HTML element")

    def handle_starttag(self, tag, attrs):
        check(len(dict(attrs)) == len(attrs), "Duplicate attribute on " + tag)
        node = Element(tag, dict(attrs))
        self.stack[-1].children.append(node)
        self.elements.append(node)
        if "id" in node.attrs:
            key = node.attrs["id"]
            check(key and key not in self.ids, "Duplicate or empty id: " + key)
            self.ids[key] = node
        if tag not in VOID:
            self.stack.append(node)

    def handle_endtag(self, tag):
        check(len(self.stack) > 1 and self.stack[-1].tag == tag,
              "Mismatched closing tag: " + tag)
        self.stack.pop()

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_data(self, text):
        self.stack[-1].children.append(text)


def validate_html(base):
    source = (base / "index.html").read_text(encoding="utf-8")
    doc = Document(source)
    check(sum(node.tag == "h1" for node in doc.elements) == 1, "Exactly one h1 is required")
    check(sum(node.tag == "main" for node in doc.elements) == 1, "Exactly one main is required")
    check(any(node.tag == "html" and node.attrs.get("lang") == "en" for node in doc.elements),
          "Document language missing")
    check(any(node.tag == "meta" and node.attrs.get("name") == "viewport" and
              "width=device-width" in node.attrs.get("content", "") for node in doc.elements),
          "Responsive viewport missing")
    labels = {node.attrs.get("for") for node in doc.elements if node.tag == "label"}
    for node in doc.elements:
        attrs = node.attrs
        for key in ("aria-controls", "aria-labelledby", "aria-describedby"):
            for target in attrs.get(key, "").split():
                check(target in doc.ids, "Unknown " + key + " target: " + target)
        if node.tag == "label":
            check(attrs.get("for") in doc.ids, "Label does not name a control")
        if node.tag in ("input", "select", "textarea"):
            check(attrs.get("id") in labels or attrs.get("aria-label"), "Unlabelled form field")
        if node.tag == "button":
            check(attrs.get("type") == "button", "Button type must be explicit")
            check(attrs.get("aria-label") or node.text.strip(), "Button has no accessible name")
        if node.tag == "nav":
            check(attrs.get("aria-label"), "Navigation landmark needs a name")
        if node.tag == "img":
            check("alt" in attrs, "Image is missing alt text")
        if node.tag == "video":
            check("autoplay" not in attrs and "controls" in attrs and attrs.get("preload") == "none",
                  "Video must load and play on request")
        if node.tag == "a":
            check(attrs.get("href"), "Link is missing its destination")
        if attrs.get("target") == "_blank":
            check("noopener" in attrs.get("rel", "").split(), "External tab lacks noopener")
        if "data-copy" in attrs:
            target = doc.ids.get(attrs["data-copy"])
            check(target and target.text.strip(), "Copy control has no content")
        for key in ("href", "src", "poster"):
            if key not in attrs:
                continue
            url = urlsplit(attrs[key])
            check(url.scheme in ("", "https", "http"), "Unexpected URL scheme")
            if url.scheme or url.netloc:
                check(bool(url.netloc), "External URL lacks a host")
                continue
            if url.path:
                target = (base / unquote(url.path)).resolve()
                check(target.is_relative_to(ROOT), "Local link escapes the repository")
                # Only existence is checked; media are never opened or decoded.
                check(target.is_file(), "Missing local asset: " + str(target))
            if url.fragment and not url.path:
                check(unquote(url.fragment) in doc.ids, "Broken page anchor: " + url.fragment)

    loader = 'loadstring(game:HttpGet("https://raw.githubusercontent.com/CarlDV/ProjectUAI/main/dist/uai.lua"))()'
    check(doc.ids["loadstringCode"].text.strip() == loader, "The copyable loader is incorrect")
    tools = [node.attrs["data-tool-name"] for node in doc.elements if "data-tool-name" in node.attrs]
    groups = [node.attrs["data-group"] for node in doc.elements if node.has_class("tool-group")]
    check(len(tools) == len(set(tools)) and len(tools) > 0, "Tool names are empty or duplicated")
    check(len(groups) == len(set(groups)) and len(groups) > 0, "Groups are empty or duplicated")
    for node in doc.elements:
        if "data-tool-ref" in node.attrs:
            check(node.attrs["data-tool-ref"] in tools, "Example names an unknown tool")
    options = {node.attrs.get("value") for node in doc.elements if node.tag == "option"}
    check(options == set(groups) | {""}, "Category options do not cover the catalog")
    for name, expected in (("tool-count", len(tools)), ("group-count", len(groups))):
        values = re.findall(r"<!-- site:" + name + r":start -->(\d+)<!-- site:" + name + r":end -->", source)
        check(values and all(int(value) == expected for value in values), "Incorrect displayed " + name)
    print(f"  HTML verified: {base.relative_to(ROOT) or '.'} ({len(tools)} tools, {len(groups)} groups)")


def validate_css():
    css = (ROOT / "style.css").read_text(encoding="utf-8")
    # Structural validation only, not a browser layout or cascade simulation.
    stripped = re.sub(r"/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'", "", css)
    stack = []
    for char in stripped:
        if char in "{([":
            stack.append(char)
        elif char in "})]":
            check(stack and stack.pop() == {"}": "{", ")": "(", "]": "["}[char],
                  "Unbalanced stylesheet")
    check(not stack, "Unclosed stylesheet delimiter")
    variables = dict(re.findall(r"(--[\w-]+)\s*:\s*(#[\da-fA-F]{6})\s*;", css))

    def color(selector, property_name):
        body = re.search(re.escape(selector) + r"\s*\{([^{}]+)\}", css)
        assert body, selector
        value = re.search(r"(?:^|;)\s*" + property_name + r"\s*:\s*([^;]+)", body[1])
        assert value, selector + " " + property_name
        text = value[1].strip()
        return variables[text[4:-1]] if text.startswith("var(") else text

    def luminance(hex_color):
        check(bool(re.fullmatch(r"#[0-9a-fA-F]{6}", hex_color)), "Expected opaque test color")
        rgb = [int(hex_color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
        rgb = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4 for value in rgb]
        return sum(value * weight for value, weight in zip(rgb, (.2126, .7152, .0722)))

    pairs = [
        ("body", variables["--ink"], variables["--canvas"]),
        ("secondary text", variables["--muted"], variables["--canvas"]),
        ("secondary text on paper", variables["--muted"], variables["--paper"]),
        ("accent links", variables["--accent"], variables["--canvas"]),
    ]
    for selector in (".button-primary", ".button-light", ".risk-read", ".risk-write", ".risk-danger", ".release-version"):
        pairs.append((selector, color(selector, "color"), color(selector, "background")))
    for label, foreground, background in pairs:
        light, dark = sorted((luminance(foreground), luminance(background)), reverse=True)
        check((light + .05) / (dark + .05) >= 4.5, "Low text contrast: " + label)
    check("prefers-reduced-motion: reduce" in css, "Reduced-motion rule missing")
    check("overflow-x: hidden" not in css, "Do not conceal page overflow")
    print("  CSS structure and primary text contrast verified")


def main():
    subprocess.run(["node", "tools/build_site.js", "--check"], cwd=ROOT, check=True)
    for base in (ROOT, ROOT / "docs"):
        validate_html(base)
    for name in ("index.html", "style.css", "script.js"):
        check((ROOT / name).read_bytes() == (ROOT / "docs" / name).read_bytes(),
              "Publishing copies differ: " + name)
    validate_css()
    print(f"Public site: {checks} static checks passed; no browser or media opened.")


if __name__ == "__main__":
    main()

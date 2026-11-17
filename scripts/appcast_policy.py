"""Parse and preserve authoritative Sparkle policy before updating an appcast."""
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

SPARKLE_URI = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = "{" + SPARKLE_URI + "}"
ET.register_namespace("sparkle", SPARKLE_URI)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
# The one updater compatibility policy (floor and workload protocol), shared
# with the publication verifier, the packaged Info.plist and the app.
POLICY_PATH = pathlib.Path(__file__).resolve().parent.parent / "release" / "updater-policy.json"

# Canonical major.minor.patch with no leading zeros: older apps compare the
# floor as an exact string, so "0.013.6" would not mean "0.13.6" to them.
CANONICAL_VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"

def parse_version(text):
    if not isinstance(text, str) or not re.fullmatch(CANONICAL_VERSION, text):
        raise ValueError("invalid version " + repr(text))
    return tuple(map(int, text.split(".")))

def load_policy(path=POLICY_PATH):
    policy = json.loads(pathlib.Path(path).read_text())
    if not isinstance(policy, dict) or policy.get("schema") != 1:
        raise ValueError("invalid updater policy")
    workload = policy.get("workloadProtocol")
    if type(workload) is not int or workload < 1:
        raise ValueError("invalid updater policy")
    parse_version(policy.get("minimumUpdateVersion"))
    return policy

def parse_feed(text):
    if len(text) > 1024 * 1024 or "<!DOCTYPE" in text or "<!ENTITY" in text:
        raise ValueError("unsupported appcast document")
    root = ET.fromstring(text)
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise ValueError("expected one RSS channel")
    channel = channels[0]
    items = channel.findall("item")
    if len(list(root.iter("item"))) != len(items):
        raise ValueError("nested appcast items are unsupported")
    versions = {}
    for item in items:
        fields = item.findall(SPARKLE + "version")
        if len(fields) != 1 or not fields[0].text or fields[0].text.strip() in versions:
            raise ValueError("missing, ambiguous or duplicate appcast version")
        enclosures = item.findall("enclosure")
        if len(enclosures) > 1:
            raise ValueError("ambiguous appcast enclosure")
        informational = not enclosures or item.find(SPARKLE + "informationalUpdate") is not None
        if informational and not item.findtext("link", "").startswith("https://"):
            raise ValueError("informational policy requires an HTTPS link")
        versions[fields[0].text.strip()] = (item, informational)
    return root, channel, versions

def update_feed(xml, options):
    root, channel, versions = parse_feed(xml)
    version = options["version"].removeprefix("v")
    if not re.fullmatch(CANONICAL_VERSION, version):
        raise ValueError("invalid release version")
    url = options["url"]
    if urlparse(url).scheme != "https":
        raise ValueError("release URL must use HTTPS")
    informational = options.get("informational", False)
    if informational:
        if url != "https://github.com/castlemilk/micropod/releases/tag/v" + version:
            raise ValueError("informational updates must link to the public release page")
        if "signature" in options or "length" in options:
            raise ValueError("informational announcements cannot include a payload")
    elif not options.get("signature") or not re.fullmatch(r"[1-9]\d*", str(options.get("length", ""))):
        raise ValueError("installable items require signature and positive length")
    existing = versions.get(version)
    if existing:
        if not informational and existing[1]:
            raise ValueError("cannot turn an informational announcement into an installable update")
        channel.remove(existing[0])
    languages = channel.findall("language")
    if len(languages) != 1 or languages[0].text != "en":
        raise ValueError("expected one English channel marker")
    item = ET.Element("item")
    for tag, text in [("title", "Version " + version), ("pubDate", options["pubDate"]),
                      (SPARKLE + "version", version), (SPARKLE + "shortVersionString", version)]:
        ET.SubElement(item, tag).text = text
    if informational:
        ET.SubElement(item, "link").text = url
        ET.SubElement(item, SPARKLE + "informationalUpdate")
        ET.SubElement(item, "description", {SPARKLE + "format": "plain-text"}).text = (
            "Cache visibility fixes are available. Installation requires stopping Micropod and its workloads; "
            "automatic replacement remains disabled.")
    else:
        source = options.get("source")
        if source is not None and not re.fullmatch(r"[0-9a-f]{40}", source):
            raise ValueError("invalid source revision")
        minimum = options.get("minimum-update-version")
        workload = options.get("workload-protocol")
        if (minimum is None) != (workload is None):
            raise ValueError("workload items need both a compatibility floor and a workload protocol")
        if minimum is not None:
            # A floor below the policy's would also admit updaters known not to
            # retain workloads; a higher one (a later policy) stays valid.
            policy = load_policy()
            try:
                floor = parse_version(minimum)
            except ValueError:
                raise ValueError("unsupported workload updater compatibility floor") from None
            if floor < parse_version(policy["minimumUpdateVersion"]) or parse_version(version) < floor:
                raise ValueError("unsupported workload updater compatibility floor")
            if type(workload) is bool or str(workload) != str(policy["workloadProtocol"]):
                raise ValueError("unsupported workload protocol")
            ET.SubElement(item, SPARKLE + "minimumUpdateVersion").text = minimum
        attributes = {"url": url, SPARKLE + "edSignature": options["signature"],
                      "length": str(options["length"]), "type": "application/octet-stream"}
        if source is not None:
            attributes["micropodSourceRevision"] = source
        if workload is not None:
            attributes["micropodWorkloadProtocol"] = str(workload)
        ET.SubElement(item, "enclosure", attributes)
    channel.insert(list(channel).index(languages[0]) + 1, item)
    ET.indent(root, space="  ")
    result = ET.tostring(root, encoding="utf-8", xml_declaration=True).decode("utf-8") + "\n"
    parse_feed(result)
    return result

if __name__ == "__main__":
    try:
        text = sys.stdin.read(2 * 1024 * 1024 + 1)
        if len(text) > 2 * 1024 * 1024:
            raise ValueError("unsupported appcast request")
        if sys.argv[1:] == ["--update"]:
            request = json.loads(text)
            print(update_feed(request["xml"], request["options"]), end="")
        else:
            parse_feed(text)
    except (KeyError, TypeError, ValueError, ET.ParseError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

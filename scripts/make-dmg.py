#!/usr/bin/env python3
"""
Build the NeoDrop drag-and-drop DMG, then read back what was actually written.

A DMG's layout lives in a binary `.DS_Store` at the root of the image, which Finder reads to
position icons and draw the background. Writing that file by hand is error-prone and AppleScript
driving Finder needs Automation permission and a GUI, so this uses dmgbuild, which writes the
`.DS_Store` directly and works headlessly in a build script.

Because nobody can eyeball a build, this script verifies its own output: it mounts the finished
image and checks the recorded layout against the artwork's own geometry — that each real icon
lands on top of the icon painted into the background, and that neither covers the arrow or the
caption. Getting that wrong is how you ship a DMG with four icons in it.

Usage:
    make-dmg.py --app build/NeoDrop.app --output build/NeoDrop.dmg
               --background Resources/dmg-background.png --layout build/dmg-layout.json
               [--badge-icon build/NeoDrop.icns] [--volume-name NeoDrop] [--dump]

Exit status: 0 when the image built and every layout check passed, 1 otherwise.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

APP_NAME = "NeoDrop"
APPLICATIONS_LINK = "Applications"


def fail(message):
    print(f"  FAIL {message}", file=sys.stderr)
    return 1


def ok(message):
    print(f"  ok   {message}")


def note(message):
    print(f"  --   {message}")


# ---------------------------------------------------------------------------------------------
# Building


def build(args, layout):
    try:
        import dmgbuild
    except ImportError:
        print(
            "make-dmg.py: dmgbuild is not installed.\n"
            "  install it with:  scripts/setup-dmg-tools.sh\n"
            "  (or: python3 -m venv .venv && ./.venv/bin/pip install dmgbuild)",
            file=sys.stderr,
        )
        return 1

    settings = {
        "volume_name": args.volume_name,
        # Built read-write first, so the volume's custom-icon bit can be set on the mounted image
        # below; a compressed UDZO cannot be modified afterwards.
        "format": "UDRW",
        "files": [args.app, args.readme],
        "symlinks": {APPLICATIONS_LINK: "/Applications"},
        # Both icons sit exactly where the background art paints them.
        "icon_locations": {
            f"{APP_NAME}.app": tuple(layout["appIcon"]["centre"]),
            APPLICATIONS_LINK: tuple(layout["applicationsIcon"]["centre"]),
        },
        "icon_size": layout["iconSize"],
        "background": args.background,
        # dmgbuild copies this to .VolumeIcon.icns. Its own badge_icon option cannot be used here:
        # in 1.6.5 it imports Quartz (pyobjc) and is gated on a `badge` flag that is hard-coded to
        # None, so it never runs.
        "icon": args.badge_icon,
        "window_rect": ((200, 160), (layout["window"]["width"], layout["window"]["height"])),
        "default_view": "icon-view",
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "show_icon_preview": False,
        "label_pos": "bottom",
        "text_size": 13,
        "arrange_by": "none",
        # The instructions should not clutter the window; it stays in the image for anyone who
        # opens the DMG from a shell.
        "hide": ["Read Me First.txt"],
    }

    if os.path.exists(args.output):
        os.remove(args.output)

    print("Building the DMG with dmgbuild…")
    intermediate = f"{args.output}.rw.dmg"
    if os.path.exists(intermediate):
        os.remove(intermediate)
    dmgbuild.build_dmg(
        intermediate,
        args.volume_name,
        settings=settings,
        callback=lambda message: None,
    )
    if not os.path.exists(intermediate):
        return fail("dmgbuild did not produce an image")

    # Mark the volume as having a custom icon while it is still writable. Without this the
    # .VolumeIcon.icns sits there unused and Finder shows a generic disk.
    mount_point = tempfile.mkdtemp(prefix="neodrop-rw-")
    try:
        subprocess.run(
            ["hdiutil", "attach", intermediate, "-nobrowse", "-mountpoint", mount_point],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if not os.path.exists(os.path.join(mount_point, ".VolumeIcon.icns")):
            return fail(".VolumeIcon.icns was not written into the image")
        subprocess.run(["SetFile", "-a", "C", mount_point], check=True)
        ok("volume custom-icon bit set")
    except subprocess.CalledProcessError as error:
        return fail(f"could not set the volume icon: {error}")
    finally:
        unmount(mount_point)
        shutil.rmtree(mount_point, ignore_errors=True)

    # Compress the finished filesystem. The .DS_Store, the background, the custom-icon bit and the
    # payload all carry across the conversion untouched.
    print("Compressing…")
    result = subprocess.run(
        ["diskutil", "image", "create", "from", "--format", "UDZO",
         "--volumeName", args.volume_name, intermediate, args.output],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        os.remove(intermediate)
    except OSError:
        pass
    if result.returncode != 0 or not os.path.exists(args.output):
        return fail(f"compression failed: {result.stderr.decode().strip()[:200]}")

    ok(f"image written ({os.path.getsize(args.output) // 1024} KB)")
    return 0


# ---------------------------------------------------------------------------------------------
# Verification


def mount(image, mount_point):
    subprocess.run(
        ["hdiutil", "attach", image, "-nobrowse", "-readonly", "-mountpoint", mount_point],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def unmount(mount_point):
    subprocess.run(["hdiutil", "detach", mount_point], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def read_store(mount_point):
    """Every .DS_Store record, as {(filename, code text): value}.

    `ds_store` hands back record codes as bytes (and not consistently cased: `b'Iloc'` alongside
    `b'icvp'`), so they are normalised to lower-case text here to keep lookups honest.
    """
    from ds_store import DSStore

    path = os.path.join(mount_point, ".DS_Store")
    if not os.path.exists(path):
        return None
    records = {}
    with DSStore.open(path, "r") as store:
        for entry in store:
            code = entry.code.decode() if isinstance(entry.code, bytes) else str(entry.code)
            records[(entry.filename, code.lower())] = entry.value
    return records


def find_record(records, code, filename=None):
    """Value of a record, matched case-insensitively on the code."""
    wanted = code.lower()
    for (name, record_code), value in records.items():
        if record_code == wanted and (filename is None or name == filename):
            return value
    return None


def icon_location(value):
    """ds_store returns an IconLocation; pull (x, y) out without depending on its exact shape."""
    if value is None:
        return None
    for attribute in ("x", "y"):
        if not hasattr(value, attribute):
            break
    else:
        return (float(value.x), float(value.y))
    try:
        return (float(value[0]), float(value[1]))
    except (TypeError, IndexError, KeyError):
        return None


def window_size(bwsp):
    """'WindowBounds' is a string like '{{196, 240}, {724, 543}}'."""
    if not isinstance(bwsp, dict):
        return None
    bounds = bwsp.get("WindowBounds")
    if not isinstance(bounds, str) or "}, {" not in bounds:
        return None
    try:
        size = bounds.split("}, {")[1].rstrip("}")
        width, height = size.split(",")
        return (float(width.strip()), float(height.strip()))
    except (IndexError, ValueError):
        return None


def background_dimensions(mount_point):
    """The resolutions in the image's background file, as a count and the smallest.

    dmgbuild writes a multi-representation TIFF (`.background.tiff`) when the 1x and @2x pair are
    found together, and a plain copy of the single image otherwise. `tiffutil -info` reports one
    'Image Width: W Image Length: H' block per representation.
    """
    import glob
    import re

    candidates = glob.glob(os.path.join(mount_point, ".background.*"))
    if not candidates:
        return None
    result = subprocess.run(["tiffutil", "-info", candidates[0]], capture_output=True, text=True)
    sizes = re.findall(r"Image Width:\s*(\d+)\s*Image Length:\s*(\d+)", result.stdout)
    if not sizes:
        return None
    dims = sorted((int(w), int(h)) for w, h in sizes)
    return dims, dims[0]


def rect(centre, size):
    half = size / 2.0
    return (centre[0] - half, centre[1] - half, centre[0] + half, centre[1] + half)


def contains(outer, inner, slack=0.0):
    return (
        outer[0] <= inner[0] + slack
        and outer[1] <= inner[1] + slack
        and outer[2] >= inner[2] - slack
        and outer[3] >= inner[3] - slack
    )


def overlaps(a, b):
    return not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1])


def verify(args, layout):
    failures = []

    mount_point = tempfile.mkdtemp(prefix="neodrop-dmg-")
    try:
        mount(args.output, mount_point)
    except subprocess.CalledProcessError as error:
        return fail(f"the image does not mount: {error.stderr.decode().strip()}")

    try:
        # 1. The drag-and-drop pieces have to be present.
        if os.path.isdir(os.path.join(mount_point, f"{APP_NAME}.app")):
            ok(f"{APP_NAME}.app is in the image")
        else:
            failures.append(f"{APP_NAME}.app is missing from the image")

        if os.path.islink(os.path.join(mount_point, APPLICATIONS_LINK)):
            ok("/Applications drop target present")
        else:
            failures.append("the Applications symlink is missing")

        if os.path.exists(os.path.join(mount_point, ".VolumeIcon.icns")):
            ok("volume icon present")
        else:
            failures.append("no .VolumeIcon.icns in the image")

        # Slash the instructions out of the window but keep them on the disk.
        readme_name = os.path.basename(args.readme)
        readme_path = os.path.join(mount_point, readme_name)
        if os.path.exists(readme_path):
            listing = subprocess.run(["ls", "-lO", readme_path], capture_output=True, text=True).stdout
            if "hidden" in listing:
                ok(f"{readme_name} is included but hidden")
            else:
                failures.append(f"{readme_name} is not hidden, so it will show in the window")
        else:
            failures.append(f"{readme_name} is missing from the image")

        # 2. The layout Finder will read.
        records = read_store(mount_point)
        if records is None:
            return fail("the image has no .DS_Store, so Finder would not lay it out at all")

        if args.dump:
            print("    .DS_Store records:")
            for (filename, code), value in sorted(records.items()):
                print(f"      {filename!r:28} {code!r:8} {value!r}")

        bwsp = find_record(records, "bwsp")
        icvp = find_record(records, "icvp")

        expected_size = (layout["window"]["width"], layout["window"]["height"])
        actual_size = window_size(bwsp)
        if actual_size and abs(actual_size[0] - expected_size[0]) < 1 and abs(actual_size[1] - expected_size[1]) < 1:
            ok(f"window matches the artwork: {int(actual_size[0])}x{int(actual_size[1])} points")
        else:
            failures.append(f"window size is {actual_size}, expected {expected_size}")

        if isinstance(icvp, dict) and abs(float(icvp.get("iconSize", 0)) - layout["iconSize"]) < 0.5:
            ok(f"icon size matches the painted icon: {layout['iconSize']} points")
        else:
            failures.append(
                f"icon size is {icvp.get('iconSize') if isinstance(icvp, dict) else icvp}, "
                f"expected {layout['iconSize']}"
            )

        if isinstance(icvp, dict) and icvp.get("backgroundType") == 2 and icvp.get("backgroundImageAlias"):
            ok("background picture is set")
        else:
            failures.append("the window has no background picture recorded")

        # Finder does not scale a background to fit the window; it draws it at its own size. A
        # single-resolution image larger than the window would therefore show only its top-left
        # corner, so the background must be a 1x/@2x pair whose 1x is exactly the window. dmgbuild
        # only combines the pair when it finds an @2x beside the 1x, and silently ships a plain copy
        # otherwise — which is precisely the failure this has to catch.
        background = background_dimensions(mount_point)
        if background is None:
            failures.append("the image has no background file")
        else:
            representations, smallest = background
            largest = representations[-1]
            if len(representations) < 2:
                failures.append(
                    f"the background has only one resolution ({smallest}), so Retina screens would "
                    "get an upscaled bitmap"
                )
            elif smallest != expected_size:
                failures.append(
                    f"the background's 1x representation is {smallest}, but the window is "
                    f"{int(expected_size[0])}x{int(expected_size[1])} — Finder would not scale it"
                )
            elif largest != (smallest[0] * 2, smallest[1] * 2):
                failures.append(
                    f"the background's representations are not a 1x/@2x pair: {smallest} and {largest}"
                )
            else:
                ok(
                    f"background is {smallest[0]}x{smallest[1]} at 1x / {largest[0]}x{largest[1]} at 2x, "
                    "matching the window"
                )

        # 3. The thing that actually matters: the real icons must cover the painted ones. What has to
        #    cover the painted tile is the artwork *inside* the icon box, and an app icon only fills
        #    ~80% of the box it is drawn in (Apple's 1024 canvas has an 824-point body), so comparing
        #    the nominal box against the painted tile would pass on an image that shows the painted
        #    icon peeking out on every side.
        icon_size = layout["iconSize"]
        body_ratio = layout.get("iconBodyRatio")
        if not body_ratio:
            return fail("the layout records no iconBodyRatio, so icon coverage cannot be judged")
        drawn_size = icon_size * body_ratio
        app_centre = icon_location(find_record(records, "Iloc", f"{APP_NAME}.app"))
        links_centre = icon_location(find_record(records, "Iloc", APPLICATIONS_LINK))

        for label, centre, painted in (
            (APP_NAME, app_centre, layout["appIcon"]["box"]),
            (APPLICATIONS_LINK, links_centre, layout["applicationsIcon"]["box"]),
        ):
            if centre is None:
                failures.append(f"no icon location recorded for {label}")
                continue
            expected = tuple(layout["appIcon"]["centre"] if label == APP_NAME else layout["applicationsIcon"]["centre"])
            if abs(centre[0] - expected[0]) > 2 or abs(centre[1] - expected[1]) > 2:
                failures.append(f"{label} is placed at {centre}, expected {expected}")
                continue

            real = rect(centre, drawn_size)
            painted_box = (painted[0], painted[1], painted[0] + painted[2], painted[1] + painted[3])
            if contains(real, painted_box):
                ok(f"{label}'s drawn body ({drawn_size:.0f}pt) covers the painted icon")
            else:
                failures.append(
                    f"{label} would not cover the painted icon: icon {tuple(round(v) for v in real)} "
                    f"vs painted {tuple(round(v) for v in painted_box)}"
                )

            if layout.get("arrow"):
                arrow = layout["arrow"]
                arrow_box = (arrow[0], arrow[1], arrow[0] + arrow[2], arrow[1] + arrow[3])
                if overlaps(real, arrow_box):
                    failures.append(f"{label} overlaps the painted arrow")
            if real[3] > layout["captionTop"]:
                failures.append(
                    f"{label} reaches y={round(real[3])}, past the caption at y={layout['captionTop']}"
                )

        if not any(f.startswith("overlaps the painted arrow") or "past the caption" in f for f in failures):
            ok("neither icon covers the arrow or the caption")
    finally:
        unmount(mount_point)
        shutil.rmtree(mount_point, ignore_errors=True)

    if failures:
        print()
        for failure in failures:
            fail(failure)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description="Build and verify the NeoDrop drag-and-drop DMG")
    parser.add_argument("--app", required=True, help="the built NeoDrop.app")
    parser.add_argument("--output", required=True, help="DMG to write")
    parser.add_argument("--background", required=True, help="installer artwork (PNG)")
    parser.add_argument("--layout", required=True, help="layout JSON from scripts/dmg-layout.swift")
    parser.add_argument("--badge-icon", default=None, help=".icns for the mounted volume")
    parser.add_argument("--readme", default=None, help="extra file to include (hidden)")
    parser.add_argument("--volume-name", default=APP_NAME)
    parser.add_argument("--build-only", action="store_true", help="skip verification")
    parser.add_argument("--dump", action="store_true", help="print every .DS_Store record")
    args = parser.parse_args()

    if args.readme is None:
        args.readme = os.path.join(os.path.dirname(os.path.abspath(args.output)), "Read Me First.txt")

    for path in (args.app, args.background, args.layout, args.readme):
        if not os.path.exists(path):
            return fail(f"missing input: {path}")
    if args.badge_icon and not os.path.exists(args.badge_icon):
        return fail(f"missing badge icon: {args.badge_icon}")

    with open(args.layout) as handle:
        layout = json.load(handle)

    status = build(args, layout)
    if status != 0:
        return status

    if args.build_only:
        return 0

    print("Verifying the layout Finder will read…")
    status = verify(args, layout)
    if status == 0:
        print("DMG layout verification passed")
    return status


if __name__ == "__main__":
    sys.exit(main())

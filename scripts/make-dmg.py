#!/usr/bin/env python3
"""
Build the NeoDrop drag-and-drop DMG, then read back what was actually written.

A DMG's layout lives in a binary `.DS_Store` at the root of the image, which Finder reads to
position icons and draw the background. Writing that file by hand is error-prone and AppleScript
driving Finder needs Automation permission and a GUI, so this uses dmgbuild, which writes the
`.DS_Store` directly and works headlessly in a build script.

Because nobody can eyeball a build, this script verifies its own output: it mounts the finished
image and reads the layout back — each icon is where the layout says, at the size Finder was asked
for, with its box and its label inside the window. An icon that hangs outside makes Finder re-lay-out
the whole window, which is how you ship a DMG with icons scattered across it.

Usage:
    make-dmg.py --app build/NeoDrop.app --output build/NeoDrop.dmg
               --background build/dmg-background.png --layout build/dmg-layout.json
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

# Finder positions an icon's *cell* — the icon's box plus the label under it — near the point it is
# given, and the box lands to the right of and above that point: the cell is wider than the box, so
# the box is inset from its left edge, and the label block hangs below the box, which pulls the box
# up. Both offsets are measured, never assumed.
#
# Measured on macOS 26 by capturing a mounted window and template-matching the drawn icon against
# the real icon art (the app icon matches at 0.985 confidence). With the point at (449, 195) the drawn
# box centre landed at (464, 195): 15pt right of the recorded x, and level with the recorded y.
#
# Reading that offset correctly needs the window content's own origin, and both easy ways to get it are
# wrong: the window's bounding box starts at its shadow and title bar, which put the measurement 32pt
# too high in an earlier version of this file and inverted the sign of the y correction (it then asked
# for the icons 30pt below where they belong). The reliable reference is the first row below the title
# bar that is no longer grey.
BOX_RIGHT_OF_POINT = 15.0
BOX_ABOVE_POINT = 0.0


def placed(centre):
    """The .DS_Store point that puts an icon's box centre at `centre`."""
    return (int(round(centre[0] - BOX_RIGHT_OF_POINT)), int(round(centre[1] + BOX_ABOVE_POINT)))


def drawn(recorded):
    """Where an icon's box centre actually lands, given the point .DS_Store records."""
    if recorded is None:
        return None
    return (recorded[0] + BOX_RIGHT_OF_POINT, recorded[1] - BOX_ABOVE_POINT)


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
        # Both icons sit exactly where the background art paints them, and the instructions sit in the
        # band beside the art that exists to give them somewhere to go. All three are placed through
        # `placed()` so the box, not the cell, lands on the measured centre.
        "icon_locations": {
            f"{APP_NAME}.app": placed(layout["appIcon"]["centre"]),
            APPLICATIONS_LINK: placed(layout["applicationsIcon"]["centre"]),
            os.path.basename(args.readme): placed(layout["noticeIcon"]["centre"]),
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
        "text_size": args.text_size,
        "arrange_by": "none",
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
        if not set_label_background(mount_point, args.label_ground):
            return fail("could not set the label background colour")
    except subprocess.CalledProcessError as error:
        return fail(f"could not set the volume icon: {error}")
    finally:
        # Only remove the staging directory once the image is really gone: rmtree on a mount point
        # that is still mounted does nothing, which is how the directory (and the mount) accumulated.
        if unmount(mount_point):
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


def set_label_background(mount_point, colour):
    """Record a dark "background colour" beside the background picture.

    Finder colours every icon's label itself, and the two obvious knobs do not work: it is not the
    system appearance (the labels were black while the window chrome was dark), and it is not the
    brightness of the background picture — multiplying the wallpaper down to 28% of its original
    brightness left the labels black, over artwork that was nearly black itself. What the record does
    carry is `backgroundColorRed/Green/Blue` in `icvp`, which dmgbuild writes as white beside a
    picture, and that is what Finder reads when it decides between its dark and light label colours.
    Writing a dark value there leaves the picture exactly as it was and turns the labels white.

    Returns True when the record was written; the file's absence or an unreadable record is a failure,
    because silently leaving white here is the difference between a readable window and an unreadable
    one.
    """
    from ds_store import DSStore

    path = os.path.join(mount_point, ".DS_Store")
    if not os.path.exists(path):
        return False
    red, green, blue = colour
    try:
        with DSStore.open(path, "r+") as store:
            record = store["."]["icvp"]
            record["backgroundColorRed"] = red
            record["backgroundColorGreen"] = green
            record["backgroundColorBlue"] = blue
            store["."]["icvp"] = record
    except Exception as error:  # noqa: BLE001 - the library raises whatever the format does
        print(f"make-dmg.py: could not write the label background colour: {error}", file=sys.stderr)
        return False
    ok(f"label background recorded as ({red}, {green}, {blue})")
    return True


def mount(image, mount_point):
    subprocess.run(
        ["hdiutil", "attach", image, "-nobrowse", "-readonly", "-mountpoint", mount_point],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def unmount(mount_point):
    """Detach the image, and try harder when the volume is busy. Returns True when it let go.

    A detach fails while anything still has the volume open, and Spotlight indexing an image the
    script has just written does exactly that. The failure used to be thrown away, so the mount
    outlived the run — and a leaked mount is not harmless: the next packaging run fails inside
    `diskutil image create` with "Resource temporarily unavailable" (error 156) and nothing on
    screen connects the two. So: retry with -force, and if it still will not let go, say which
    volume is stuck and how to eject it, rather than leaving it for the next person to find.
    """
    for force in (False, True):
        command = ["hdiutil", "detach", mount_point] + (["-force"] if force else [])
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 0 or not os.path.ismount(mount_point):
            return True
    fail(f"{mount_point} is still mounted: eject it before packaging again "
         f"(diskutil eject \"{mount_point}\")")
    return False


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


def box_xywh(values):
    """A measured [x, y, width, height] as the (x0, y0, x1, y1) the overlap tests use."""
    return (values[0], values[1], values[0] + values[2], values[1] + values[3])


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

        # The instructions are part of the window now, so they must be present and not carrying the
        # hidden flag that previously kept them off it.
        readme_name = os.path.basename(args.readme)
        readme_path = os.path.join(mount_point, readme_name)
        if os.path.exists(readme_path):
            listing = subprocess.run(["ls", "-lO", readme_path], capture_output=True, text=True).stdout
            if "hidden" in listing:
                failures.append(f"{readme_name} is still flagged hidden, so it would not show in the window")
            else:
                ok(f"{readme_name} is in the image and visible in the window")
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
            ok(f"window matches the layout: {int(actual_size[0])}x{int(actual_size[1])} points")
        else:
            failures.append(f"window size is {actual_size}, expected {expected_size}")

        if isinstance(icvp, dict) and abs(float(icvp.get("iconSize", 0)) - layout["iconSize"]) < 0.5:
            ok(f"icon size matches the layout's slot: {layout['iconSize']} points")
        else:
            failures.append(
                f"icon size is {icvp.get('iconSize') if isinstance(icvp, dict) else icvp}, "
                f"expected {layout['iconSize']}"
            )

        if isinstance(icvp, dict) and icvp.get("backgroundType") == 2 and icvp.get("backgroundImageAlias"):
            ok("background picture is set")
        else:
            failures.append("the window has no background picture recorded")

        # The labels are Finder's, and the background colour recorded beside the picture is what it
        # reads to choose between black and white ones. A white value here puts unreadable black
        # labels on the dark artwork, which is the exact defect this window shipped with twice.
        if isinstance(icvp, dict):
            ground = tuple(icvp.get(f"backgroundColor{channel}", 1.0) for channel in ("Red", "Green", "Blue"))
            luminance = 0.2126 * ground[0] + 0.7152 * ground[1] + 0.0722 * ground[2]
            if luminance < 0.35:
                ok(f"label background is dark (luminance {luminance:.2f}), so Finder draws white labels")
            else:
                failures.append(
                    f"the label background is {tuple(round(v, 2) for v in ground)} (luminance "
                    f"{luminance:.2f}) — Finder would draw black labels on the dark artwork"
                )
        else:
            failures.append("no view-options record to read the label background colour from")

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

        # 3. Each icon has to cover the slot the layout puts it on. The background paints nothing, so
        #    nothing is doubled if this drifts — but the slot is where the design says the icon goes,
        #    and an icon body smaller than its slot would mean the size Finder was asked for is not the
        #    size it used. What has to cover the slot is the artwork *inside* the icon box, and an app
        #    icon only fills ~80% of the box it is drawn in (Apple's 1024 canvas has an 824-point body),
        #    so comparing the nominal box against the slot would pass on an image that shows the slot
        #    peeking out on every side.
        icon_size = layout["iconSize"]
        body_ratio = layout.get("iconBodyRatio")
        if not body_ratio:
            return fail("the layout records no iconBodyRatio, so icon coverage cannot be judged")
        drawn_size = icon_size * body_ratio
        app_centre = drawn(icon_location(find_record(records, "Iloc", f"{APP_NAME}.app")))
        links_centre = drawn(icon_location(find_record(records, "Iloc", APPLICATIONS_LINK)))
        notice_centre = drawn(icon_location(find_record(records, "Iloc", readme_name)))

        # Every icon's whole cell — box plus the label under it — has to sit inside the window's
        # content area. An icon whose cell hangs outside makes Finder re-lay-out the entire window:
        # measured on macOS 26, every icon then lands ~92pt below where it was asked to go, on both
        # axes at once. That is exactly what shipped a window with four visible icons in it.
        window = (layout["window"]["width"], layout["window"]["height"])
        label_height = layout.get("labelHeight", 22)
        label_gap = layout.get("labelGap", 6)
        oversize = []
        for name, centre in ((APP_NAME, app_centre), (APPLICATIONS_LINK, links_centre),
                             (readme_name, notice_centre)):
            if centre is None:
                failures.append(f"no icon location recorded for {name}")
                continue
            if (centre[0] - icon_size / 2 < 0 or centre[0] + icon_size / 2 > window[0]
                    or centre[1] - icon_size / 2 < 0
                    or centre[1] + icon_size / 2 + label_gap + label_height > window[1]):
                oversize.append(name)
        if oversize:
            failures.append(
                f"{' and '.join(oversize)} would not fit inside the {int(window[0])}x{int(window[1])} "
                "window — an icon that hangs outside makes Finder re-lay-out every icon in the window"
            )
        else:
            ok("every icon's box and label sit inside the window")

        for label, centre, slot in (
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
            slot_box = (slot[0], slot[1], slot[0] + slot[2], slot[1] + slot[3])
            # How far the slot sticks out past the drawn body, in points. A couple of points are
            # allowed, because the sizes round to whole points on both sides. What this catches is a
            # real shortfall — a size Finder did not honour, or an icon placed somewhere else.
            exposure = max(real[0] - slot_box[0], real[1] - slot_box[1],
                           slot_box[2] - real[2], slot_box[3] - real[3])
            if exposure <= 2:
                ok(f"{label}'s drawn body ({drawn_size:.0f}pt) covers its {int(slot[2])}pt slot")
            else:
                failures.append(
                    f"{label} would leave {exposure:.0f}pt of its slot showing: "
                    f"body {tuple(round(v) for v in real)} vs slot {tuple(round(v) for v in slot_box)}"
                )

            if layout.get("arrow"):
                arrow = layout["arrow"]
                arrow_box = (arrow[0], arrow[1], arrow[0] + arrow[2], arrow[1] + arrow[3])
                if overlaps(real, arrow_box):
                    failures.append(f"{label} overlaps the arrow")
            if real[3] > layout["captionTop"]:
                failures.append(
                    f"{label} reaches y={round(real[3])}, past the caption at y={layout['captionTop']}"
                )

        # The layout of a background with nothing drawn on it records no arrow and no caption, so these
        # stay quiet rather than claiming a check that had nothing to check.
        if not any(f.startswith("overlaps the arrow") or "past the caption" in f for f in failures):
            note("the background draws no arrow and no caption, so there is nothing to cover")

        # Kept for a background that does have a caption: the labels have to clear its ink, because
        # Finder draws each label just below its icon box and the two would then be a few points apart.
        caption = layout.get("captionBox")
        if not caption or caption[2] <= 0 or caption[3] <= 0:
            # The background draws nothing under the labels, so there is nothing for them to clear.
            note("the background has no caption, so the labels have nothing to clear")
        else:
            caption_box = box_xywh(caption)
            for name, key in ((APP_NAME, "appIcon"), (APPLICATIONS_LINK, "applicationsIcon"),
                              (readme_name, "noticeIcon")):
                label = layout[key].get("label")
                if not label:
                    failures.append(f"the layout records no label box for {name}")
                elif overlaps(box_xywh(label), caption_box):
                    failures.append(f"{name}'s label would sit on the caption")
            if not any("label" in f for f in failures):
                ok("every label clears the caption")

        # 4. The instructions have to sit in their own slot, clear of the other two. A third icon is
        #    an easier thing to misplace than the first two: it is expected to be an odd size in an odd
        #    place, so an overlap would look almost intentional.
        notice = layout.get("noticeIcon")
        if not notice:
            failures.append("the layout records no slot for the instructions")
        else:
            expected_notice = tuple(notice["centre"])
            if notice_centre is None:
                failures.append(f"no icon location recorded for {readme_name}")
            elif abs(notice_centre[0] - expected_notice[0]) > 2 or abs(notice_centre[1] - expected_notice[1]) > 2:
                failures.append(f"{readme_name} is placed at {notice_centre}, expected {expected_notice}")
            else:
                ok(f"{readme_name} sits at its slot {expected_notice}")

            notice_body = rect(expected_notice, notice["size"] * body_ratio)
            label = notice["label"]
            notice_label = box_xywh(label)
            obstacles = {
                f"the {APP_NAME} slot": box_xywh(layout["appIcon"]["box"]),
                f"the {APPLICATIONS_LINK} slot": box_xywh(layout["applicationsIcon"]["box"]),
            }
            if layout.get("arrow"):
                obstacles["the arrow"] = box_xywh(layout["arrow"])
            collisions = [
                name for name, box in obstacles.items()
                if overlaps(notice_body, box) or overlaps(notice_label, box)
            ]
            if collisions:
                failures.append(f"{readme_name} would sit on {', '.join(collisions)}")
            elif max(notice_body[3], notice_label[3]) > layout["captionTop"]:
                failures.append(
                    f"{readme_name} reaches y={round(max(notice_body[3], notice_label[3]))}, "
                    f"past the caption at y={layout['captionTop']}"
                )
            else:
                ok(f"{readme_name}'s icon and label clear the other two slots")
    finally:
        if unmount(mount_point):
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
    parser.add_argument("--background", required=True, help="installer background (PNG; its @2x is picked up beside it)")
    parser.add_argument("--layout", required=True, help="layout JSON from scripts/make-dmg-artwork.swift")
    parser.add_argument("--badge-icon", default=None, help=".icns for the mounted volume")
    parser.add_argument("--readme", default=None, help="extra file to include (hidden)")
    parser.add_argument("--volume-name", default=APP_NAME)
    parser.add_argument("--text-size", type=int, default=13,
                        help="label text size Finder is asked for (default 13)")
    parser.add_argument("--label-ground", default="0.03,0.05,0.14",
                        help="the background colour Finder reads when choosing the label colour "
                             "(dark values give white labels; the picture is unaffected)")
    parser.add_argument("--build-only", action="store_true", help="skip verification")
    parser.add_argument("--dump", action="store_true", help="print every .DS_Store record")
    args = parser.parse_args()

    try:
        args.label_ground = tuple(float(part) for part in args.label_ground.split(","))
    except ValueError:
        return fail("--label-ground needs three numbers, e.g. 0.03,0.05,0.14")
    if len(args.label_ground) != 3 or not all(0.0 <= value <= 1.0 for value in args.label_ground):
        return fail("--label-ground needs three values in 0...1")

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

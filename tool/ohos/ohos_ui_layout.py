#!/usr/bin/env python3
import json
import re
import sys

data = json.load(open(sys.argv[2], encoding="utf-8"))
mode = sys.argv[1]

def bounds(attrs):
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attrs.get("bounds", ""))
    if not match:
        raise ValueError("node has no bounds")
    x1, y1, x2, y2 = map(int, match.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2, attrs["bounds"]

def is_effectively_visible(attrs):
    if attrs.get("visible") == "false" or attrs.get("enabled") == "false":
        return False
    # OHOS accessibility dumps can report opacity=0 for a Flutter overlay
    # that is visibly rendered. Treat opacity as diagnostic evidence only;
    # the click target must instead come from the newest post-wakeup dump.
    return True

def is_painted_visible(attrs):
    """Require a hit target to be both exposed and currently painted.

    OHOS can retain an accessibility node after a Flutter control layer has
    animated to opacity zero. That node is not a valid coordinate target even
    though visible=true and clickable=true remain in the dump.
    """
    if not is_effectively_visible(attrs):
        return False
    raw_opacity = str(attrs.get("opacity", "")).strip()
    if not raw_opacity:
        return True
    try:
        return float(raw_opacity) > 0.001
    except ValueError:
        return True

def is_current_control_target(attrs, slider_centers):
    """Accept a fresh Flutter target whose OHOS opacity field is unreliable.

    On the device the control layer is visibly painted while accessibility
    exports opacity=0. A stale node, however, can retain the same semantic id
    after its bounds moved to the previous orientation. The current progress
    slider provides a layout-local anchor for the bottom control band; an
    opacity-zero button is accepted only when it is close to that anchor.
    """
    if is_painted_visible(attrs):
        return True
    if str(attrs.get("opacity", "")).strip() not in ("0", "0.0", "0.000000"):
        return False
    try:
        _, center_y, _ = bounds(attrs)
    except ValueError:
        return False
    return any(abs(center_y - slider_y) <= 260 for slider_y in slider_centers)

def walk(node):
    if not isinstance(node, dict):
        return
    yield node
    for child in node.get("children", []):
        yield from walk(child)

if mode in ("search-clear", "search-submit"):
    for node in walk(data):
        children = node.get("children", [])
        for index, child in enumerate(children):
            if child.get("attributes", {}).get("type") != "TextInput":
                continue
            candidates = []
            for sibling in children[index + 1:]:
                attrs = sibling.get("attributes", {})
                if attrs.get("type") == "Button" and attrs.get("visible") == "true":
                    candidates.append(attrs)
            # The current search page exposes clear and submit as two
            # unlabeled buttons after the TextInput. Clear is first; submit is
            # last. Resolve either semantic action from that structure.
            if candidates:
                print(*bounds(candidates[0 if mode == "search-clear" else -1]))
                raise SystemExit(0)
    raise SystemExit("search clear/submit button not found")

if mode == "search-input":
    for node in walk(data):
        attrs = node.get("attributes", {})
        if attrs.get("type") == "TextInput":
            print(*bounds(attrs))
            raise SystemExit(0)
    raise SystemExit("search input not found")

if mode == "home-search":
    # On some OHOS orientations the home search bar is exported as one
    # clickable Text node with bounds covering the whole XComponent. Its
    # clipboard/account child views still expose the real top-row geometry;
    # derive the search hit area from those children instead of using a fixed
    # screen coordinate.
    for node in walk(data):
        attrs = node.get("attributes", {})
        text = attrs.get("text") or attrs.get("originalText") or ""
        if "搜索" not in text:
            continue
        child_rects = []
        for child in node.get("children", []):
            child_attrs = child.get("attributes", {})
            try:
                x, y, raw = bounds(child_attrs)
                match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
                x1, y1, x2, y2 = map(int, match.groups())
            except (ValueError, TypeError, AttributeError):
                continue
            if (child_attrs.get("visible") != "false" and
                    child_attrs.get("clickable") == "true" and y2 <= 320):
                child_rects.append((x1, y1, x2, y2))
        if child_rects:
            right_edge = min(rect[0] for rect in child_rects)
            top = min(rect[1] for rect in child_rects)
            bottom = max(rect[3] for rect in child_rects)
            print(right_edge // 2, (top + bottom) // 2,
                  f"[0,{top}][{right_edge},{bottom}]")
            raise SystemExit(0)
        # Some dumps expose the search affordance itself as the only
        # clickable node, without exporting its internal children.  Accept
        # that semantic node when its bounds are a small, top-area control;
        # never fall back to a page-sized XComponent/container.
        if (attrs.get("clickable") == "true" and
                attrs.get("visible") != "false"):
            try:
                x, y, raw = bounds(attrs)
                match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
                x1, y1, x2, y2 = map(int, match.groups())
            except (ValueError, TypeError, AttributeError):
                continue
            if (x2 - x1 <= 500 and y2 - y1 <= 300 and y1 < 600):
                print(x, y, raw)
                raise SystemExit(0)
    raise SystemExit("home search control not found")

if mode == "first-video":
    found = []
    fallback_surfaces = []
    sort_labels = {"默认排序", "播放多", "新发布", "弹幕多", "收藏多"}
    for node in walk(data):
        attrs = node.get("attributes", {})
        text = attrs.get("text") or attrs.get("originalText") or ""
        if ("XComponent" in attrs.get("type", "") or
                "Surface" in attrs.get("type", "")):
            try:
                x, y, raw = bounds(attrs)
                if attrs.get("visible") != "false" and x > 0 and y > 0:
                    fallback_surfaces.append((-(x * y), x, y, raw))
            except ValueError:
                pass
        if attrs.get("clickable") != "true" or "播放" not in text:
            continue
        try:
            x, y, raw = bounds(attrs)
            match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
            x1, y1, x2, y2 = map(int, match.groups())
        except ValueError:
            continue
        # The sort-strip label "播放多" is also clickable and precedes every
        # result card.  It must never satisfy a video-card lookup: tapping it
        # changes the query to order=click and invalidates the re-entry
        # experiment.  A result card is a tall hit target below the sort row.
        if text.strip() not in sort_labels and y1 >= 560 and y2 - y1 >= 180:
            found.append((y, x, y, raw))
    if not found:
        # A successful search can immediately restore the native player in
        # fullscreen.  In that state the Flutter result labels are not
        # exported, but a large visible XComponent plus a playback Slider is
        # still a semantic video target.  Return its center so the caller can
        # wake the controls and continue with the normal state checks.
        has_slider = any(
            node.get("attributes", {}).get("type") == "Slider"
            for node in walk(data)
        )
        if has_slider and fallback_surfaces:
            _, x, y, raw = sorted(fallback_surfaces)[0]
            print(x, y, raw)
            raise SystemExit(0)
        raise SystemExit("video result not found")
    print(*sorted(found)[0][1:])
    raise SystemExit(0)

if mode == "video-seek-start":
    for node in walk(data):
        attrs = node.get("attributes", {})
        if attrs.get("type") != "Slider" or attrs.get("visible") == "false":
            continue
        raw = attrs.get("bounds", "")
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
        if not match:
            continue
        x1, y1, x2, y2 = map(int, match.groups())
        # Use the current progress bar, not a screen coordinate. A small
        # inset avoids the rounded endpoint while still seeking to the first
        # frame of the source.
        print(x1 + 5, (y1 + y2) // 2, raw)
        raise SystemExit(0)
    raise SystemExit("playback slider not found")

if mode in ("video-center", "video-wake"):
    candidates = []
    sliders = []
    for node in walk(data):
        attrs = node.get("attributes", {})
        node_type = attrs.get("type", "")
        if node_type == "Slider" and attrs.get("visible") != "false":
            try:
                sliders.append(bounds(attrs))
            except ValueError:
                pass
        if "XComponent" not in node_type and "Surface" not in node_type:
            continue
        try:
            x, y, raw = bounds(attrs)
        except ValueError:
            continue
        if attrs.get("visible") != "false" and x > 0 and y > 0:
            # The page exposes both the Flutter wrapper and the native video
            # XComponent.  The wrapper is often larger and transparent; use
            # the black native surface first so wake taps stay inside the
            # actual video in portrait mode.
            is_native_video = attrs.get("backgroundColor") == "#FF000000"
            candidates.append((not is_native_video, -(x * y), x, y, raw))
    if not candidates:
        raise SystemExit("video surface not found")
    _, _, center_x, center_y, raw = sorted(candidates)[0]
    # OHOS UI dump may expose the XComponent wrapper as the whole page even
    # though the actual video is only the area above its progress Slider.
    # Use that slider's top edge as the video bottom to avoid tapping details
    # content below the player and missing the transient control bar.
    if sliders:
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
        x1, y1, x2, y2 = map(int, match.groups())
        slider_top = min(
            int(re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", item[2]).group(2))
            for item in sliders
        )
        center_x = (x1 + x2) // 2
        center_y = (y1 + min(slider_top, y2)) // 2
        raw = f"[{x1},{y1}][{x2},{slider_top}]"
        if mode == "video-wake":
            # The native XComponent can consume taps in the picture while
            # the Flutter control layer remains reachable at the lower edge.
            center_y = min(slider_top - 20, y2 - 20)
            center_y = max(y1 + 20, center_y)
    print(center_x, center_y, raw)
    raise SystemExit(0)

if mode == "controls-present":
    # A control-bar wake is only valid when the layout exposes a player
    # control, not merely a video surface.  This is deliberately a
    # conservative gate: a missing control must stop the test before any
    # fullscreen tap is attempted.
    patterns = re.compile(r"全屏|fullscreen|full.?screen", re.IGNORECASE)
    slider_centers = []
    for node in walk(data):
        attrs = node.get("attributes", {})
        if attrs.get("type") == "Slider" and attrs.get("visible") != "false":
            try:
                slider_centers.append(bounds(attrs)[1])
            except ValueError:
                pass
    for node in walk(data):
        attrs = node.get("attributes", {})
        if not is_current_control_target(attrs, slider_centers):
            continue
        if attrs.get("type") == "Slider":
            print("slider")
            raise SystemExit(0)
        if attrs.get("clickable") == "false":
            continue
        searchable = " ".join(
            str(attrs.get(key, ""))
            for key in ("text", "originalText", "description", "id", "resourceId")
        )
        if patterns.search(searchable):
            print("semantic-control")
            raise SystemExit(0)
    raise SystemExit("video controls not exposed")

if mode in ("fullscreen-label", "fullscreen-label-painted"):
    target_identifier = "pl-player-fullscreen-toggle"
    target_labels = {"全屏", "退出全屏", "进入全屏"}
    allow_opacity_zero = mode == "fullscreen-label"
    slider_centers = []
    for node in walk(data):
        attrs = node.get("attributes", {})
        if attrs.get("type") == "Slider" and attrs.get("visible") != "false":
            try:
                slider_centers.append(bounds(attrs)[1])
            except ValueError:
                pass
    found = []
    for node in walk(data):
        attrs = node.get("attributes", {})
        identifier = next(
            (
                str(attrs.get(key, ""))
                for key in ("id", "resourceId", "key", "accessibilityId")
                if attrs.get(key)
            ),
            "",
        )
        labels = {
            str(attrs.get(key, "")).strip()
            for key in (
                "text",
                "originalText",
                "description",
                "contentDescription",
                "accessibilityText",
            )
            if attrs.get(key)
        }
        if target_identifier not in identifier and not labels.intersection(target_labels):
            continue
        if attrs.get("clickable") != "true":
            continue
        if allow_opacity_zero:
            target_visible = is_current_control_target(attrs, slider_centers)
        else:
            target_visible = is_painted_visible(attrs)
        if not target_visible:
            continue
        labels = labels.intersection(target_labels)
        if labels:
            found.append(next(iter(labels)))
    if len(found) != 1:
        raise SystemExit(f"fullscreen button label not found uniquely: matches={len(found)}")
    print(found[0])
    raise SystemExit(0)

if mode in ("fullscreen-button", "fullscreen-button-fresh"):
    found = []
    target_identifier = "pl-player-fullscreen-toggle"
    target_labels = {"全屏", "退出全屏", "进入全屏"}
    allow_opacity_zero = mode == "fullscreen-button-fresh"
    slider_centers = []
    for node in walk(data):
        attrs = node.get("attributes", {})
        if attrs.get("type") == "Slider" and attrs.get("visible") != "false":
            try:
                slider_centers.append(bounds(attrs)[1])
            except ValueError:
                pass
    for node in walk(data):
        attrs = node.get("attributes", {})
        identifier = next(
            (
                str(attrs.get(key, ""))
                for key in ("id", "resourceId", "key", "accessibilityId")
                if attrs.get(key)
            ),
            "",
        )
        labels = {
            str(attrs.get(key, "")).strip()
            for key in (
                "text",
                "originalText",
                "description",
                "contentDescription",
                "accessibilityText",
            )
            if attrs.get(key)
        }
        if target_identifier not in identifier and not labels.intersection(target_labels):
            continue
        if attrs.get("clickable") != "true":
            continue
        if allow_opacity_zero:
            target_visible = is_current_control_target(attrs, slider_centers)
        else:
            target_visible = is_painted_visible(attrs)
        if not target_visible:
            continue
        try:
            x, y, raw = bounds(attrs)
        except ValueError:
            continue
        found.append((x, y, raw, identifier or ",".join(sorted(labels))))
    if len(found) != 1:
        raise SystemExit(
            "fullscreen button not found uniquely: "
            f"matches={len(found)}"
        )
    print(*found[0][:3])
    raise SystemExit(0)

raise SystemExit(f"unknown mode: {mode}")

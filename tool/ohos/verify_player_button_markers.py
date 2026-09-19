#!/usr/bin/env python3
"""Fail-closed marker verifier for one fullscreen raw-input trial.

The trial script owns capture and input.  This helper only decides whether a
byte range of its append-only root Hilog proves the four ordered Flutter
markers and, where the active rendering topology exposes it, the paired HCPP
input sequence for the same action identity. Texture/SDR actions deliberately
use Flutter marker evidence only: there is no HCPP attachment to invent.
"""

import argparse
import re
import sys


def observe(
    path: str,
    offset: int,
    expected: str,
    pid: str,
    view_id: str,
    epoch: str,
    consumed: int,
    input_channel: str = "hcpp",
) -> tuple[int, str, int]:
    with open(path, "rb") as source:
        source.seek(offset)
        raw = source.read()
    text = raw.decode("utf-8", errors="replace")
    target = "true" if expected == "enter" else "false"
    line = r"(?m)^[^\n]*\b" + re.escape(pid) + r"\b[^\n]*"
    patterns = [
        line
        + r"PlayerTouchTrace.*fullscreen-button pointer-down\b.*\bviewId="
        + re.escape(view_id)
        + r"\b",
        line
        + r"PlayerTouchTrace.*fullscreen-button pointer-up\b.*\bviewId="
        + re.escape(view_id)
        + r"\b",
        line
        + r"PlayerTouchTrace.*fullscreen-button callback target="
        + re.escape(target),
        line + r"FullscreenTrace.*trigger status=" + re.escape(target),
    ]
    matches = [re.search(pattern, text) for pattern in patterns]
    if not all(matches) or [item.start() for item in matches] != sorted(
        item.start() for item in matches
    ):
        raise ValueError("missing or unordered Flutter markers")

    request_end = offset + len(
        text[: matches[-1].end()].encode("utf-8", errors="replace")
    )
    if request_end <= consumed:
        raise ValueError("marker set was already consumed")

    if input_channel == "flutter":
        # Use explicit sentinels, rather than empty tab fields: Bash `read`
        # collapses leading IFS whitespace and would otherwise lose the
        # consumed end offset needed to prevent cross-action reuse.
        return "none", "none", request_end

    epoch_pattern = re.escape(epoch) if epoch != "unknown" else r"(\d+)"
    down = re.search(
        r"hcpp_input stage=owner route=input seq=(\d+) epoch="
        + epoch_pattern
        + r".*TouchType=Down",
        text,
    )
    if not down:
        raise ValueError("missing HCPP down in action window")
    sequence = int(down.group(1))
    hcpp_epoch = epoch if epoch != "unknown" else down.group(2)
    up = re.search(
        r"hcpp_input stage=owner route=input seq="
        + str(sequence + 1)
        + r" epoch="
        + re.escape(hcpp_epoch)
        + r".*TouchType=Up",
        text[down.end() :],
    )
    if not up:
        raise ValueError("missing paired HCPP up in action window")
    return sequence, hcpp_epoch, request_end


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hilog", required=True)
    parser.add_argument("--offset", required=True, type=int)
    parser.add_argument("--expected", choices=("enter", "exit"), required=True)
    parser.add_argument("--pid", required=True)
    parser.add_argument("--view-id", required=True)
    parser.add_argument("--epoch", required=True)
    parser.add_argument("--consumed-before", required=True, type=int)
    parser.add_argument("--input-channel", choices=("hcpp", "flutter"), default="hcpp")
    args = parser.parse_args()
    try:
        sequence, epoch, marker_end = observe(
            args.hilog,
            args.offset,
            args.expected,
            args.pid,
            args.view_id,
            args.epoch,
            args.consumed_before,
            args.input_channel,
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"{sequence}\t{epoch}\t{marker_end}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

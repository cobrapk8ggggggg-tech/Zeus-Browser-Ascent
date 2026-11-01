#!/usr/bin/env python3
"""Turn a simulator test log into parity evidence.

Greps xcodebuild output for the comic translation test cases that map to the
Ascent parity checklist, verifies the core pipeline tests actually passed,
and writes evidence.json used by parity_report.py. Fails loudly when a core
test is absent or failed — the parity score must never lean on absent proof.
"""
import json
import re
import sys
from pathlib import Path

# Core proof tests: the pipeline end to end plus Arabic lettering/contrast.
CORE = [
    "testActualWebKitSwapRestoreAndStaleResults",
    "testArabicLetteringChangesActualPixelsInsideTheBalloon",
    "testArabicCoreTextFitsAndColorIsValidated",
    "testActualLocalOCRReadsRasterText",
    "testContextWindowCacheSeparatesOwnedSpeechSubsets",
    "testInteriorSamplingRejectsDarkBalloonOutline",
    "testEndToEndImagesDoNotTranslateDOMAndFontChangesReuseOCRAndProvider",
]
PADDLE = "testActualPinnedPaddleModelReadsRasterText"
END_TO_END = "testEndToEndImagesDoNotTranslateDOMAndFontChangesReuseOCRAndProvider"


def main(log_path, out_path):
    text = Path(log_path).read_text(errors="replace") if Path(log_path).exists() else ""
    # Xcode 26.x: Test Case '-[ZEUSNextTests.NativeComicTranslationTests name]' passed (1.2 seconds).
    tests = re.findall(r"Test Case '-\[ZEUSNextTests\.NativeComicTranslationTests (\w+)\]' (passed|failed)", text)
    if not tests:
        # Older format: Test Case 'NativeComicTranslationTests/name' passed.
        tests = re.findall(r"Test Case 'NativeComicTranslationTests/(\w+)' (passed|failed)", text)
    passed = {name for name, verdict in tests if verdict == "passed"}
    failed = {name for name, verdict in tests if verdict == "failed"}
    missing = [name for name in CORE if name not in passed and name not in failed]
    if missing:
        raise SystemExit(f"core tests absent from the log (never ran): {missing}")
    if failed:
        raise SystemExit(f"core pipeline tests failed: {sorted(failed)}")
    evidence = {
        "passed_tests": ["simulator"],
        "core_passed": CORE + ([PADDLE] if PADDLE in passed else []),
        "end_to_end_webkit": END_TO_END in passed,
        "total_test_cases": len(tests),
    }
    Path(out_path).write_text(json.dumps(evidence, ensure_ascii=False, indent=1))
    print(f"evidence: {len(passed)} passed / {len(failed)} failed / {len(tests)} total")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

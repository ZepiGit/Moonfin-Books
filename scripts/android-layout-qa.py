#!/usr/bin/env python3
"""Android layout QA on a disposable emulator.

Installs a public release APK, launches it and reproduces the reported
phone problem: the Add-server dialog and URL field are too small in
portrait, and the custom TV keyboard appears instead of the system IME.
Evidence (screenshots, UI dumps, logcat, JSON findings) is written to
qa-evidence/ so a broken release can still be uploaded. No server login
is performed. Standard library only.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


PACKAGES = {
    "mobile": "art.tiedemann.moonfin",
    "tv-stable": "art.tiedemann.moonfin.tv",
}
READABLE_FIELD_DP = 200


class AdbError(RuntimeError):
    pass


class Adb:
    def __init__(self, serial=None):
        self.serial = serial

    def run(self, *args, check=True, timeout=60):
        cmd = ["adb"]
        if self.serial:
            cmd += ["-s", self.serial]
        cmd += list(args)
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        if check and proc.returncode != 0:
            raise AdbError(f"{cmd[0]} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc.stdout

    def run_output(self, out_path, *args, check=True):
        cmd = ["adb"]
        if self.serial:
            cmd += ["-s", self.serial]
        cmd += list(args)
        with open(out_path, "wb") as fh:
            proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.PIPE, timeout=60)
        if check and proc.returncode != 0:
            raise AdbError(f"{cmd[0]} failed: {proc.stderr.decode(errors='replace')}")

    def shell(self, command, check=True):
        return self.run("shell", command, check=check)


def dump_ui(adb, path):
    """Dump the current UI hierarchy and return the parsed root."""
    remote = "/sdcard/moonfin-books-layout-qa.xml"
    for _ in range(3):
        adb.shell(f"rm -f {remote}")
        adb.shell(f"uiautomator dump {remote}", check=False)
        adb.run_output(path, "exec-out", "cat", remote, check=False)
        try:
            return ET.parse(path).getroot()
        except ET.ParseError:
            time.sleep(2)
    raise AdbError("UI hierarchy unavailable after three fresh dumps")


def parse_bounds(text):
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", text or "")
    if not match:
        return None
    left, top, right, bottom = (int(part) for part in match.groups())
    if right <= left or bottom <= top:
        return None
    return {
        "left": left,
        "top": top,
        "right": right,
        "bottom": bottom,
        "width_px": right - left,
        "height_px": bottom - top,
        "center_x": (left + right) // 2,
        "center_y": (top + bottom) // 2,
    }


def find_nodes(root, attr, value):
    if root is None:
        return []
    return [node for node in root.iter() if node.get(attr) == value]


def find_clickable_with_text(root, texts):
    """Find the clickable node whose own or child text matches."""
    if root is None:
        return []
    wanted = [text.casefold() for text in texts]
    hits = []
    for node in root.iter():
        if node.get("clickable") != "true":
            continue
        labels = [node.get("text", ""), node.get("content-desc", "")]
        labels += [child.get("text", "") for child in node.iter() if child is not node]
        if any(label and any(w in label.casefold() for w in wanted) for label in labels):
            bounds = parse_bounds(node.get("bounds"))
            if bounds:
                hits.append({"node": node, "bounds": bounds})
    return hits


def find_edit_fields(root):
    if root is None:
        return []
    fields = []
    for node in root.iter():
        if node.get("class") not in ("android.widget.EditText", "android.widget.AutoCompleteTextView"):
            continue
        bounds = parse_bounds(node.get("bounds"))
        if bounds:
            fields.append({"node": node, "bounds": bounds})
    return fields


def tap(adb, bounds):
    adb.shell(f"input tap {bounds['center_x']} {bounds['center_y']}")


def screen_metrics(adb):
    wm = adb.shell("wm size")
    density = adb.shell("wm density")
    sizes = re.findall(r"(?:Physical|Override) size: (\d+)x(\d+)", wm)
    densities = re.findall(r"(?:Physical|Override) density: (\d+)", density)
    if not sizes or not densities:
        raise AdbError(f"unreadable display metrics: {wm!r} / {density!r}")
    density_value = int(densities[-1])
    width_px, height_px = map(int, sizes[-1])
    return {
        "width_px": width_px,
        "height_px": height_px,
        "density_dpi": density_value,
        "width_dp": round(width_px * 160 / density_value),
        "height_dp": round(height_px * 160 / density_value),
        "raw": {"wm_size": wm.strip(), "wm_density": density.strip()},
    }


def save_screenshot(adb, path):
    adb.run_output(path, "exec-out", "screencap", "-p")


def keyboard_is_custom_ui(root, package):
    """Detect the app's CustomTVTextField on-screen keyboard.

    The custom keyboard renders one tappable chip per key whose
    accessibility label is the key legend, including the sentinel words
    SPACE, BACKSPACE, SHIFT, DONE, IME, PASTE, CURSORL and CURSORR. A
    native IME draws in its own window and never produces this exact
    in-app signature.
    """
    if root is None:
        return False, 0
    key_count = 0
    sentinel_count = 0
    sentinel_words = {
        "space", "backspace", "shift", "done", "ime", "paste",
        "cursorl", "cursorr",
    }
    for node in root.iter():
        if node.get("clickable") != "true" or node.get("package") != package:
            continue
        text = (node.get("text") or node.get("content-desc") or "").strip()
        if not text:
            continue
        folded = text.casefold()
        if folded in sentinel_words:
            sentinel_count += 1
            key_count += 1
        elif re.fullmatch(r"[a-z0-9]", folded) or text in ("ABC", "123"):
            key_count += 1
    return key_count >= 15, key_count


def system_ime_present(adb):
    state = adb.shell("dumpsys input_method")
    shown = bool(re.search(r"(?:mInputShown|isInputViewShown|mIsInputViewShown)=true", state))
    return shown, state


def check_crash(adb, package, evidence_dir):
    adb.run_output(
        os.path.join(evidence_dir, "logcat-crash.txt"),
        "logcat", "-b", "crash", "-d", check=False,
    )
    adb.run_output(
        os.path.join(evidence_dir, "logcat-main.txt"),
        "logcat", "-b", "main", "-b", "system", "-d", check=False,
    )
    crash_path = os.path.join(evidence_dir, "logcat-crash.txt")
    try:
        with open(crash_path, encoding="utf-8", errors="replace") as fh:
            crash_text = fh.read()
    except OSError:
        crash_text = ""
    with open(os.path.join(evidence_dir, "logcat-main.txt"), errors="replace") as fh:
        main_text = fh.read()
    crashed = bool(re.search(r"FATAL EXCEPTION|Fatal signal", crash_text)) or f"ANR in {package}" in main_text
    return crashed, crash_text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--package-choice", choices=sorted(PACKAGES), required=True,
        help="mobile or tv-stable APK under test",
    )
    parser.add_argument(
        "--observe-only", action="store_true",
        help="record findings but always exit 0 so evidence uploads from a broken release",
    )
    parser.add_argument("--evidence-dir", default="qa-evidence")
    parser.add_argument("--boot-timeout", type=int, default=300)
    args = parser.parse_args()

    package = PACKAGES[args.package_choice]
    evidence_dir = args.evidence_dir
    os.makedirs(evidence_dir, exist_ok=True)
    adb = Adb()

    findings = []

    def fail(message):
        findings.append({"severity": "fail", "check": message})

    def note(message):
        findings.append({"severity": "info", "check": message})

    adb.run("wait-for-device", timeout=args.boot_timeout)
    deadline = time.time() + args.boot_timeout
    while time.time() < deadline:
        boot = adb.shell("getprop sys.boot_completed", check=False).strip()
        if boot == "1":
            break
        time.sleep(5)
    else:
        raise AdbError("emulator did not finish booting")

    metrics = screen_metrics(adb)
    note(f"display: {metrics['width_dp']}dp x {metrics['height_dp']}dp at {metrics['density_dpi']}dpi")

    apk_dir = "apk" if os.path.isdir("apk") else "."
    apks = sorted(
        name for name in os.listdir(apk_dir)
        if name.endswith(".apk")
    )
    if len(apks) != 1:
        raise AdbError(f"expected exactly one APK in {apk_dir}/, found {apks}")
    apk_path = os.path.join(apk_dir, apks[0])
    note(f"apk: {apk_path}")

    adb.run("install", "-r", "-g", apk_path, timeout=300)
    component = adb.shell(
        f"cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER {package}"
    ).strip().splitlines()[-1].strip()
    if "/" not in component:
        raise AdbError(f"launcher activity missing for {package}")
    note(f"component: {component}")
    adb.shell("settings put secure show_ime_with_hard_keyboard 1")
    adb.shell("settings put system accelerometer_rotation 0")
    adb.shell("settings put system user_rotation 0")
    adb.shell("input keyevent KEYCODE_WAKEUP")
    adb.shell("wm dismiss-keyguard")

    adb.shell("logcat -c")
    adb.shell(f"am start -W -n {component}")
    time.sleep(15)
    pid = adb.shell(f"pidof -s {package}", check=False).strip()
    if not pid:
        fail("app process exited after startup")

    startup_root = dump_ui(adb, os.path.join(evidence_dir, "ui-startup.xml"))
    labels = " ".join(n.get("text", "") for n in startup_root.iter())
    if "Pixel Launcher" in labels and "isn't responding" in labels:
        save_screenshot(adb, os.path.join(evidence_dir, "launcher-anr.png"))
        buttons = find_clickable_with_text(startup_root, ["close app"])
        if not buttons:
            raise AdbError("Launcher ANR blocks app and cannot be dismissed")
        tap(adb, buttons[0]["bounds"])
        adb.shell(f"am start -W -n {component}")
        time.sleep(5)
        startup_root = dump_ui(adb, os.path.join(evidence_dir, "ui-startup.xml"))
        note("Dismissed unrelated Pixel Launcher ANR before measuring app")
    save_screenshot(adb, os.path.join(evidence_dir, "startup.png"))
    startup_nodes = find_clickable_with_text(startup_root, ["add server"])
    if not startup_nodes:
        adb.shell(f"input swipe {metrics['width_px']//2} {metrics['height_px']*3//4} {metrics['width_px']//2} {metrics['height_px']//3} 400")
        time.sleep(2)
        startup_root = dump_ui(adb, os.path.join(evidence_dir, "ui-startup-retry.xml"))
        startup_nodes = find_clickable_with_text(startup_root, ["add server"])
    if not startup_nodes:
        fail("Add server control not found on the startup screen")
        add_node = None
    else:
        add_node = startup_nodes[0]
        note(
            "Add server bounds: "
            + json.dumps(startup_nodes[0]["bounds"], sort_keys=True)
        )
        tap(adb, add_node["bounds"])
        time.sleep(5)

    dialog_root = dump_ui(adb, os.path.join(evidence_dir, "ui-dialog.xml"))
    save_screenshot(adb, os.path.join(evidence_dir, "dialog.png"))
    fields = [f for f in find_edit_fields(dialog_root) if f['node'].get('package') == package]
    if not fields:
        fail("no editable URL field found in the Add server dialog")
    else:
        field = fields[0]
        width_dp = round(
            field["bounds"]["width_px"] * 160 / metrics["density_dpi"]
        )
        height_dp = round(
            field["bounds"]["height_px"] * 160 / metrics["density_dpi"]
        )
        note(
            "URL field bounds (px): "
            + json.dumps(field["bounds"], sort_keys=True)
        )
        note(f"URL field width: {width_dp}dp, height: {height_dp}dp")
        if width_dp < READABLE_FIELD_DP:
            fail(
                f"URL field is only {width_dp}dp wide "
                f"(< {READABLE_FIELD_DP}dp readable minimum) on a "
                f"{metrics['width_dp']}dp-wide phone display"
            )
        if height_dp < 24:
            fail(f"URL field is only {height_dp}dp tall")
        tap(adb, field["bounds"])
        time.sleep(5)
    if args.package_choice == 'tv-stable':
        adb.shell("input keyevent KEYCODE_DPAD_CENTER")
        time.sleep(2)

    keyboard_root = dump_ui(adb, os.path.join(evidence_dir, "ui-keyboard.xml"))
    save_screenshot(adb, os.path.join(evidence_dir, "keyboard.png"))
    is_custom, key_count = keyboard_is_custom_ui(keyboard_root, package)
    ime_present, ime_state = system_ime_present(adb)
    with open(os.path.join(evidence_dir, 'input-method.txt'), 'w') as fh:
        fh.write(ime_state)
    note(f"system IME visible: {ime_present}")
    note(f"custom-style key nodes in app dump: {key_count}")
    if is_custom:
        fail(
            "custom TV keyboard rendered on phone mobile package "
            f"({key_count} key nodes) instead of the system IME"
        )
    if not ime_present:
        fail("system input method is not visible after focusing the URL field")

    crashed, crash_text = check_crash(adb, package, evidence_dir)
    if crashed:
        fail("app crashed during layout QA (see logcat-crash.txt)")

    result = {
        "package": package,
        "package_choice": args.package_choice,
        "apk_path": apk_path,
        "display": metrics,
        "findings": findings,
        "observe_only": args.observe_only,
        "add_server_found": add_node is not None,
        "url_field_width_dp": (
            round(fields[0]["bounds"]["width_px"] * 160 / metrics["density_dpi"])
            if fields else None
        ),
        "custom_keyboard_detected": is_custom,
        "system_ime_present": ime_present,
        "app_crashed": bool(crashed),
    }
    result_path = os.path.join(evidence_dir, "result.json")
    with open(result_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, sort_keys=True)
        fh.write("\n")

    failures = [item for item in findings if item["severity"] == "fail"]
    print(f"layout QA: {len(failures)} failure(s), {len(findings)} total finding(s)")
    for item in findings:
        prefix = "FAIL" if item["severity"] == "fail" else "info"
        print(f"  [{prefix}] {item['check']}")
    if failures and not args.observe_only:
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        os.makedirs('qa-evidence', exist_ok=True)
        with open('qa-evidence/result.json', 'w') as fh:
            json.dump({'status': 'harness_error', 'error': str(error)}, fh, indent=2)
        raise

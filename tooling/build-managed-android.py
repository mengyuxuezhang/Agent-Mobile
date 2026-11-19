"""Build a branded APK using a YushuHub project export."""

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from build_number import build_number
from urllib.parse import urlsplit


def brand_inputs(config):
    if not isinstance(config, dict):
        raise ValueError("Expected a JSON object in the YushuHub project export")
    project = config.get("projectId")
    name = config.get("appName")
    api = config.get("clientApiUrl")
    color = config.get("themeColor")
    if config.get("schema") != "agent-mobile-build-v1":
        raise ValueError("Expected a YushuHub Android project export")
    if not isinstance(project, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", project):
        raise ValueError("Invalid project ID")
    if not isinstance(name, str) or not name.strip() or len(name) > 80 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Invalid application name")
    if not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
        raise ValueError("Invalid brand color")
    url = urlsplit(api if isinstance(api, str) else "")
    if url.scheme != "https" or not url.hostname or url.username is not None or url.query or url.fragment:
        raise ValueError("The project requires an HTTPS client API address")
    if not url.path.rstrip("/").endswith("/api"):
        raise ValueError("The client API address must end in /api/")
    application_id = "cn.mengyunet.agent.mobile.p_" + project.replace("-", "_")
    return {
        "AGENT_PROJECT_ID": project,
        "AGENT_APP_NAME": name.strip(),
        "AGENT_API_BASE_URL": api.rstrip("/") + "/",
        "AGENT_UPDATE_FEED": api.rstrip("/") + f"/client/android-download/{project}/update.json",
        "AGENT_BRAND_PRIMARY": color,
        "AGENT_ANDROID_APPLICATION_ID": application_id,
    }


@contextmanager
def staged_icon(root, icon, temporary, defines):
    if icon is None:
        yield
        return
    data = icon.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or not 32 <= len(data) <= 4 * 1024 * 1024:
        raise ValueError("The project icon must be a PNG of at most 4 MiB")
    flutter_asset = root / "app/assets/managed-brand/icon.png"
    with flutter_asset.open("xb") as output:
        output.write(data)
    try:
        resources = temporary / "android-res"
        drawable = resources / "drawable-nodpi"
        drawable.mkdir(parents=True)
        (drawable / "managed_brand_icon.png").write_bytes(data)
        mipmap = resources / "mipmap-anydpi"
        mipmap.mkdir()
        base = root / "app/android/app/src/main/res/mipmap-anydpi"
        for icon_res in base.glob("ic_launcher*.xml"):
            (mipmap / icon_res.name).write_text(
                '<bitmap xmlns:android="http://schemas.android.com/apk/res/android" '
                'android:src="@drawable/managed_brand_icon" android:gravity="fill" />',
                encoding="utf-8",
            )
        defines["AGENT_BRAND_ICON"] = "true"
        defines["AGENT_ANDROID_ICON_RES"] = str(resources)
        yield
    finally:
        flutter_asset.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--abi", choices=("arm64", "x64"), default="arm64")
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--icon", type=Path, help="prepared PNG from the project brand")
    parser.add_argument("--check", action="store_true", help="validate the export without building")
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    args = parser.parse_args()
    defines = brand_inputs(json.loads(args.config.read_text(encoding="utf-8-sig")))
    if args.check:
        print(json.dumps({"projectId": defines["AGENT_PROJECT_ID"], "applicationId":
                          defines["AGENT_ANDROID_APPLICATION_ID"]}))
        return
    if not args.flutter:
        parser.error("Flutter is required")
    root = Path(__file__).resolve().parent.parent
    subprocess.run([sys.executable,
                    str(root / "tooling/check_runtime_bundle.py"), args.abi], cwd=root, check=True)
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("Version must use major.minor.patch")
    version_code = build_number()
    defines["DSH_APP_VERSION"] = f"{args.version}+{version_code}"
    mode = "release" if args.release else "debug"
    if args.release:
        defines["AGENT_ANDROID_REQUIRE_SIGNING"] = "true"
    with tempfile.TemporaryDirectory(prefix="agent-mobile-brand-") as tmp:
        temporary = Path(tmp)
        with staged_icon(root, args.icon, temporary, defines):
            path = temporary / "brand.json"
            path.write_text(json.dumps(defines, ensure_ascii=False), encoding="utf-8")
            platform = "android-x64" if args.abi == "x64" else "android-arm64"
            subprocess.run(
                [args.flutter, "build", "apk", f"--{mode}",
                 "--flavor", args.abi, "--target-platform", platform, "--build-name", args.version,
                 "--build-number", str(version_code),
                 f"--dart-define-from-file={path}"],
                cwd=root / "app", check=True,
            )
    metadata = root / "app/build/app/outputs/apk" / args.abi / mode / "output-metadata.json"
    if json.loads(metadata.read_text(encoding="utf-8"))["applicationId"] != defines["AGENT_ANDROID_APPLICATION_ID"]:
        raise RuntimeError("APK package does not match the exported project configuration")


if __name__ == "__main__":
    main()

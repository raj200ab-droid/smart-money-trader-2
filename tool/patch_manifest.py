"""Make sure the release APK actually has network access.

`flutter create` only puts android.permission.INTERNET in the debug and
profile manifests, so a release build has no network permission at all and
every HTTP call dies with a SocketException. Release builds merge only
android/app/src/main/AndroidManifest.xml, so the permission has to be there.
"""

import pathlib
import sys

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")
PERMISSION = '    <uses-permission android:name="android.permission.INTERNET" />'


def main() -> int:
    if not MANIFEST.is_file():
        print(f"error: {MANIFEST} not found", file=sys.stderr)
        return 1

    xml = MANIFEST.read_text(encoding="utf-8")

    if "android.permission.INTERNET" not in xml:
        if "<application" not in xml:
            print("error: no <application> tag in manifest", file=sys.stderr)
            return 1
        xml = xml.replace("<application", PERMISSION + "\n\n    <application", 1)
        MANIFEST.write_text(xml, encoding="utf-8")
        print("added INTERNET permission to main manifest")
    else:
        print("INTERNET permission already present")

    if "android.permission.INTERNET" not in MANIFEST.read_text(encoding="utf-8"):
        print("error: permission missing after patch", file=sys.stderr)
        return 1

    # Fail loudly if the permission still is not where release builds look.
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if "uses-permission" in line:
            print("  " + line.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())

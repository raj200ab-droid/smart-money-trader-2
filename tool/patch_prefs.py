"""Add the device-storage channel that keeps the Gemini key across restarts.

Why this patch exists instead of a dependency
---------------------------------------------
The Gemini key has to survive an app restart. The usual answer is
`shared_preferences`, but adding it means `flutter pub get` has to fetch a new
package from pub.dev during the release build, and this project has already
been bitten by build-time network steps. The key is one short string, so the
plugin's own storage is replaced by ~40 lines of Kotlin using the same
Android API (`Context.getSharedPreferences` in the app's private sandbox).

The patch is idempotent: it is applied to the `flutter create` scaffolding in
CI, and running it twice is a no-op. It writes:

    MainActivity.kt            -- onCreate installs the channel
    GeminiPrefs.kt             -- the get/set handler

and fails loudly if the generated MainActivity does not look like what it
expects, because silently shipping a build where the key is forgotten would be
worse than failing the build.
"""

import pathlib
import re
import sys

ORG = "com.smartmoney"
APP = "smart_money_trader"
CHANNEL = "com.smartmoney.smart_money_trader/prefs"

PREFS_KT = """package {pkg}

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Minimal string store on top of the app-private SharedPreferences file.
 *
 * This exists so the Gemini API key survives a restart without pulling
 * shared_preferences (and a pub.dev fetch) into the release build. It stores
 * strings only and never logs the values.
 */
class GeminiPrefs(private val context: Context) : MethodChannel.MethodCallHandler {{
    private val prefs =
        context.getSharedPreferences("smart_money_prefs", Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {{
        when (call.method) {{
            "getString" -> {{
                val key = call.argument<String>("key")
                if (key == null) {{
                    result.error("bad_args", "key missing", null)
                }} else {{
                    result.success(prefs.getString(key, "") ?: "")
                }}
            }}
            "setString" -> {{
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key == null || value == null) {{
                    result.error("bad_args", "key/value missing", null)
                }} else {{
                    prefs.edit().putString(key, value).apply()
                    result.success(null)
                }}
            }}
            "clear" -> {{
                val key = call.argument<String>("key")
                if (key == null) {{
                    result.error("bad_args", "key missing", null)
                }} else {{
                    prefs.edit().remove(key).apply()
                    result.success(null)
                }}
            }}
            else -> result.notImplemented()
        }}
    }}
}}
"""


def find_main_activity(root: pathlib.Path):
    """Locate the MainActivity that `flutter create` generated for this app.

    Searches the whole repository, not just android/: the path depends on the
    Flutter version (kotlin/ vs java/ source sets both occur) and a wrong guess
    fails the build two minutes later with an unhelpful message.
    """
    hits = sorted(root.rglob("MainActivity.kt")) + sorted(root.rglob("MainActivity.java"))
    return hits[0] if hits else None


def describe_tree(root: pathlib.Path) -> str:
    """Print the files the patch cares about, so a failure explains itself."""
    lines = [f"searching from: {root.resolve()}"]
    for pat in ("**/MainActivity.*", "**/AndroidManifest.xml", "**/build.gradle*"):
        found = sorted(str(p) for p in root.rglob(pat.replace("**/", "")))
        lines.append(f"  {pat}: {len(found)} -> {found[:6]}")
    return "\n".join(lines)


KOTLIN_OVERRIDE = """
    /** Device storage for the Gemini key. See tool/patch_prefs.py. */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "__CHANNEL__"
        ).setMethodCallHandler(GeminiPrefs(applicationContext))
    }
"""

JAVA_OVERRIDE = """
    /** Device storage for the Gemini key. See tool/patch_prefs.py. */
    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(),
            "__CHANNEL__"
        ).setMethodCallHandler(new GeminiPrefs(getApplicationContext()));
    }
"""


def _add_import(text: str, imp: str) -> str:
    """Add an import once, keeping Kotlin/Java import lists together."""
    if imp in text:
        return text
    last = None
    for last in re.finditer(r"^import .*$", text, re.M):
        pass
    if last is not None:
        return text[: last.end()] + "\n" + imp + text[last.end():]
    m = re.search(r"^package .*$", text, re.M)
    if m:
        return text[: m.end()] + "\n\n" + imp + text[m.end():]
    return imp + "\n\n" + text


def patch_main_activity(path: pathlib.Path) -> bool:
    """Install the channel, whatever shape `flutter create` produced.

    The templates differ across Flutter versions in ways that matter:
    `class MainActivity : FlutterActivity()` has no body, while 3.16 emits
    `class MainActivity: FlutterActivity() {` -- no space, body present. An
    earlier version assumed the first form and appended a closing brace to the
    second, producing Kotlin that would not compile. So this matches the class
    declaration with a regex and inserts INTO the body when one exists.
    """
    text = path.read_text(encoding="utf-8")
    if CHANNEL in text:
        print("channel already installed in", path)
        return True  # idempotent: already correct is a success

    if path.suffix == ".kt":
        pat = re.compile(r"class\s+MainActivity\s*:\s*FlutterActivity\s*\(\s*\)\s*(\{)?")
        m = pat.search(text)
        if not m:
            print("::error title=prefs::MainActivity.kt does not look like the "
                  "FlutterActivity template", file=sys.stderr)
            print(text, file=sys.stderr)
            return False
        body = KOTLIN_OVERRIDE.replace("__CHANNEL__", CHANNEL)
        if m.group(1):
            # body already open: insert immediately after the brace
            text = text[: m.end()] + body + text[m.end():]
        else:
            text = text[: m.start()] + (
                "class MainActivity : FlutterActivity() {" + body + "}"
            ) + text[m.end():]
        text = _add_import(text, "import io.flutter.embedding.engine.FlutterEngine")
        text = _add_import(text, "import io.flutter.plugin.common.MethodChannel")
    else:
        pat = re.compile(r"class\s+MainActivity\s+extends\s+FlutterActivity\s*(\{)?")
        m = pat.search(text)
        if not m:
            print("::error title=prefs::MainActivity.java does not look like the "
                  "FlutterActivity template", file=sys.stderr)
            print(text, file=sys.stderr)
            return False
        body = JAVA_OVERRIDE.replace("__CHANNEL__", CHANNEL)
        if m.group(1):
            text = text[: m.end()] + body + text[m.end():]
        else:
            text = text[: m.start()] + (
                "class MainActivity extends FlutterActivity {" + body + "}"
            ) + text[m.end():]
        text = _add_import(text, "import io.flutter.embedding.engine.FlutterEngine")
        text = _add_import(text, "import io.flutter.plugin.common.MethodChannel")
        text = _add_import(text, "import androidx.annotation.NonNull")

    # A missing brace in generated Kotlin is a build failure 2 minutes later
    # with an unhelpful message, so fail here with a useful one.
    if text.count("{") != text.count("}"):
        print(f"::error title=prefs::unbalanced braces ({text.count('{')} open, "
              f"{text.count('}')} close)")
        print(text, file=sys.stderr)
        return False
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")
    print("installed prefs channel in", path)
    return True


def fail(msg: str) -> int:
    """Report a failure twice: stderr for humans, annotation for the API.

    This repository's Actions logs are served from a host that the development
    sandbox cannot reach, so `print(..., file=sys.stderr)` is invisible where
    the fix has to be written. Annotations come back through the API.
    """
    print(f"::error title=prefs::{msg}")
    print(f"error: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    root = pathlib.Path(".")
    print(f"cwd: {pathlib.Path('.').resolve()}")
    print(f"files here: {sorted(p.name for p in pathlib.Path('.').iterdir())[:20]}")
    if not pathlib.Path("android").is_dir():
        return fail("android/ not found -- run after flutter create")
    act = find_main_activity(root)
    if act is None:
        print(describe_tree(root), file=sys.stderr)
        return fail("no MainActivity in tree: " +
                    describe_tree(root).replace("\n", " | "))
    # Package directory is whatever follows the last source root.
    parent = act.parent.as_posix()
    for marker in ("/kotlin/", "/java/"):
        if marker in parent:
            parent = parent.split(marker, 1)[1]
            break
    pkg = parent.replace("/", ".")
    prefs = act.parent / "GeminiPrefs.kt"
    prefs.write_text(PREFS_KT.format(pkg=pkg), encoding="utf-8")
    print(f"package: {pkg}")
    print("wrote", prefs)

    if not patch_main_activity(act):
        return fail(f"could not patch {act}")

    # verify
    if CHANNEL not in act.read_text(encoding="utf-8"):
        return fail("channel not present after patch")
    if not prefs.is_file():
        return fail("GeminiPrefs.kt missing")
    print("verify: channel + handler in place")
    return 0


def _run_with_traceback() -> int:
    """Run main() and leave a full traceback on disk.

    GitHub Actions logs are not always retrievable for this repo, so the script
    writes its own diagnosis next to the log: a step that fails in 0 seconds
    without a readable error is worse than a slow one.
    """
    import traceback

    try:
        return main()
    except SystemExit:
        raise
    except BaseException:
        tb = traceback.format_exc()
        print(tb, file=sys.stderr)
        # Also publish as workflow annotations: this repo's Actions logs live on
        # a host the development sandbox cannot read, so stderr is not enough.
        for line in tb.strip().splitlines():
            safe = line.replace('%', '%25').replace('\r', '').replace('\n', '%0A')
            print(f"::error title=prefs::{safe}")
        try:
            with open("prefs_debug.txt", "w", encoding="utf-8") as f:
                f.write(tb)
                f.write("\n\n--- tree ---\n")
                f.write(describe_tree(pathlib.Path(".")))
        except OSError:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(_run_with_traceback())

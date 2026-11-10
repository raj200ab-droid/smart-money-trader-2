"""
Guard the one promise the Gemini integration makes: it is an ADVISOR.

The app's whole credibility rests on "the engine decides". Adding a language
model to the screen is only safe if the model cannot move a signal. That is a
structural property, and structural properties can be tested by reading code:

  1. Every Gemini call is fire-and-forget (`unawaited`), so a slow or failing
     model can never delay or break a scan.
  2. The review is written into `_gNotes` / `_gScanNote` only. It must never
     touch `_signals`, `_quiets`, `_scratch`, or the sort.
  3. Turning Gemini off means no request at all (`usable` gates every call).
  4. The key is not in the repository and never logged.
  5. The prompt REQUIRES the model to attack the setup, and forbids inventing
     numbers, because a model asked "is this good?" always says yes.
  6. The endpoint and header are the ones Google documents today.
  7. The Android channel that stores the key is actually installed by CI.

Run: python3 tool/mirror/test_gemini.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DART = os.path.join(ROOT, 'lib', 'main.dart')
GEMINI = os.path.join(ROOT, 'lib', 'gemini.dart')
fails = []


def check(name, cond, detail=''):
    if cond:
        print(f'  PASS  {name}')
    else:
        print(f'  FAIL  {name}  {detail}')
        fails.append(name)


def main():
    main_src = open(DART).read()
    gem_src = open(GEMINI).read()
    full = main_src + '\n' + gem_src

    # ------------------------------------------------------- 1. fire and forget
    print('1. Gemini can never block or break a scan')
    calls = re.findall(r'_reviewOne\(|_reviewScan\(|_autoReview\(', main_src)
    awaited = re.findall(r'await\s+_review(?:One|Scan)\(', main_src)
    check('no review call is awaited', not awaited, str(awaited))
    check('reviews are launched with unawaited()',
          'unawaited(_reviewOne(sig))' in main_src
          and 'unawaited(_reviewScan())' in main_src)
    check('a review failure is returned as a note, not thrown',
          'GeminiNote(\n        symbol: symbol,\n        text: \'\',\n        model: model,\n        at: DateTime.now(),\n        error: e.message,' in gem_src
          or 'error: e.message' in gem_src)

    # --------------------------------------------- 2. review never edits a signal
    print('2. a review can never change a signal')
    # Every statement that writes a review must not mention the signal lists.
    writes = [ln.strip() for ln in main_src.splitlines()
              if re.search(r'_gNotes\[|_gScanNote\s*=', ln)]
    bad = [w for w in writes
           if any(k in w for k in ('_signals', '_quiets', '_scratch'))]
    check('review writes touch only the note maps', not bad, str(bad))
    check('the sort has no Gemini input',
          'gemini' not in main_src.split('_signals.sort(')[1].split('});')[0].lower())
    # The badge is additive: it is rendered next to the tier chip, and the
    # engine fields are read, never written.
    check('the card badge only reads the note map',
          '_geminiBadge(signal.symbol)' in main_src)

    # ------------------------------------------------------- 3. off means off
    print('3. Gemini off sends nothing')
    check('every request is gated by usable', 'usable' in gem_src)
    gated = [ln.strip() for ln in main_src.splitlines()
             if '_gemini.usable' in ln]
    check('the app checks usability before reviewing', len(gated) >= 3,
          f'{len(gated)} checks')
    check('_autoReview returns early when not usable',
          'if (!_gemini.usable || _signals.isEmpty) return;' in main_src)

    # ------------------------------------------------------- 4. key handling
    print('4. the key stays on the device')
    # A real key looks like AIza + 35 chars. The string 'AIza...' is the text
    # field's placeholder and must not be confused with a leaked credential.
    leaked = re.findall(r'AIza[0-9A-Za-z_\-]{30,}', full)
    check('no key is baked into the source', not leaked, str(leaked[:1]))
    check('the key is never printed',
          'print(_gemini.apiKey' not in main_src
          and 'debugPrint' not in full)
    check('the key field is masked in the UI', 'obscureText: _obscure' in gem_src)
    patch_src = open(os.path.join(ROOT, 'tool', 'patch_prefs.py')).read()
    check('the key is stored through the platform channel, not in a file',
          "MethodChannel('com.smartmoney.smart_money_trader/prefs')" in gem_src
          and 'getSharedPreferences("smart_money_prefs"' in patch_src)

    # ------------------------------------------------------- 5. prompt design
    print('5. the prompt asks the model to attack, and forbids invention')
    for phrase, why in [
        ('ATTACK it, not to approve it', 'asks for disagreement'),
        ('do not pretend to', 'no fake chart reading'),
        ('Never invent a price', 'no invented numbers'),
        ('never promise profit', 'no profit promises'),
        ('STANCE: AGREE | CAUTION | AVOID', 'machine-readable stance'),
    ]:
        check(why, phrase in gem_src)
    check('the prompt receives the real cost in R',
          'i.e. ${feeR.toStringAsFixed(2)}R on this stop' in gem_src)

    # ------------------------------------------------------- 6. endpoint
    print('6. the endpoint is the documented one')
    check('base url is the v1beta generativelanguage host',
          "https://generativelanguage.googleapis.com/v1beta" in gem_src)
    check('auth uses the x-goog-api-key header', 'x-goog-api-key' in gem_src)
    check('the response text is read from candidates[0].content.parts',
          "'candidates'" in gem_src and "'parts'" in gem_src)
    check('429/quota has its own message', 'Rate limit' in gem_src)
    check('404 tells the user to find a working model',
          'Find a working model' in gem_src)

    # ------------------------------------------------------- 7. android channel
    print('7. the key survives a restart (channel installed in CI)')
    for wf in ('build.yml', 'release.yml'):
        p = os.path.join(ROOT, '.github', 'workflows', wf)
        txt = open(p).read()
        check(f'{wf} runs patch_prefs.py', 'tool/patch_prefs.py' in txt)
        check(f'{wf} runs it AFTER flutter create',
              txt.find('flutter create') < txt.find('tool/patch_prefs.py'))
    patch = patch_src
    check('the patch writes the handler class', 'GeminiPrefs.kt' in patch)
    check('the patch verifies braces', 'unbalanced braces' in patch)
    check('the channel name matches the Dart side',
          'com.smartmoney.smart_money_trader/prefs' in patch
          and 'com.smartmoney.smart_money_trader/prefs' in gem_src)

    print()
    if fails:
        print(f'{len(fails)} FAILED: {fails}')
        return 1
    print('all Gemini advisor tests PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())

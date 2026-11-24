"""
The version is written in two places and only one of them is authoritative.

v17.1.0 shipped an APK named `...-17.0.0-20.apk` because `kVersionName` in
lib/main.dart still held the previous version while pubspec.yaml had moved on.
Nothing failed; the file was simply misnamed, and a user comparing the filename
to Settings would see two different versions.

pubspec.yaml is the source of truth (Gradle reads it into versionName). This
test fails if the Dart constant drifts, or if the build stamp is stale relative
to the version.

Run: python3 tool/mirror/test_stamps.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), '..', '..')


def read():
    dart = open(os.path.join(ROOT, 'lib', 'main.dart'), encoding='utf-8').read()
    pub = open(os.path.join(ROOT, 'pubspec.yaml'), encoding='utf-8').read()
    build = re.search(r"kBuild = '([^']+)'", dart).group(1)
    dver = re.search(r"kVersionName = '([^']+)'", dart).group(1)
    pver = re.search(r"^version:\s*(\S+)", pub, re.M).group(1)
    return build, dver, pver


def test_stamps_agree():
    build, dver, pver = read()
    assert dver == pver, (
        'kVersionName is %r but pubspec version is %r -- the APK would be '
        'named after the Dart constant, so the filename and the installed app '
        'would disagree' % (dver, pver))

    # "17.1.0+21" -> the stamp has to mention 17.1 so a screenshot identifies it.
    short = pver.split('+')[0].rsplit('.', 1)[0]          # 17.1
    assert short in build, (
        'build stamp %r does not mention version %r -- a device screenshot '
        'would not identify the running build' % (build, short))
    print('  stamps agree: %s / %s / %s: PASS' % (build, dver, pver))


def test_release_workflow_reads_pubspec():
    wf = open(os.path.join(ROOT, '.github', 'workflows', 'release.yml'),
              encoding='utf-8').read()
    assert '^version:' in wf and 'pubspec.yaml' in wf, (
        'release.yml no longer derives the APK version from pubspec.yaml')
    assert "kVersionName = '\\K" not in wf, (
        'release.yml went back to reading the duplicated kVersionName constant')
    print('  release.yml reads pubspec.yaml: PASS')


if __name__ == '__main__':
    test_stamps_agree()
    test_release_workflow_reads_pubspec()
    print('all stamp tests PASS')
    sys.exit(0)

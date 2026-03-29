# Changelog

## 2029-03-29
- Android: show the unlock user picker from `onResume` (in addition to `onOutOfScreenSaver`), because the screensaver unlock event does not fire on Android (e.g. Boox/ONYX). Thanks to [dawo-sensei](https://github.com/dawo-sensei) for spotting the bug and the fix idea.
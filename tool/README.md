run `dart run tool/jnigen.dart`

Run `python3 tool/check_ios_localization.py` to check English/Chinese resource
coverage, matching format arguments, permission strings and preview generation.
On macOS it also validates the strings files with `plutil` and exercises
Foundation language selection and formatting. The iOS build workflow runs this
check; the navigation preview includes an English settings smoke test.

The iOS app follows the device's preferred supported language or the language
selected in iOS Settings for PiliPlus. Both English and Simplified Chinese are
bundled. App-owned labels use `piliLocalized` (or `piliLocalizedFormat` for
arguments); keep user titles, names, comments and messages verbatim. After adding
an interface string, update both `ios/Runner/en.lproj/Localizable.strings` and
`ios/Runner/zh-Hans.lproj/Localizable.strings`.

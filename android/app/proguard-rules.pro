# FuelToken Tracker release rules
#
# google_mlkit_text_recognition ships the LATIN recognizer as a runtime
# artifact (bundled, ~4 MB). The other script recognizers
# (chinese/devanagari/japanese/korean) are compileOnly dependencies — the
# plugin's TextRecognizer.initialize() references their option classes but
# they are never constructed at runtime because we only ever use
# TextRecognitionScript.latin — tell R8 those dangling references are fine.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit's on-device pipeline resolves a lot of its internals through
# reflection. R8 full-mode stripping/renaming breaks that at RUNTIME with
# instant processImage() failures (photo "failed" cards) — keep the
# engine intact. Cost is a few MB of metadata; correctness first.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.mlkit.vision.** { *; }
-dontwarn com.google.android.gms.**

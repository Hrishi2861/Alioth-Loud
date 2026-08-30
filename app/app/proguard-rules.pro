# alioth-loud app
#
# The app uses no reflection and no serialization, so there is nothing that R8
# cannot see. View subclasses named in activity_main.xml are kept by the rules
# aapt2 generates from merged resources, so they need no entry here.
#
# The one thing worth keeping is readable stack traces: this app is debugged
# through logcat on a device the author cannot reach, and an obfuscated frame in
# an AudioEffect attachment failure would be actively harmful.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Keep our own classes unobfuscated. They are a handful of files; the size win
# from renaming them is negligible against the debugging cost.
-keep class com.f3.aliothloud.** { *; }

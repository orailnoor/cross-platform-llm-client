# Consumer Proguard / R8 rules shipped with the flutter_litert_lm plugin.
#
# These are AUTOMATICALLY applied to any app that depends on this plugin —
# Android Gradle Plugin merges them with the app's own rules at build time.
# Apps don't need to copy anything.
#
# Why this file exists: the LiteRT-LM Android SDK (com.google.ai.edge.litertlm)
# is a JNI library. Its native C++ side reaches back into Kotlin via JNI to
# read fields and call getters on data classes such as `SamplerConfig`,
# `EngineConfig`, `ConversationConfig`, `Message`, `Contents`, `Content`,
# `ToolCall`, etc. R8 cannot see those JNI calls, so in release builds it
# happily strips or renames the getters and fields, and inference crashes
# the moment the native side tries to look them up:
#
#   java.lang.NoSuchMethodError: no non-static method
#     "Lcom/google/ai/edge/litertlm/SamplerConfig;.getTopK()I"
#
# The fix is to keep every public type, method, field and Kotlin metadata
# entry under `com.google.ai.edge.litertlm` so the native side keeps finding
# what it expects.

-keep class com.google.ai.edge.litertlm.** { *; }
-keepclassmembers class com.google.ai.edge.litertlm.** { *; }
-keepnames class com.google.ai.edge.litertlm.** { *; }

# Keep nested classes (Backend.CPU/GPU/NPU, Content.Text/ImageFile/...) and
# Kotlin companion objects.
-keep class com.google.ai.edge.litertlm.**$* { *; }
-keepclassmembers class com.google.ai.edge.litertlm.**$* { *; }

# Native methods declared on the JNI bridge class.
-keepclasseswithmembernames class com.google.ai.edge.litertlm.** {
    native <methods>;
}

# Anything reachable via JNI by name — covers fields the native side reads
# directly without going through a getter.
-keepclassmembers class com.google.ai.edge.litertlm.** {
    @androidx.annotation.Keep *;
}

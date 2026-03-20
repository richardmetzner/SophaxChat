# SophaxChat ProGuard rules
# Keep crypto classes — obfuscating them can break serialization
-keep class com.sophax.sophaxchat.crypto.** { *; }
-keep class com.sophax.sophaxchat.protocol.** { *; }

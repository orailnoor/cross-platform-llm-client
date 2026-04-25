#!/bin/bash
# ======================================================
# Overlayd AI — Flutter Project Setup Script
# Run this once to scaffold the Flutter project skeleton
# around the existing source files.
# ======================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "🚀 Setting up AI Chat Flutter project..."

# 1. Check if Flutter is available
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter SDK not found in PATH."
    echo "   Please install Flutter: https://flutter.dev/docs/get-started/install"
    echo "   Or add it to your PATH and try again."
    exit 1
fi

echo "✅ Flutter found: $(flutter --version | head -1)"

# 2. Create Flutter project skeleton (if android/ doesn't exist)
if [ ! -d "android" ]; then
    echo "📦 Creating Flutter project skeleton..."
    
    # Backup our files
    cp -r lib lib_backup
    cp pubspec.yaml pubspec_backup.yaml
    
    # Create project
    flutter create --org com.aichat --project-name ai_chat .
    
    # Restore our files
    rm -rf lib
    mv lib_backup lib
    mv pubspec_backup.yaml pubspec.yaml
    
    echo "✅ Project skeleton created."
else
    echo "ℹ️  android/ directory already exists, skipping create."
fi

# 3. Configure AndroidManifest.xml
MANIFEST="android/app/src/main/AndroidManifest.xml"
echo "🔧 Configuring Android Manifest..."

# Check if Shizuku provider is already added
if ! grep -q "ShizukuProvider" "$MANIFEST"; then
    # Add permissions and Shizuku provider
    # Using sed to insert before the closing </application> tag
    
    # macOS sed requires different syntax
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Add permissions before <application
        sed -i '' 's|<application|<!-- Permissions for Overlayd AI -->\
    <uses-permission android:name="android.permission.INTERNET" />\
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />\
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />\
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />\
    <uses-permission android:name="android.permission.WAKE_LOCK" />\
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />\
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />\
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />\
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />\
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />\
\
    <application|' "$MANIFEST"
        
        # Add Shizuku provider and boot receiver before </application>
        sed -i '' 's|</application>|<!-- Shizuku Provider for ADB shell access -->\
        <provider\
            android:name="rikka.shizuku.ShizukuProvider"\
            android:authorities="${applicationId}.shizuku"\
            android:multiprocess="false"\
            android:enabled="true"\
            android:exported="true"\
            android:permission="android.permission.INTERACT_ACROSS_USERS_FULL" />\
\
        <!-- Boot receiver to restart services after reboot -->\
        <receiver\
            android:name=".BootReceiver"\
            android:enabled="true"\
            android:exported="true">\
            <intent-filter>\
                <action android:name="android.intent.action.BOOT_COMPLETED" />\
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />\
            </intent-filter>\
        </receiver>\
\
    </application>|' "$MANIFEST"
        
        # Add largeHeap to application tag
        sed -i '' 's|<application|<application\
        android:largeHeap="true"|' "$MANIFEST"
    else
        # Linux sed
        sed -i 's|<application|<!-- Permissions -->\n    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />\n    <uses-permission android:name="android.permission.WAKE_LOCK" />\n    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />\n    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />\n    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />\n    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />\n    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />\n\n    <application|' "$MANIFEST"
        
        sed -i 's|</application>|<provider android:name="rikka.shizuku.ShizukuProvider" android:authorities="${applicationId}.shizuku" android:multiprocess="false" android:enabled="true" android:exported="true" android:permission="android.permission.INTERACT_ACROSS_USERS_FULL" />\n        <receiver android:name=".BootReceiver" android:enabled="true" android:exported="true"><intent-filter><action android:name="android.intent.action.BOOT_COMPLETED" /><action android:name="android.intent.action.QUICKBOOT_POWERON" /></intent-filter></receiver>\n    </application>|' "$MANIFEST"
        
        sed -i 's|<application|<application android:largeHeap="true"|' "$MANIFEST"
    fi
    
    echo "✅ Manifest configured with Shizuku, permissions, and boot receiver."
else
    echo "ℹ️  Shizuku already configured in manifest."
fi

# 4. Configure build.gradle for minSdk 26
BUILD_GRADLE="android/app/build.gradle"
if [ -f "$BUILD_GRADLE" ]; then
    # Update minSdk for Shizuku support
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/minSdk.*/minSdk = 26/' "$BUILD_GRADLE"
        # Disable R8 shrinking for LLM compatibility
        sed -i '' 's/minifyEnabled.*/minifyEnabled = false/' "$BUILD_GRADLE" 2>/dev/null || true
        sed -i '' 's/shrinkResources.*/shrinkResources = false/' "$BUILD_GRADLE" 2>/dev/null || true
    else
        sed -i 's/minSdk.*/minSdk = 26/' "$BUILD_GRADLE"
        sed -i 's/minifyEnabled.*/minifyEnabled = false/' "$BUILD_GRADLE" 2>/dev/null || true
        sed -i 's/shrinkResources.*/shrinkResources = false/' "$BUILD_GRADLE" 2>/dev/null || true
    fi
    echo "✅ build.gradle configured (minSdk=26, shrink disabled)."
fi

# Also check for build.gradle.kts
BUILD_GRADLE_KTS="android/app/build.gradle.kts"
if [ -f "$BUILD_GRADLE_KTS" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/minSdk.*/minSdk = 26/' "$BUILD_GRADLE_KTS"
        sed -i '' 's/isMinifyEnabled.*/isMinifyEnabled = false/' "$BUILD_GRADLE_KTS" 2>/dev/null || true
        sed -i '' 's/isShrinkResources.*/isShrinkResources = false/' "$BUILD_GRADLE_KTS" 2>/dev/null || true
    else
        sed -i 's/minSdk.*/minSdk = 26/' "$BUILD_GRADLE_KTS"
        sed -i 's/isMinifyEnabled.*/isMinifyEnabled = false/' "$BUILD_GRADLE_KTS" 2>/dev/null || true
        sed -i 's/isShrinkResources.*/isShrinkResources = false/' "$BUILD_GRADLE_KTS" 2>/dev/null || true
    fi
    echo "✅ build.gradle.kts configured (minSdk=26, shrink disabled)."
fi

# 5. Create Boot Receiver
BOOT_RECEIVER_DIR="android/app/src/main/kotlin/com/aichat/ai_chat"
if [ ! -d "$BOOT_RECEIVER_DIR" ]; then
    # Try Java path
    BOOT_RECEIVER_DIR="android/app/src/main/java/com/aichat/ai_chat"
fi

# Find the actual package directory
KOTLIN_DIR=$(find android/app/src/main -name "MainActivity.kt" -o -name "MainActivity.java" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)

if [ -n "$KOTLIN_DIR" ] && [ -d "$KOTLIN_DIR" ]; then
    if [ ! -f "$KOTLIN_DIR/BootReceiver.kt" ]; then
        cat > "$KOTLIN_DIR/BootReceiver.kt" << 'KOTLIN_EOF'
package com.aichat.ai_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            // Restart the Flutter engine / foreground service
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (launchIntent != null) {
                context.startActivity(launchIntent)
            }
        }
    }
}
KOTLIN_EOF
        echo "✅ BootReceiver.kt created."
    fi
fi

# 6. Get dependencies
echo "📥 Fetching Flutter dependencies..."
flutter pub get

echo ""
echo "======================================================"
echo "✅ AI Chat setup complete!"
echo "======================================================"
echo ""
echo "To run the app:"
echo "  flutter run"
echo ""
echo "To build release APK:"
echo "  flutter build apk --release"
echo ""
echo "Prerequisites on Android device:"
echo "  1. Install Shizuku from Play Store"
echo "  2. Start Shizuku via Wireless Debugging"
echo "  3. Grant permission when prompted in the app"
echo ""

#!/bin/zsh
# Package the built app as a signed Sparkle update and write the update feed.
#
#   tools/make_update.sh [FEED_URL_BASE]
#
# Run after tools/build_app.sh. Produces build/iPod-Drop-<version>.zip (attach it to
# the GitHub release v<version>) and docs/appcast.xml (published with the website).
# Signing uses the private key in the login Keychain (account "ipod-drop"), created
# once with Sparkle's generate_keys. Keep that key: without it, existing copies of
# iPod Drop can't verify, and so won't install, future updates.
set -euo pipefail
cd "${0:A:h:h}"

APP="build/Release/iPod Drop.app"
BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -d $APP ]] || { echo "Build the app first: tools/build_app.sh"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
ZIP="build/iPod-Drop-$VERSION.zip"
BASE=${1:-https://github.com/abijitinu/ipod-drop/releases/download/v$VERSION}

echo "› Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "› Signing the update"
SIGNATURE=$("$BIN/sign_update" --account ipod-drop "$ZIP")  # sparkle:edSignature="…" length="…"

echo "› Writing docs/appcast.xml"
cat > docs/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>iPod Drop</title>
    <link>https://abijitinu.github.io/ipod-drop/</link>
    <description>Updates for iPod Drop</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/abijitinu/ipod-drop/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$(cat build/release-notes.html 2>/dev/null || echo "<p>See the release notes on GitHub.</p>")]]></description>
      <enclosure url="$BASE/iPod-Drop-$VERSION.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "› $(du -h "$ZIP" | cut -f1)  $ZIP  (version $VERSION, build $BUILD)"

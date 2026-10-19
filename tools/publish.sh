#!/bin/zsh
# Publish iPod Drop to GitHub: public repo, code push, v2.0 release with the DMG,
# and the download website on GitHub Pages (served from docs/).
# Run from the project folder in a terminal where `gh` is logged in as abijitinu:
#   tools/publish.sh
set -euo pipefail

OWNER=abijitinu
REPO=ipod-drop
VERSION=v2.0
DMG=build/iPod-Drop.dmg

cd "${0:A:h:h}"

echo "› Checking GitHub sign-in"
LOGIN=$(gh api user --jq .login 2>/dev/null || true)
if [[ "$LOGIN" != "$OWNER" ]]; then
  echo "This terminal is signed in to GitHub as '${LOGIN:-nobody}', not '$OWNER'."
  echo "Run: gh auth login -h github.com -p https -w   (then run this script again)"
  exit 1
fi
[[ -f $DMG ]] || { echo "Missing $DMG. Build it first: tools/build_app.sh --dmg"; exit 1; }

echo "› Creating the public repository $OWNER/$REPO (skipped if it exists)"
if ! gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  gh repo create "$OWNER/$REPO" --public \
    --description "Drag and drop music onto your classic iPod from macOS. No iTunes needed." \
    --homepage "https://$OWNER.github.io/$REPO/"
fi

echo "› Pushing the code"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/$REPO.git"
gh auth setup-git
git push -u origin main

echo "› Publishing release $VERSION with the DMG"
if ! gh release view "$VERSION" --repo "$OWNER/$REPO" >/dev/null 2>&1; then
  gh release create "$VERSION" "$DMG" --repo "$OWNER/$REPO" --title "iPod Drop 2.0" --notes "$(cat <<'NOTES'
First public release.

- Drag and drop music onto classic iPods from the menu bar or the library window
- Automatic conversion (FLAC, WAV, Opus and more) to formats the iPod plays
- Playlists, song info editing, Fix Info (iTunes catalogue lookup) and a built-in player
- Tested on iPod classic and simulated iPod, mini and nano (1st–4th gen) models

**Install:** open `iPod-Drop.dmg`, drag iPod Drop to Applications, then approve it once in System Settings › Privacy & Security (the app isn't notarized yet). Install ffmpeg with `brew install ffmpeg` for format conversion. Requires macOS 26 on Apple silicon.
NOTES
)"
else
  echo "  (release exists; uploading the DMG again)"
  gh release upload "$VERSION" "$DMG" --repo "$OWNER/$REPO" --clobber
fi

echo "› Turning on the website (GitHub Pages from docs/)"
if ! gh api "repos/$OWNER/$REPO/pages" >/dev/null 2>&1; then
  gh api -X POST "repos/$OWNER/$REPO/pages" -f "source[branch]=main" -f "source[path]=/docs" >/dev/null
fi

echo
echo "Done."
echo "  Repository: https://github.com/$OWNER/$REPO"
echo "  Release:    https://github.com/$OWNER/$REPO/releases/tag/$VERSION"
echo "  Website:    https://$OWNER.github.io/$REPO/  (can take a minute or two to appear)"

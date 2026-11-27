# Sourced by upload-dev.sh and release.sh: the Mac apps for Homebrew, signed with Developer ID.
#
# developer_id_app <archive> <dir> <log> [--no-notarize] exports the archive's app with Developer ID
# into <dir>, notarizes it with the App Store Connect API key (load_asc_key from asc-key.sh first: key_file,
# key_id, issuer), staples it and leaves <dir>/<App>.app. Needs $team (the paid team) and $work (a
# scratch folder only this run uses). Stops the script with the reason when a step fails.
#
# The provisioning profile for Developer ID ("Mac Team Direct") carries the App Group and iCloud
# (iCloud Documents, Production), so Stats sync works in these copies as in the TestFlight ones.
developer_id_app() {
  local archive=$1 dir=$2 log=$3 notarize=${4:-} app status
  app=$(basename "$(find "$archive/Products/Applications" -maxdepth 1 -name "*.app" | head -1)" .app)
  [ -n "$app" ] || fail "no app in $archive"
  if [ ! -f "$work/DeveloperID.plist" ]; then
    cat > "$work/DeveloperID.plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOP
  fi
  rm -rf "$dir"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/DeveloperID.plist" \
    -exportPath "$dir" -allowProvisioningUpdates >>"$log" 2>&1 \
    || fail "exporting $app with Developer ID failed; see $log"
  [ "$notarize" != --no-notarize ] || return 0
  ditto -c -k --keepParent "$dir/$app.app" "$work/$app-notarize.zip"
  xcrun notarytool submit "$work/$app-notarize.zip" --key "$key_file" --key-id "$key_id" --issuer "$issuer" \
    --wait --output-format json >"$dir/notary.json" 2>>"$log" || true
  status=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", "?"))' "$dir/notary.json" 2>/dev/null || echo "?")
  [ "$status" = Accepted ] \
    || fail "notarizing $app: $status. Its submission is in $dir/notary.json; xcrun notarytool log <id> shows why."
  xcrun stapler staple "$dir/$app.app" >>"$log" 2>&1 || fail "stapling $app failed; see $log"
  rm -f "$work/$app-notarize.zip"
}

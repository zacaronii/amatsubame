# Sourced by upload-dev.sh and release.sh: the App Store Connect API key from the login keychain
# (service amatsubame.asc, account = Key ID, comment = Issuer ID, password = the .p8 file in base64):
#   security add-generic-password -s amatsubame.asc -a <Key ID> -j <Issuer ID> -w "$(base64 -i AuthKey_<Key ID>.p8)"
# load_asc_key <dir> writes the key into <dir>, readable only by this user, and sets key_id, issuer
# and key_file.
load_asc_key() {
  local item
  item=$(security find-generic-password -s amatsubame.asc 2>/dev/null) \
    || fail "no App Store Connect key in the keychain (service amatsubame.asc); see scripts/asc-key.sh."
  key_id=$(sed -nE 's/^[[:space:]]*"acct"<blob>="(.*)"$/\1/p' <<<"$item")
  issuer=$(sed -nE 's/^[[:space:]]*"icmt"<blob>="(.*)"$/\1/p' <<<"$item")
  [ -n "$key_id" ] && [ -n "$issuer" ] || fail "the keychain item needs the Key ID as its account and the Issuer ID as its comment."
  key_file="$1/AuthKey_$key_id.p8"
  (umask 077; security find-generic-password -s amatsubame.asc -w | base64 -D > "$key_file")
  grep -q "BEGIN PRIVATE KEY" "$key_file" || fail "the keychain item doesn't hold a base64-encoded .p8 key."
}

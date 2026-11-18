#!/bin/sh
# Developer ID で署名した CastMicHAL.driver を Apple に公証してもらう。
#
# 初回だけ、認証情報をキーチェーンに保存しておく (App 用パスワードは appleid.apple.com で作成):
#   xcrun notarytool store-credentials castmic --apple-id <Apple ID> --team-id 2PBVY8C5TF --password <App用パスワード>
#
# その後は:
#   ./notarize.sh
set -eu
cd "$(dirname "$0")"
PROFILE="${CASTMIC_NOTARY_PROFILE:-castmic}"
CASTMIC_SIGN_ID="${CASTMIC_SIGN_ID:-Developer ID Application: Yasuyo Mizutani (2PBVY8C5TF)}" ./build.sh
rm -f build/CastMicHAL.zip
ditto -c -k --keepParent build/CastMicHAL.driver build/CastMicHAL.zip
xcrun notarytool submit build/CastMicHAL.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/CastMicHAL.driver
spctl --assess --type install -vv build/CastMicHAL.driver || true
echo "公証済み: $(pwd)/build/CastMicHAL.driver"

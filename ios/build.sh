#!/bin/zsh
# Build Blazie, install it on the USB iPad and open it. The blazied token (~/.blazie/token) is baked in.
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IPAD=${BLAZIE_IPAD:-00008103-001604D00269401E}
DD=$PWD/../vendor/blazie-dd
xcodegen generate --quiet
lane build -- xcodebuild build -project Blazie.xcodeproj -scheme Blazie -configuration Release \
  -destination "id=$IPAD" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$PWD/../vendor/spm" \
  BLAZIE_TOKEN="$(cat ~/.blazie/token)" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -skipPackagePluginValidation -skipMacroValidation \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_265V39N664.p8 \
  -authenticationKeyID 265V39N664 -authenticationKeyIssuerID ca81fc03-e9d2-4af2-9273-b9d1a3052169 \
  -quiet
APP="$DD/Build/Products/Release-iphoneos/Blazie.app"
lane phone -- xcrun devicectl device install app --device "$IPAD" "$APP" >/dev/null
xcrun devicectl device process launch --device "$IPAD" --terminate-existing com.shinyobjectz.blazie >/dev/null
echo "Blazie installed and opened on the iPad"

# Signing

## `debug.keystore` — committed on purpose

Every build of this app, on CI or on a laptop, is signed with this key.

Android only installs an APK over an existing app when both are signed with
the **same** certificate. The stock Flutter setup signs with
`~/.android/debug.keystore`, which is generated on first use — so a fresh
GitHub Actions runner minted a *different* key on every run, each new APK
refused to install over the last one, and a test tablet kept running its
old build while looking like it had been updated.

Committing the debug key fixes that. It is the standard Android debug
identity — store password `android`, alias `androiddebugkey`, key password
`android` — and is exactly as secret as the one on every developer's
machine: not at all. It exists so sideloaded builds update in place.

If you have a tablet with a build from **before** this key existed, the
first install after it will fail with "App not installed" (different
signer). Uninstall the old app once; every build after that updates in
place.

Regenerate it only if you accept that every installed tablet will need
that one-time uninstall again:

```sh
keytool -genkeypair -v -keystore debug.keystore -storetype PKCS12 \
  -storepass android -keypass android -alias androiddebugkey \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -dname "CN=Origami FarmOS Debug, OU=Sideload, O=Origami Farms, L=Bekaa, C=LB"
```

## Play Store

This key must **not** be used for a store release. Generate an upload key,
keep it out of the repository (the `.gitignore` already blocks `*.keystore`
and `*.jks` — this file is the single, deliberate exception), supply it via
`key.properties` and a CI secret, and enrol the app in Play App Signing.

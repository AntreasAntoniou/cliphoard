# Mac App Store build

The Store build is a separate compile-time distribution channel. It keeps the complete Free
history and search experience and uses StoreKit for Pro, while the direct build retains its
offline licence flow. `APP_STORE` removes synthetic Command-V and Accessibility prompts: picking
a clip writes it to the pasteboard, returns to the previous app, and asks the user to press ⌘V.

The build is sandboxed and uses system open/save panels for files outside its container. It
bundles every reachable Core ML model so the reviewed app does not download functionality later.

The Store identifier has its own sandbox container and keychain access group. Installing it beside
the direct build does not automatically copy history, preferences, or a direct licence. A user can
move history explicitly with Cliphoard's encrypted export/import flow through the system file
picker; Store Pro status comes only from the Store purchase entitlement.

## Local sandbox assembly

```sh
MAS_SIGN_MODE=adhoc bash Scripts/build-mas.sh
```

This produces `build/mas/Cliphoard.app` with an ad-hoc sandbox inspection signature. It is not
uploadable and deliberately omits restricted keychain/application identifiers because no
provisioning profile authorizes an ad-hoc signature.

## Store upload package

The Apple Developer account must already contain:

- explicit App ID `ai.a2-labs.cliphoard` for team `74M96PGT6P`;
- a Mac App Store Connect provisioning profile for that ID;
- an installed Mac App Distribution certificate and private key;
- an installed Mac Installer Distribution certificate and private key.

The script does not create or download any of these and performs no upload:

```sh
MAS_SIGN_MODE=app-store \
MAS_PROFILE=/absolute/path/Cliphoard_Mac_App_Store.provisionprofile \
MAS_APP_IDENTITY='<installed Mac App Distribution identity>' \
MAS_INSTALLER_IDENTITY='<installed Mac Installer Distribution identity>' \
bash Scripts/build-mas.sh
```

It verifies the profile's exact App ID, team, and sandbox authorization before signing, embeds the
profile, verifies the signed app, then creates and verifies `build/mas/Cliphoard.pkg`. Submission,
pricing, IAP creation, review metadata, purchases, and release remain separate external actions.

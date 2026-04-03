# Signing and Notarization Setup

This project can produce Developer ID signed and notarized macOS releases from GitHub Actions.

The release workflow expects these GitHub Actions secrets:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## 1. Create a Developer ID Application certificate

In Apple Developer:

1. Open Certificates, Identifiers & Profiles.
2. Create a new certificate.
3. Choose `Developer ID Application`.
4. Generate the certificate from a CSR in Keychain Access.
5. Download and install the certificate on your Mac.

## 2. Export the certificate as a `.p12`

In Keychain Access:

1. Open `login` keychain.
2. Find the `Developer ID Application` certificate.
3. Expand it so the private key is visible underneath.
4. Select both the certificate and its private key.
5. Export them as `Octodot-DeveloperID.p12`.
6. Choose a strong export password.

## 3. Base64-encode the exported certificate

Run:

```sh
base64 -i Octodot-DeveloperID.p12 | pbcopy
```

Paste that value into the `APPLE_CERTIFICATE_BASE64` GitHub secret.

Use the export password from step 2 for:

- `APPLE_CERTIFICATE_PASSWORD`

## 4. Find the signing identity string

Run:

```sh
security find-identity -v -p codesigning
```

Use the full `Developer ID Application: ...` name as:

- `APPLE_SIGNING_IDENTITY`

Example:

```text
Developer ID Application: Jason Long (TEAMID1234)
```

## 5. Find your Apple team ID

Use the 10-character team identifier from Apple Developer membership details.

Store it as:

- `APPLE_TEAM_ID`

## 6. Create an app-specific password

In your Apple account:

1. Open Sign-In and Security.
2. Create a new app-specific password.
3. Label it something like `Octodot GitHub Actions`.

Store these as GitHub secrets:

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## 7. Add the GitHub Actions secrets

In GitHub:

1. Open the repository.
2. Go to `Settings` -> `Secrets and variables` -> `Actions`.
3. Add all six secrets listed above.

## 8. Trigger a notarized release

Create and push a version tag:

```sh
git tag -a v0.2.4 -m "v0.2.4"
git push origin v0.2.4
```

The release workflow will:

1. run tests
2. import the Developer ID certificate into a temporary keychain
3. build a signed Release app
4. notarize the zipped app with `notarytool`
5. staple the notarization ticket
6. upload the stapled zip to the GitHub release

## 9. Verify the result locally

After downloading the release asset, you can verify it with:

```sh
spctl --assess --type execute --verbose=4 Octodot.app
codesign --verify --deep --strict --verbose=2 Octodot.app
```

You should see a valid Developer ID signature and notarization acceptance.

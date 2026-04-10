# iOS App Setup & TestFlight Distribution

Guide for building the Echo iOS app and distributing it via TestFlight.

## Prerequisites

- Mac with Xcode 15+ installed
- [Apple Developer account](https://developer.apple.com) ($99/year)
- Flutter SDK installed (`flutter doctor` should show iOS as ready)
- CocoaPods installed (`sudo gem install cocoapods`)

## Step 1: Apple Developer Portal Setup

### Create an App ID

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Keys** > **Identifiers**
3. Click **+** > select **App IDs** > **App**
4. Fill in:
   - **Description:** `Echo Messenger`
   - **Bundle ID:** Explicit > `us.echomessenger.app`
5. Under **Capabilities**, enable:
   - **Push Notifications**
   - **Keychain Sharing** (used for secure key storage)
6. Click **Continue** > **Register**

### Create a Provisioning Profile

1. Go to **Profiles** > click **+**
2. Select **iOS App Development** (for testing) or **App Store Connect** (for TestFlight)
3. Select your App ID (`us.echomessenger.app`)
4. Select your signing certificate
5. Select test devices (for development profile)
6. Name it (e.g., `Echo Dev` or `Echo Distribution`)
7. Download and double-click to install

## Step 2: Xcode Project Configuration

1. Open `apps/client/ios/Runner.xcworkspace` in Xcode
2. Select the **Runner** target > **Signing & Capabilities**
3. Check **Automatically manage signing**
4. Select your Team from the dropdown
5. Verify Bundle Identifier is `us.echomessenger.app`
6. Ensure these capabilities are listed:
   - **Keychain Sharing** (group: `$(AppIdentifierPrefix)us.echomessenger.app`)
   - **Push Notifications**
   - If missing, click **+ Capability** and add them

## Step 3: Build the Flutter App

```bash
cd apps/client

# Install dependencies
flutter pub get

# Install CocoaPods dependencies
cd ios && pod install && cd ..

# Build the iOS app (release mode)
flutter build ios --release
```

If you get signing errors, open Xcode and fix them in **Signing & Capabilities**.

## Step 4: Archive and Upload to App Store Connect

### Option A: Xcode (GUI)

1. Open `apps/client/ios/Runner.xcworkspace` in Xcode
2. Select **Product** > **Archive**
3. Once archived, click **Distribute App**
4. Select **App Store Connect** > **Upload**
5. Follow the prompts (accept defaults for bitcode/symbols)

### Option B: Command Line

```bash
# Build the archive
flutter build ipa --release

# The .ipa file will be in build/ios/ipa/
# Upload using xcrun:
xcrun altool --upload-app \
  --type ios \
  --file build/ios/ipa/echo_app.ipa \
  --apiKey YOUR_API_KEY_ID \
  --apiIssuer YOUR_ISSUER_ID
```

## Step 5: TestFlight Configuration

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Select your app (or create it if first time: **My Apps** > **+** > **New App**)
   - Platform: iOS
   - Name: Echo Messenger
   - Bundle ID: `us.echomessenger.app`
   - SKU: `echo-messenger`
3. After upload, go to **TestFlight** tab
4. The build will appear after Apple processes it (usually 5-30 minutes)
5. If prompted for **Export Compliance**, select:
   - "Standard encryption algorithms" (uses OS-provided CryptoKit)
   - Distribution in France: **No** (unless you plan to)
   - This is handled automatically by `ITSAppUsesNonExemptEncryption = false` in Info.plist
6. Add **Internal Testers** (your team, up to 100, no review needed)
7. Or create an **External Testing Group** (up to 10,000, requires Apple review)

## Step 6: Install on Device

1. Testers receive a TestFlight invitation email
2. Install the **TestFlight** app from the App Store
3. Open the invitation link or enter the invite code
4. Install Echo from TestFlight

## CI/CD (GitHub Actions)

The release pipeline (`.github/workflows/release.yml`) handles iOS builds automatically on push to `main`. It requires these GitHub repository secrets:

| Secret | Description |
|--------|-------------|
| `IOS_CERTIFICATE_BASE64` | Base64-encoded .p12 distribution certificate |
| `IOS_CERTIFICATE_PASSWORD` | Password for the .p12 certificate |
| `IOS_PROVISION_PROFILE_BASE64` | Base64-encoded provisioning profile |
| `APPSTORE_API_KEY_ID` | App Store Connect API Key ID |
| `APPSTORE_API_ISSUER_ID` | App Store Connect Issuer ID |
| `APPSTORE_API_PRIVATE_KEY` | App Store Connect API private key contents |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `No signing certificate` | Open Xcode > Preferences > Accounts > Download certificates |
| `Provisioning profile doesn't match` | Check bundle ID matches in Xcode and Apple portal |
| `Pod install fails` | Run `cd ios && pod repo update && pod install` |
| `Module 'flutter_local_notifications' not found` | Run `pod install` in the ios directory |
| Build stuck processing on App Store Connect | Wait up to 30 minutes, then re-upload if needed |

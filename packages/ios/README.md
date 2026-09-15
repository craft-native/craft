# @craft-native/ios

Build native iOS apps with web technologies using Craft.

## Features

### Core

- **WKWebView** - Native iOS WebView with full JavaScript support
- **Safe Areas** - Automatic handling of notch and home indicator
- **Dark Mode** - Native dark/light theme support

### Input & Feedback

- **Native Speech Recognition** - iOS SFSpeechRecognizer (works offline!)
- **Haptic Feedback** - UIImpactFeedbackGenerator, UINotificationFeedbackGenerator
- **Audio Recording** - AVAudioRecorder with compressed output
- **Video Recording** - UIImagePickerController video capture

### Device Access

- **Camera & Gallery** - Take photos or pick from gallery
- **Barcode/QR Scanner** - VisionKit DataScanner (iOS 16+)
- **File Picker** - UIDocumentPickerViewController
- **File Download** - Download and save files to device

### Sensors & Location

- **Geolocation** - GPS and network location via CLLocationManager
- **Motion Sensors** - Accelerometer & gyroscope via CoreMotion
- **NFC** - Read NFC tags via CoreNFC

### Communication

- **Share Sheet** - Native UIActivityViewController
- **Clipboard** - Read and write to system clipboard
- **Push Notifications** - APNs integration

### Security & Auth

- **Biometric Auth** - Face ID / Touch ID
- **Social Auth** - Apple Sign In
- **Secure Storage** - Keychain integration

### Data & Storage

- **Local Database** - SQLite with full SQL support
- **Bluetooth LE** - CoreBluetooth scanning

### System

- **Device Info** - Device model, OS version, screen info
- **Network Status** - Connection type monitoring (WiFi/Cellular)
- **App Badge** - Notification badge count
- **App State** - Foreground/background detection
- **Flashlight** - Camera flash control
- **Open URL** - External browser launch
- **Vibration** - Custom vibration patterns
- **App Review** - StoreKit review prompt
- **Screen Capture** - Take screenshots programmatically
- **Health/Fitness** - HealthKit integration

## Installation

The iOS support is built into the main `craft` CLI:

```bash
bun add craft-native
```

## Quick Start

### 1. Initialize Project

```bash
craft ios init MyApp --bundle-id com.example.myapp
cd ios
```

### 2. Add Your Web Content

Replace `dist/index.html` with your web app, or point to a dev server:

```bash
craft ios build --html-path ../dist/index.html
# or
craft ios build --dev-server http://localhost:3456
```

### 3. Open in Xcode

```bash
craft ios open
```

### 4. Run on Device

In Xcode:

1. Select your Team in Signing & Capabilities
2. Connect your iPhone
3. Select your device
4. Click Run

## Configuration

Edit `craft.config.json` in your iOS project:

```json
{
  "appName": "MyApp",
  "bundleId": "com.example.myapp",
  "version": "1.0.0",
  "buildNumber": "1",
  "darkMode": true,
  "backgroundColor": "#1a1a2e",
  "enableSpeechRecognition": true,
  "enableHaptics": true,
  "enableShare": true,
  "enableCamera": true,
  "enableBiometric": true,
  "enablePushNotifications": false,
  "enableSecureStorage": true,
  "enableGeolocation": true,
  "enableClipboard": true,
  "enableNetworkStatus": true,
  "enableAppReview": true,
  "enableFlashlight": true,
  "enableQRScanner": true,
  "enableFilePicker": true,
  "enableFileDownload": true,
  "enableSocialAuth": true,
  "enableAudioRecording": true,
  "enableVideoRecording": true,
  "enableMotionSensors": true,
  "enableLocalDatabase": true,
  "enableBluetooth": true,
  "enableNFC": true,
  "enableHealthKit": false,
  "enableScreenCapture": true,
  "iosVersion": "15.0",
  "teamId": ""
}
```

When push notifications are enabled, generated Debug builds use the APNs
development environment and Release builds use the production environment.
The generated entitlements select the correct value from the active Xcode
build configuration automatically.

## JavaScript Bridge

Once Craft is initialized, the `window.craft` object is available:

```javascript
// Wait for Craft to be ready
window.addEventListener('craftReady', (e) => {
  console.log('Platform:', e.detail.platform); // 'ios'
  console.log('Capabilities:', e.detail.capabilities);
});

// Haptic feedback
window.craft.haptic('light');   // light, medium, heavy
window.craft.haptic('success'); // success, warning, error
window.craft.haptic('selection');

// Speech recognition
window.craft.startListening();
window.craft.stopListening();

// Listen for speech events
window.addEventListener('craftSpeechStart', () => { /* recording started */ });
window.addEventListener('craftSpeechResult', (e) => {
  console.log(e.detail.transcript);  // "hello world"
  console.log(e.detail.isFinal);     // true/false
});
window.addEventListener('craftSpeechEnd', () => { /* recording stopped */ });
window.addEventListener('craftSpeechError', (e) => {
  console.error(e.detail.error);
});

// Share
window.craft.share('Check out this app!', 'My App');

// Camera & Gallery
const imageBase64 = await window.craft.openCamera();
const selectedImage = await window.craft.pickImage();

// Barcode/QR Scanner (iOS 16+)
const scannedCode = await window.craft.scanQRCode();
console.log(scannedCode); // "https://example.com"

// File Picker
const file = await window.craft.pickFile(['public.image', 'public.pdf']);
console.log(file.name, file.data); // base64 encoded

// File Download
await window.craft.downloadFile('https://example.com/file.pdf', 'document.pdf');
await window.craft.saveFile(base64Data, 'image.png', 'image/png');

// Social Auth (Apple Sign In)
const user = await window.craft.signInWithApple();
console.log(user.userId, user.email, user.fullName, user.identityToken);

// Audio Recording
await window.craft.startAudioRecording();
const audioBase64 = await window.craft.stopAudioRecording();

// Video Recording
const videoBase64 = await window.craft.startVideoRecording();

// Motion Sensors
window.craft.startMotionUpdates();
window.addEventListener('craftMotionUpdate', (e) => {
  console.log('Accelerometer:', e.detail.accelerometer); // {x, y, z}
  console.log('Gyroscope:', e.detail.gyroscope);         // {x, y, z}
});
window.craft.stopMotionUpdates();

// Local Database (SQLite)
await window.craft.db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
await window.craft.db.execute('INSERT INTO users (name) VALUES (?)', ['Alice']);
const users = await window.craft.db.query('SELECT * FROM users');

// Bluetooth LE Scanning
window.craft.startBluetoothScan();
window.addEventListener('craftBluetoothDevice', (e) => {
  console.log(e.detail.name, e.detail.uuid, e.detail.rssi);
});
window.craft.stopBluetoothScan();

// NFC Tag Reading
const nfcData = await window.craft.scanNFC();
console.log(nfcData); // Tag content

// Health/Fitness (requires HealthKit entitlement)
await window.craft.requestHealthAuthorization(['stepCount', 'heartRate']);
const steps = await window.craft.getHealthData('stepCount', startDate, endDate);

// Screen Capture
const screenshotBase64 = await window.craft.takeScreenshot();

// Biometric authentication
try {
  const authenticated = await window.craft.authenticate('Confirm your identity');
  if (authenticated) {
    console.log('User authenticated!');
  }
} catch (error) {
  console.log('Authentication failed:', error.message);
}

// Push notifications
const token = await window.craft.registerPush();
console.log('Push token:', token);

// Secure storage (Keychain)
await window.craft.secureStore.set('api*key', 'secret123');
const apiKey = await window.craft.secureStore.get('api*key');
await window.craft.secureStore.remove('api*key');

// Geolocation
const position = await window.craft.getCurrentPosition();
console.log(position.latitude, position.longitude);

// Watch position (continuous updates)
const watchId = window.craft.watchPosition((position) => {
  console.log('New position:', position);
});
window.craft.clearWatch(watchId);

// Clipboard
await window.craft.clipboard.write('Hello World');
const text = await window.craft.clipboard.read();

// Device Info
const device = window.craft.getDeviceInfo();
console.log(device.model, device.systemVersion, device.screenWidth);

// App Badge
window.craft.setBadge(5);
window.craft.clearBadge();

// Network Status
const network = window.craft.getNetworkStatus();
console.log(network.isConnected, network.type); // true, 'wifi'

// Network change listener
window.craft.onNetworkChange((status) => {
  console.log('Network changed:', status);
});
window.craft.offNetworkChange();

// App Review (StoreKit)
await window.craft.requestReview();

// Flashlight
window.craft.setFlashlight(true);  // turn on
window.craft.setFlashlight(false); // turn off
window.craft.toggleFlashlight();   // toggle

// Open URL (external browser)
window.craft.openURL('https://example.com');

// Vibration Pattern (custom durations in ms)
window.craft.vibrate([100, 50, 100, 50, 200]);

// App State
const state = window.craft.getAppState(); // 'active', 'inactive', 'background'

// App state change listener
window.craft.onAppStateChange((state) => {
  console.log('App state:', state);
});
window.craft.offAppStateChange();

// Logging (appears in Xcode console)
window.craft.log('Debug message');

// ==================== High Value Bridges ====================

// Contacts
const contacts = await window.craft.getContacts();
console.log(contacts); // [{id, givenName, familyName, displayName, phoneNumbers, emailAddresses}]

const newContactId = await window.craft.addContact({
  givenName: 'John',
  familyName: 'Doe',
  phone: '+1234567890',
  email: 'john@example.com'
});

// Calendar Events
const events = await window.craft.getCalendarEvents(startDateMs, endDateMs);
console.log(events); // [{id, title, location, notes, startDate, endDate, isAllDay}]

const newEventId = await window.craft.createCalendarEvent({
  title: 'Meeting',
  location: 'Office',
  notes: 'Discuss project',
  startDate: Date.now(),
  endDate: Date.now() + 3600000,
  isAllDay: false
});

await window.craft.deleteCalendarEvent(eventId);

// Local Notifications
const notificationId = await window.craft.scheduleNotification({
  id: 'reminder-1',
  title: 'Reminder',
  body: 'Don\'t forget!',
  badge: 1,
  timestamp: Date.now() + 60000, // 1 minute from now
  // or use delay: 60000 // delay in ms
});

await window.craft.cancelNotification('reminder-1');
await window.craft.cancelAllNotifications();
const pending = await window.craft.getPendingNotifications();

// In-App Purchase
const products = await window.craft.getProducts(['product*id*1', 'product*id*2']);
console.log(products); // [{id, title, description, price, priceLocale}]

const purchaseResult = await window.craft.purchase('product*id*1');
console.log(purchaseResult); // {transactionId, productId, ...}

await window.craft.restorePurchases();

// Keep Screen Awake
window.craft.setKeepAwake(true);  // Prevent screen dimming
window.craft.setKeepAwake(false); // Allow screen dimming

// Orientation Lock
window.craft.lockOrientation('portrait');   // Lock to portrait
window.craft.lockOrientation('landscape');  // Lock to landscape
window.craft.unlockOrientation();           // Allow all orientations

// ==================== Medium Value Bridges ====================

// Background Tasks (iOS 13+)
await window.craft.backgroundTask.register('sync-data');
await window.craft.backgroundTask.schedule('sync-data', {
  delay: 900,              // 15 minutes minimum
  requiresNetwork: true,
  requiresCharging: false
});
await window.craft.backgroundTask.cancel('sync-data');
await window.craft.backgroundTask.cancelAll();

// PDF Viewer
await window.craft.openPDF('https://example.com/document.pdf');
await window.craft.openPDF(base64PdfData, 5); // Open at page 5
await window.craft.closePDF();

// Contacts Picker (shows native picker UI)
const contact = await window.craft.pickContact();
console.log(contact); // {id, givenName, familyName, displayName, phoneNumbers, emailAddresses}

const contacts = await window.craft.pickContact({multiple: true}); // Select multiple

// App Shortcuts (3D Touch / long press)
await window.craft.shortcuts.set([
  {type: 'new-message', title: 'New Message', subtitle: 'Start composing', iconName: 'square.and.pencil'},
  {type: 'search', title: 'Search', iconName: 'magnifyingglass'}
]);
window.craft.shortcuts.onShortcut((shortcut) => {
  console.log('Shortcut activated:', shortcut.type);
});
await window.craft.shortcuts.clear();

// Keychain Sharing (cross-app data with access groups)
await window.craft.sharedKeychain.set('user*token', 'abc123', 'com.example.shared'); // group optional
const result = await window.craft.sharedKeychain.get('user*token', 'com.example.shared');
console.log(result.value); // 'abc123'
await window.craft.sharedKeychain.remove('user*token');

// Local Auth Persistence (skip re-auth for a duration)
await window.craft.authPersistence.enable(300); // 5 minutes
const status = await window.craft.authPersistence.check();
if (status.isValid) {
  console.log('Session valid for', status.remainingSeconds, 'more seconds');
}
await window.craft.authPersistence.clear();

// ==================== Nice to Have Bridges ====================

// AR (ARKit) - Requires iOS device with A9+ chip
await window.craft.ar.start({planeDetection: true});
window.craft.ar.onPlaneDetected((plane) => {
  console.log('Plane detected:', plane.id, plane.alignment);
});

// Place 3D objects (built-in shapes or .usdz/.scn files)
const obj = await window.craft.ar.placeObject('box', {x: 0, y: 0, z: -0.5});
console.log('Object placed:', obj.objectId);
// Built-in shapes: 'box', 'sphere', 'cylinder', 'cone'
// Or provide URL to .usdz or .scn file

// Get detected planes
const planes = await window.craft.ar.getPlanes();
console.log(planes); // [{id, alignment, center, extent}]

// Remove object
await window.craft.ar.removeObject(obj.objectId);

// Stop AR session
await window.craft.ar.stop();

// ML (Vision Framework)
// First capture an image
const image = await window.craft.openCamera();

// Image Classification - Identify what's in the image
const labels = await window.craft.ml.classifyImage(image);
console.log(labels); // [{label: 'cat', confidence: 0.95}, ...]

// Object Detection - Detect and locate objects
const objects = await window.craft.ml.detectObjects(image);
console.log(objects); // [{labels: [...], boundingBox: {x, y, width, height}}]

// Text Recognition (OCR) - Extract text from image
const textResults = await window.craft.ml.recognizeText(image);
console.log(textResults); // [{text: 'Hello World', confidence: 0.98, boundingBox: {...}}]

// ==================== Widgets (WidgetKit) ====================

// Update widget data - displayed on home screen widget
await window.craft.widget.update({
  title: 'My App',
  subtitle: 'Latest update',
  value: '42',
  icon: 'star.fill' // SF Symbol name
});

// Reload all widgets
await window.craft.widget.reload();

// ==================== Siri Shortcuts ====================

// Register a Siri shortcut
await window.craft.siri.register('Open my app', 'open*app');

// Remove a Siri shortcut
await window.craft.siri.remove('open*app');

// Listen for Siri shortcut invocations
window.craft.siri.onInvoke((detail) => {
  console.log('Siri invoked:', detail.action);
});

// ==================== Watch Connectivity ====================

// Check if watch is reachable
const status = await window.craft.watch.isReachable();
console.log(status.reachable); // true/false

// Send message to watch
const reply = await window.craft.watch.send({
  action: 'ping',
  data: { timestamp: Date.now() }
});

// Update application context (synced to watch)
await window.craft.watch.updateContext({
  lastUpdate: Date.now(),
  status: 'active'
});

// Listen for messages from watch
window.craft.watch.onMessage((message) => {
  console.log('Watch message:', message);
});

// Listen for watch reachability changes
window.craft.watch.onReachabilityChange((status) => {
  console.log('Watch reachable:', status.reachable);
});
```

## CLI Reference

```bash
craft ios init <name>           # Initialize new iOS project
craft ios build                 # Build and generate Xcode project
craft ios open                  # Open Xcode project
craft ios run --simulator       # Run on iOS Simulator

Options:
  --bundle-id <id>          Bundle identifier
  --team-id <id>            Apple Developer Team ID
  --html-path <path>        Path to HTML file
  -d, --dev-server <url>    Development server URL
  -o, --output <dir>        Output directory (default: ./ios)
  -s, --simulator           Run on simulator
```

## Requirements

- macOS with Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Apple Developer account (free or paid)
- iPhone running iOS 15+ (for device deployment)

## Permissions

Add to your Info.plist as needed:

```xml
<!-- Speech Recognition -->
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition for voice commands.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access for speech recognition.</string>

<!-- Camera -->
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to take photos.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs photo library access.</string>

<!-- Location -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs your location.</string>

<!-- Face ID -->
<key>NSFaceIDUsageDescription</key>
<string>This app uses Face ID for authentication.</string>

<!-- NFC -->
<key>NFCReaderUsageDescription</key>
<string>This app reads NFC tags.</string>

<!-- Bluetooth -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth.</string>

<!-- Health -->
<key>NSHealthShareUsageDescription</key>
<string>This app reads health data.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>This app writes health data.</string>

<!-- Contacts -->
<key>NSContactsUsageDescription</key>
<string>This app accesses your contacts.</string>

<!-- Calendar -->
<key>NSCalendarsUsageDescription</key>
<string>This app accesses your calendar.</string>
```

## Runtime Validation

The Zig-native bridge rejects malformed values and overlapping interactive
requests that the legacy Swift dispatcher could silently truncate, coerce, or
abandon. See the
[mobile runtime compatibility guide](../../docs/api/mobile/runtime-compatibility.md)
for the affected input classes and migration guidance.

## Development Mode

For hot-reload during development:

```bash
# Terminal 1: Start your dev server
bun run dev  # e.g., http://localhost:3456

# Terminal 2: Build iOS with dev server
craft ios build --dev-server http://localhost:3456
craft ios open
```

The app will load from your dev server instead of bundled HTML.

## Template compiler gate

On macOS with Xcode and XcodeGen installed, run `bun run test:templates` from
`packages/ios`. It generates a minimal app, a capability-heavy iOS app, and the
same capability-heavy app with a Watch companion. It builds iOS, Live Activity,
Watch extension, and Watch app targets against device SDKs with code signing
disabled. The Watch-enabled iOS target is not built because Xcode requires a
watchOS runtime to resolve its embedded-app graph; its identical Swift source
is built in the sibling capability fixture. This checks the actual generated
Swift and Xcode projects; `bun test` checks the builder's behavior separately.
Temporary projects are removed after the run. Pass `--keep` to retain them for
debugging.

## Publishing

Build for App Store:

```bash
craft publish --ios
```

This will:

1. Build a release archive
2. Output path for manual upload to App Store Connect

## License

MIT

# @craft-native/android

Build native Android apps with web technologies using Craft.

## Features

### Core

- **WebView** - Native Android WebView with full JavaScript support
- **Dark Mode** - Native dark/light theme support

### Input & Feedback

- **Native Speech Recognition** - Android SpeechRecognizer
- **Haptic Feedback** - Vibration patterns for different feedback types
- **Audio Recording** - MediaRecorder with compressed output
- **Video Recording** - Camera video capture

### Device Access

- **Camera & Gallery** - Take photos or pick from gallery
- **Barcode/QR Scanner** - ML Kit barcode scanning
- **File Picker** - Document picker for any file type
- **File Download** - DownloadManager integration

### Sensors & Location

- **Geolocation** - GPS and network location via FusedLocationProvider
- **Motion Sensors** - Accelerometer & gyroscope via SensorManager
- **NFC** - Read NFC tags via NfcAdapter

### Communication

- **Share Sheet** - Native Android sharing
- **Clipboard** - Read and write to system clipboard
- **Push Notifications** - Firebase Cloud Messaging ready

### Security & Auth

- **Biometric Auth** - Fingerprint / Face unlock
- **Social Auth** - Google Sign In
- **Secure Storage** - EncryptedSharedPreferences

### Data & Storage

- **Local Database** - SQLite with full SQL support
- **Bluetooth LE** - BluetoothLeScanner

### System

- **Device Info** - Device model, OS version, screen info
- **Network Status** - Connection type monitoring (WiFi/Cellular)
- **App Badge** - Notification badge count
- **App State** - Foreground/background detection
- **Flashlight** - Camera flash control
- **Open URL** - External browser launch
- **Vibration Pattern** - Custom vibration sequences
- **App Review** - Google Play In-App Review prompt
- **Screen Capture** - Take screenshots programmatically
- **Health/Fitness** - Google Fit integration

## Installation

The Android support is built into the main `craft` CLI:

```bash
bun add craft-native
```

## Quick Start

### 1. Initialize Project

```bash
craft android init MyApp --package com.example.myapp
cd android
```

### 2. Add Your Web Content

Replace `app/src/main/assets/index.html` with your web app, or point to a dev server:

```bash
craft android build --html-path ../dist/index.html
# or
craft android build --dev-server http://192.168.1.100:3456
```

### 3. Open in Android Studio

```bash
craft android open
```

### 4. Run on Device

```bash
craft android run
# or specify device
craft android run --device emulator-5554
```

## Configuration

Edit `craft.config.json` in your Android project:

```json
{
  "appName": "MyApp",
  "packageName": "com.example.myapp",
  "version": "1.0.0",
  "versionCode": 1,
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
  "enableFitness": false,
  "enableScreenCapture": true,
  "minSdk": 24,
  "targetSdk": 34
}
```

## JavaScript Bridge

Once Craft is initialized, the `window.craft` object is available:

```javascript
// Wait for Craft to be ready
window.addEventListener('craftReady', (e) => {
  console.log('Platform:', e.detail.platform); // 'android'
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

// Barcode/QR Scanner (ML Kit)
const scannedCode = await window.craft.scanQRCode();
console.log(scannedCode); // "https://example.com"

// File Picker
const file = await window.craft.pickFile(['image/*', 'application/pdf']);
console.log(file.name, file.data); // base64 encoded

// File Download
await window.craft.downloadFile('https://example.com/file.pdf', 'document.pdf');
await window.craft.saveFile(base64Data, 'image.png', 'image/png');

// Social Auth (Google Sign In)
const user = await window.craft.signInWithGoogle();
console.log(user.userId, user.email, user.displayName, user.idToken);

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

// Bluetooth LE Scanning. Rejects when the device has no adapter, Bluetooth is
// switched off, permission is denied, or the platform scanner cannot start.
await window.craft.bluetooth.startScan();
window.addEventListener('craftBluetoothDevice', (e) => {
  console.log(e.detail.name, e.detail.address, e.detail.rssi);
});
window.craft.bluetooth.stopScan();

// NFC Tag Reading
const nfcData = await window.craft.scanNFC();
console.log(nfcData); // Tag content

// Health/Fitness (Google Fit)
await window.craft.requestFitnessAuthorization();
const steps = await window.craft.getFitnessData('steps', startDate, endDate);

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

// Secure storage (encrypted)
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
console.log(device.model, device.manufacturer, device.systemVersion);

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

// App Review (Google Play In-App Review)
await window.craft.requestReview();

// Flashlight
window.craft.setFlashlight(true);  // turn on
window.craft.setFlashlight(false); // turn off
window.craft.toggleFlashlight();   // toggle

// Open URL (external browser)
window.craft.openURL('https://example.com');

// Vibration Pattern (custom durations in ms)
window.craft.vibrate([100, 50, 100, 50, 200]); // [on, off, on, off, on]

// App State
const state = window.craft.getAppState(); // 'active', 'inactive', 'background'

// App state change listener
window.craft.onAppStateChange((state) => {
  console.log('App state:', state);
});
window.craft.offAppStateChange();

// Logging (appears in Logcat)
window.craft.log('Debug message');

// ==================== High Value Bridges ====================

// Contacts
const contacts = await window.craft.getContacts();
console.log(contacts); // [{id, displayName, phoneNumbers, emailAddresses}]

const newContactId = await window.craft.addContact({
  displayName: 'John Doe',
  phone: '+1234567890',
  email: 'john@example.com'
});

// Calendar Events
const events = await window.craft.getCalendarEvents(startDateMs, endDateMs);
console.log(events); // [{id, title, description, startDate, endDate, location, isAllDay}]

const newEventId = await window.craft.createCalendarEvent({
  title: 'Meeting',
  description: 'Discuss project',
  location: 'Office',
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
  timestamp: Date.now() + 60000, // 1 minute from now
  // or use delay: 60000 // delay in ms
});

await window.craft.cancelNotification('reminder-1');
await window.craft.cancelAllNotifications();

// In-App Purchase (Google Play Billing)
const products = await window.craft.getProducts(['product*id*1', 'product*id*2']);
console.log(products); // [{productId, title, description, price}]

const purchaseResult = await window.craft.purchase('product*id*1');
console.log(purchaseResult); // {purchaseToken, productId, ...}

await window.craft.restorePurchases();

// Keep Screen Awake
window.craft.setKeepAwake(true);  // Prevent screen dimming
window.craft.setKeepAwake(false); // Allow screen dimming

// Orientation Lock
window.craft.lockOrientation('portrait');   // Lock to portrait
window.craft.lockOrientation('landscape');  // Lock to landscape
window.craft.unlockOrientation();           // Allow all orientations

// ==================== Medium Value Bridges ====================

// Background Tasks are not implemented on Android. These methods reject
// instead of reporting that work was scheduled when no worker can run.
try {
  await window.craft.backgroundTask.schedule('sync-data', {
    delay: 900,
    requiresNetwork: true,
    requiresCharging: false
  });
} catch (error) {
  console.error(error);
}

// PDF Viewer (opens in external PDF app)
await window.craft.openPDF('https://example.com/document.pdf');
await window.craft.openPDF(base64PdfData, 5); // Open at page 5
await window.craft.closePDF();

// Contacts Picker (shows native picker UI)
const contact = await window.craft.pickContact();
console.log(contact); // {id, displayName, phoneNumbers, emailAddresses}

const contacts = await window.craft.pickContact({multiple: true}); // Select multiple

// App Shortcuts (Android 7.1+, long press)
await window.craft.shortcuts.set([
  {type: 'new-message', title: 'New Message', subtitle: 'Start composing'},
  {type: 'search', title: 'Search'}
]);
window.craft.shortcuts.onShortcut((shortcut) => {
  console.log('Shortcut activated:', shortcut.type);
});
await window.craft.shortcuts.clear();

// Shared Preferences (cross-app data with named groups)
await window.craft.sharedKeychain.set('user*token', 'abc123', 'mygroup'); // group optional
const result = await window.craft.sharedKeychain.get('user*token', 'mygroup');
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

// AR (ARCore) - Note: Full ARCore requires native Activity integration
// Use Sceneform or AR Fragment for complete AR functionality
// The bridge API is consistent with iOS for cross-platform code:
await window.craft.ar.start({planeDetection: true});
// Returns error on Android: "ARCore requires native Activity integration"

// ML (ML Kit) - Full support for ML operations
// First capture an image
const image = await window.craft.openCamera();

// Image Classification (Labeling) - Identify what's in the image
const labels = await window.craft.ml.classifyImage(image);
console.log(labels); // [{label: 'Food', confidence: 0.95, index: 1}, ...]

// Object Detection - Detect and locate objects
const objects = await window.craft.ml.detectObjects(image);
console.log(objects); // [{labels: [...], boundingBox: {x, y, width, height}, trackingId: 1}]

// Text Recognition (OCR) - Extract text from image
const textResults = await window.craft.ml.recognizeText(image);
console.log(textResults); // [{text: 'Hello World', confidence: 0.98, boundingBox: {...}}]

// ==================== Widgets (AppWidgetProvider) ====================

// Update widget data - displayed on home screen widget
await window.craft.widget.update({
  title: 'My App',
  subtitle: 'Latest update',
  value: '42',
  icon: 'ic*star' // Android drawable name
});

// Reload all widgets
await window.craft.widget.reload();

// ==================== Google Assistant (App Actions) ====================

// App Actions are declared statically in app/src/main/res/xml/shortcuts.xml.
// Listen for incoming Google Assistant intents forwarded by the bridge.
window.addEventListener('craftVoiceAction', (event) => {
  console.log('Voice action:', event.detail.action);
});

// ==================== Wear OS Connectivity ====================

// Note: Full Wear OS support requires a companion watch app
// This provides the JavaScript API for future integration

// Check if watch is reachable
const status = await window.craft.watch.isReachable();
console.log(status.reachable); // true/false

// Send message to watch (requires companion app)
const reply = await window.craft.watch.send({
  action: 'ping',
  data: { timestamp: Date.now() }
});

// Update application context
await window.craft.watch.updateContext({
  lastUpdate: Date.now(),
  status: 'active'
});

// Listen for messages from watch
window.craft.watch.onMessage((message) => {
  console.log('Watch message:', message);
});
```

## CLI Reference

```bash
craft android init <name>       # Initialize new Android project
craft android build             # Build APK
craft android build --release   # Build release APK
craft android build --watch     # Watch for changes and rebuild
craft android open              # Open in Android Studio
craft android run               # Run on connected device/emulator

Options:
  --package <name>        Package name (e.g., com.example.app)
  --html-path <path>      Path to HTML file
  -d, --dev-server <url>  Development server URL
  -o, --output <dir>      Output directory (default: ./android)
  --release               Build release APK
  -w, --watch             Watch mode
  -d, --device <id>       Target device ID
```

## Requirements

- Android Studio with Android SDK
- JDK 17+
- Gradle 8.4+
- ADB (for device deployment)

## Permissions

Add to your AndroidManifest.xml as needed:

```xml
<!-- Speech Recognition -->
<uses-permission android:name="android.permission.RECORD*AUDIO" />

<!-- Camera -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.WRITE*EXTERNAL*STORAGE" />

<!-- Location -->
<uses-permission android:name="android.permission.ACCESS*FINE*LOCATION" />
<uses-permission android:name="android.permission.ACCESS*COARSE*LOCATION" />

<!-- Biometric -->
<uses-permission android:name="android.permission.USE*BIOMETRIC" />

<!-- Vibration -->
<uses-permission android:name="android.permission.VIBRATE" />

<!-- NFC -->
<uses-permission android:name="android.permission.NFC" />
<uses-feature android:name="android.hardware.nfc" android:required="false" />

<!-- Bluetooth -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH*ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH*SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH*CONNECT" />

<!-- Fitness (Google Fit) -->
<uses-permission android:name="android.permission.ACTIVITY*RECOGNITION" />

<!-- Contacts -->
<uses-permission android:name="android.permission.READ*CONTACTS" />
<uses-permission android:name="android.permission.WRITE*CONTACTS" />

<!-- Calendar -->
<uses-permission android:name="android.permission.READ*CALENDAR" />
<uses-permission android:name="android.permission.WRITE*CALENDAR" />

<!-- Notifications (Android 13+) -->
<uses-permission android:name="android.permission.POST*NOTIFICATIONS" />
```

## Development Mode

For hot-reload during development:

```bash
# Terminal 1: Start your dev server
bun run dev  # e.g., http://localhost:3456

# Terminal 2: Build Android with dev server (use your Mac's IP)
craft android build --dev-server http://192.168.1.100:3456

# Open in Android Studio and run on device
craft android open
```

The app will load from your dev server instead of bundled HTML.

## Publishing

Build release APK/AAB:

```bash
craft publish --android
```

This will:

1. Build a release AAB (Android App Bundle)
2. Output path for manual upload to Play Console

For automated uploads, integrate with fastlane:
```bash
fastlane supply --aab ./android/app/build/outputs/bundle/release/app-release.aab
```

## License

MIT

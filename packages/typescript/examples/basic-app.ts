/**
 * Craft Mobile Bridge - TypeScript Example
 *
 * This example demonstrates how to use the Craft mobile bridges
 * with full TypeScript type safety. These APIs are injected by the
 * native iOS/Android runtime as `window.craft` and are only available
 * when running inside a Craft mobile app (not in the desktop SDK).
 *
 * NOTE: Some features shown here require specific platform capabilities:
 * - AR (craft.ar): iOS only, requires A9+ chip and ARKit support
 * - ML (craft.ml): iOS (Core ML/Vision) and Android (ML Kit) only
 * - Deep Links (craft.deepLinks): Requires URL scheme or universal links setup
 * - Auth Persistence (craft.authPersistence): iOS/Android biometric session caching
 * - OTA Updates (craft.ota): Requires server-side update infrastructure
 * - Widgets (craft.widget): iOS 14+ (WidgetKit) / Android (AppWidgetProvider)
 *
 * These APIs are NOT part of the desktop TypeScript SDK (craft-native).
 * For desktop APIs, see the main SDK exports in src/index.ts.
 *
 * Usage:
 * 1. Copy this file to your web content directory
 * 2. Import the types in your tsconfig.json
 * 3. Build and run in your Craft-powered iOS or Android app
 */

/// <reference path="../types/craft.d.ts" />

// ============================================================================
// Type-safe Craft API Usage Examples
// ============================================================================

/**
 * Wait for Craft to be ready before using any APIs
 */
function initializeApp(): void {
  window.addEventListener('craftReady', (event: CraftReadyEvent) => {
    console.log('Craft is ready!');
    console.log('Platform:', event.detail.platform);
    console.log('Capabilities:', event.detail.capabilities);

    // Now safe to use all Craft APIs
    setupEventListeners();
    initializeFeatures();
  });
}

/**
 * Set up event listeners for various Craft events
 */
function setupEventListeners(): void {
  // Deep link handling
  if (craft.deepLinks) {
    craft.deepLinks.onLink((data: DeepLinkData) => {
      // initializeFeatures() asks getInitialURL() for the launch link after
      // other awaits, so it would arrive here too.
      if (data.initial) return;
      console.log('Deep link received:', data.url);
      console.log('Host:', data.host);
      console.log('Path:', data.path);
      console.log('Query params:', data.queryParams);

      // Handle the deep link
      handleDeepLink(data);
    });
  }

  // App state changes (using bridge method API)
  craft.onAppStateChange((state: 'active' | 'inactive' | 'background') => {
    console.log('App state changed:', state);

    if (state === 'background') {
      // Save state, pause operations
      saveAppState();
    }
else if (state === 'active') {
      // Restore state, resume operations
      restoreAppState();
    }
  });

  // Network status changes (using bridge method API)
  craft.onNetworkChange((status: NetworkStatus) => {
    console.log('Network status:', status);
    updateUIForNetwork(status);
  });

  // Error handling (craftError is a custom event fired by the bridge)
  window.addEventListener('craftError', ((event: CraftErrorEvent) => {
    console.error('Craft error:', event.detail.code, event.detail.message);
    reportError(event.detail as CraftErrorDetail);
  }) as EventListener);
}

/**
 * Initialize app features
 */
async function initializeFeatures(): Promise<void> {
  // Check for OTA updates
  await checkForUpdates();

  // Get device info
  const deviceInfo = craft.getDeviceInfo();
  console.log('Device:', deviceInfo.model, 'OS:', deviceInfo.systemVersion);

  // Check initial deep link
  if (craft.deepLinks) {
    const initialURL = await craft.deepLinks.getInitialURL();
    if (initialURL) {
      handleDeepLink(initialURL);
    }
  }
}

// ============================================================================
// Feature Examples
// ============================================================================

/**
 * Example: Camera and image handling
 * NOTE: ML features (craft.ml) require iOS (Core ML/Vision) or Android (ML Kit).
 * They are not available on desktop platforms.
 */
async function captureAndProcessImage(): Promise<void> {
  try {
    // Open camera with type-safe return
    const imageBase64: string | null = await craft.openCamera();

    if (imageBase64) {
      console.log('Image captured, size:', imageBase64.length);

      // Use ML to classify the image (mobile only)
      if (craft.ml) {
        const classifications = await craft.ml.classifyImage(imageBase64);
        console.log('Classifications:', classifications);

        // Extract text from image
        const textResults = await craft.ml.recognizeText(imageBase64);
        console.log('Detected text:', textResults);
      }
    }
  }
catch (error) {
    console.error('Camera error:', error);
  }
}

/**
 * Example: Biometric authentication with persistence
 * NOTE: Auth persistence (craft.authPersistence) caches biometric sessions
 * for a specified duration. Available on iOS (Face ID/Touch ID) and Android (BiometricPrompt).
 */
async function authenticateUser(): Promise<boolean> {
  try {
    // Check if we have a valid auth session (mobile only)
    if (craft.authPersistence) {
      const session = await craft.authPersistence.check();
      if (session.isValid) {
        console.log('Auth session still valid, expires in', session.remainingSeconds, 'seconds');
        return true;
      }
    }

    // Perform biometric authentication
    const authenticated = await craft.authenticate('Please authenticate to continue');

    if (authenticated && craft.authPersistence) {
      // Enable auth persistence for 5 minutes
      await craft.authPersistence.enable(300);
    }

    return authenticated;
  }
catch (error) {
    console.error('Authentication failed:', error);
    return false;
  }
}

/**
 * Example: Secure storage operations
 */
async function secureStorageExample(): Promise<void> {
  try {
    // Store sensitive data
    await craft.secureStore.set('auth_token', 'jwt_token_here');
    await craft.secureStore.set('user_id', '12345');

    // Retrieve data
    const token = await craft.secureStore.get('auth_token');
    console.log('Retrieved token:', token ? 'exists' : 'not found');

    // Delete when done
    await craft.secureStore.remove('auth_token');
  }
catch (error) {
    console.error('Secure storage error:', error);
  }
}

/**
 * Example: Local database operations
 */
async function databaseExample(): Promise<void> {
  try {
    // Create table
    await craft.db.execute(`
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // Insert data with parameters
    await craft.db.execute(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['John Doe', 'john@example.com']
    );

    // Query data
    const users = await craft.db.query<{ id: number; name: string; email: string }>(
      'SELECT * FROM users WHERE name LIKE ?',
      ['%John%']
    );

    console.log('Found users:', users);
  }
catch (error) {
    console.error('Database error:', error);
  }
}

/**
 * Example: Contacts integration
 */
async function contactsExample(): Promise<void> {
  try {
    // Get all contacts
    const contacts = await craft.getContacts();
    console.log(`Found ${contacts.length} contacts`);

    // Pick a contact with native UI
    const selectedContact = await craft.pickContact({ multiple: false });
    if (selectedContact) {
      console.log('Selected:', selectedContact.displayName);
    }

    // Add a new contact
    const newContactId = await craft.addContact({
      givenName: 'Jane',
      familyName: 'Doe',
      phone: '+1-555-123-4567',
      email: 'jane@example.com'
    });
    console.log('Created contact:', newContactId);
  }
catch (error) {
    console.error('Contacts error:', error);
  }
}

/**
 * Example: Calendar integration
 */
async function calendarExample(): Promise<void> {
  try {
    const now = Date.now();
    const oneWeekLater = now + 7 * 24 * 60 * 60 * 1000;

    // Get upcoming events
    const events = await craft.getCalendarEvents(now, oneWeekLater);
    console.log(`Found ${events.length} events this week`);

    // Create a new event
    const eventId = await craft.createCalendarEvent({
      title: 'Team Meeting',
      location: 'Conference Room A',
      notes: 'Quarterly review',
      startDate: now + 2 * 60 * 60 * 1000, // 2 hours from now
      endDate: now + 3 * 60 * 60 * 1000, // 3 hours from now
      isAllDay: false
    });
    console.log('Created event:', eventId);
  }
catch (error) {
    console.error('Calendar error:', error);
  }
}

/**
 * Example: Local notifications
 */
async function notificationExample(): Promise<void> {
  try {
    // Schedule a notification
    const notificationId = await craft.scheduleNotification({
      id: 'reminder-1',
      title: 'Reminder',
      body: 'Don\'t forget your meeting!',
      badge: 1,
      delay: 60000 // 1 minute from now
    });
    console.log('Scheduled notification:', notificationId);

    // Get pending notifications
    const pending = await craft.getPendingNotifications();
    console.log('Pending notifications:', pending.length);

    // Cancel if needed
    // await craft.cancelNotification(notificationId);
  }
catch (error) {
    console.error('Notification error:', error);
  }
}

/**
 * Example: In-app purchases
 */
async function purchaseExample(): Promise<void> {
  try {
    // Get available products
    const products = await craft.getProducts(['premium_monthly', 'premium_yearly']);
    console.log('Available products:', products);

    if (products.length > 0) {
      // Display products to user and let them select
      const selectedProduct = products[0];
      console.log(`Selected: ${selectedProduct.title} - ${selectedProduct.price}`);

      // Initiate purchase
      const purchaseResult = await craft.purchase(selectedProduct.id);
      console.log('Purchase result:', purchaseResult);
    }

    // Restore purchases for returning users
    const restored = await craft.restorePurchases();
    console.log('Restored purchases:', restored);
  }
catch (error) {
    console.error('Purchase error:', error);
  }
}

/**
 * Example: OTA Updates
 * NOTE: OTA updates (craft.ota) require server-side infrastructure.
 * Available on iOS and Android only. Not available on desktop platforms.
 */
async function checkForUpdates(): Promise<void> {
  if (!craft.ota) return;

  try {
    // Configure OTA (usually done once at app startup)
    craft.ota.configure({
      updateUrl: 'https://updates.yourapp.com/api/check',
      checkOnLaunch: true,
      checkInterval: 3600000 // 1 hour
    });

    // Set up progress listener
    craft.ota.onProgress((progress: OTAProgress) => {
      console.log(`Download progress: ${progress.percent}%`);
    });

    craft.ota.onStatusChange((status: OTAStatus) => {
      console.log('OTA status:', status);
    });

    // Check for updates
    const update = await craft.ota.checkForUpdate();
    if (update && update.available) {
      console.log(`Update available: v${update.version}`);
      console.log('Release notes:', update.releaseNotes);

      if (update.mandatory) {
        // Force update
        await craft.ota.downloadUpdate();
        await craft.ota.applyUpdate();
      }
else {
        // Prompt user
        // showUpdatePrompt(update);
      }
    }
  }
catch (error) {
    console.error('OTA check failed:', error);
  }
}

/**
 * Example: Performance profiling
 */
async function profilePerformance(): Promise<void> {
  // Start profiling
  craft.startProfiling();

  // Perform operations to measure
  performHeavyOperations();

  // Stop and get report
  const report = await craft.stopProfiling();
  if (report) {
    console.log('Profiling Report:');
    console.log('- Bridge calls:', report.bridgeCalls);
    console.log('- Duration:', report.duration, 'ms');
    console.log('- Average call time:', report.avgCallTime, 'ms');
    console.log('- Call timings:', report.callTimings);
  }
}

/**
 * Example: AR features (iOS)
 * NOTE: AR requires an iOS device with A9+ chip and ARKit support.
 * This bridge is not available on Android or desktop platforms.
 */
async function arExample(): Promise<void> {
  if (!craft.ar) {
    console.log('AR not available');
    return;
  }

  try {
    // Start AR session
    await craft.ar.start({ planeDetection: true });

    // Listen for plane detection
    window.addEventListener('craftARPlane', ((event: CraftARPlaneEvent) => {
      console.log('Plane detected:', event.detail.type, event.detail.id);
    }) as EventListener);

    // Place a 3D object
    const objectId = await craft.ar.placeObject('box', { x: 0, y: 0, z: -1 });
    console.log('Placed object:', objectId);

    // Get detected planes
    const planes = await craft.ar.getPlanes();
    console.log('Detected planes:', planes);

    // Stop AR session when done
    // await craft.ar.stop();
  }
catch (error) {
    console.error('AR error:', error);
  }
}

/**
 * Example: Widget updates
 * NOTE: Widgets require iOS 14+ (WidgetKit) or Android (AppWidgetProvider).
 * Not available on desktop platforms.
 */
async function updateWidget(): Promise<void> {
  if (!craft.widget) return;

  try {
    await craft.widget.update({
      title: 'My App',
      subtitle: 'Updated just now',
      value: '42',
      icon: 'star.fill'
    });

    // Force widget refresh
    await craft.widget.reload();
  }
catch (error) {
    console.error('Widget error:', error);
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

function handleDeepLink(data: DeepLinkData): void {
  const { path, queryParams } = data;

  switch (path) {
    case '/product':
      if (queryParams?.id) {
        // Navigate to product page
        console.log('Opening product:', queryParams.id);
      }
      break;
    case '/profile':
      // Navigate to profile
      console.log('Opening profile');
      break;
    default:
      console.log('Unknown deep link path:', path);
  }
}

function saveAppState(): void {
  console.log('Saving app state...');
}

function restoreAppState(): void {
  console.log('Restoring app state...');
}

function updateUIForNetwork(status: NetworkStatus): void {
  if (!status.isConnected) {
    console.log('No network connection');
  }
else {
    console.log('Connected via:', status.type);
  }
}

function reportError(error: CraftErrorDetail): void {
  // Send to analytics or error tracking service
  console.error('Error:', error.code, error.message);
}

function performHeavyOperations(): void {
  // Simulate heavy operations
  for (let i = 0; i < 1000; i++) {
    craft.log(`Operation ${i}`);
  }
}

// ============================================================================
// Initialize
// ============================================================================

initializeApp();

/**
 * Craft Native Bridge TypeScript Definitions
 * @package craft-native
 */

declare global {
  interface Window {
    craft: CraftBridge;
  }
}

export interface CraftBridge {
  /** Platform identifier: 'ios' | 'android' */
  platform: 'ios' | 'android';

  /** Available capabilities on the current device */
  capabilities: CraftCapabilities;

  // ==================== Debug & Error Handling ====================

  /**
   * Enable or disable debug mode
   * When enabled, captures console logs, network requests, and bridge calls
   * @param enabled - Whether to enable debug mode
   */
  setDebugMode(enabled: boolean): void;

  /**
   * Get details about the last error
   * @returns Last error info or null
   */
  getLastError(): CraftErrorDetail | null;

  /**
   * Get bridge call log (only available when debug mode is on)
   * @returns Array of logged calls
   */
  getCallLog(): CraftCallLogEntry[];

  /**
   * Clear the call log
   */
  clearCallLog(): void;

  /**
   * Get error history (up to 50 most recent errors)
   * @returns Array of error details
   */
  getErrorHistory(): CraftErrorDetail[];

  /**
   * Clear error history and last error
   */
  clearErrorHistory(): void;

  /**
   * Get user-friendly error message for an error code
   * @param code - Error code
   * @returns Human-readable error message
   */
  getErrorMessage(code: CraftErrorCode): string;

  /**
   * Get captured console logs (requires debug mode)
   * @returns Array of console log entries
   */
  getConsoleLog(): ConsoleLogEntry[];

  /**
   * Clear captured console logs
   */
  clearConsoleLog(): void;

  /**
   * Get captured network requests (requires debug mode)
   * @returns Array of network request entries
   */
  getNetworkLog(): NetworkLogEntry[];

  /**
   * Clear captured network logs
   */
  clearNetworkLog(): void;

  /**
   * Get full debug report with all captured data
   * @returns Complete debug report
   */
  getDebugReport(): DebugReport;

  // ==================== Performance Profiling ====================

  /**
   * Start performance profiling
   * Tracks bridge call timings and memory usage
   * @returns Profiling start info
   */
  startProfiling(): { started: boolean; timestamp: number };

  /**
   * Stop profiling and get report
   * @returns Profiling report with timing data
   */
  stopProfiling(): Promise<ProfilingReport | null>;

  /**
   * Get current profiling data without stopping
   * @returns Current profiling state or null if not profiling
   */
  getProfilingData(): ProfilingData | null;

  // ==================== Core ====================

  /**
   * Trigger haptic feedback
   * @param style - Feedback style: 'light', 'medium', 'heavy', 'success', 'warning', 'error', 'selection'
   */
  haptic(style: HapticStyle): void;

  /**
   * Open native share sheet
   * @param text - Text to share
   * @param title - Optional title
   */
  share(text: string, title?: string): void;

  /**
   * Log message to native console (Xcode/Logcat)
   * @param message - Message to log
   */
  log(message: string): void;

  /**
   * Get device information
   */
  getDeviceInfo(): DeviceInfo;

  // ==================== Camera & Media ====================

  /**
   * Open camera to capture photo
   * @returns Base64-encoded image data
   */
  openCamera(): Promise<string>;

  /**
   * Open photo gallery to pick image
   * @returns Base64-encoded image data
   */
  pickImage(): Promise<string>;

  /**
   * Scan QR code or barcode
   * @returns Scanned code content
   */
  scanQRCode(): Promise<string>;

  /**
   * Take screenshot of current view
   * @returns Base64-encoded image data
   */
  takeScreenshot(): Promise<string>;

  // ==================== Audio/Video Recording ====================

  /**
   * Start audio recording
   */
  startAudioRecording(): Promise<void>;

  /**
   * Stop audio recording
   * @returns Base64-encoded audio data
   */
  stopAudioRecording(): Promise<string>;

  /**
   * Start video recording
   * @returns Base64-encoded video data
   */
  startVideoRecording(): Promise<string>;

  // ==================== Speech Recognition ====================

  /**
   * Start speech recognition
   */
  startListening(): void;

  /**
   * Stop speech recognition
   */
  stopListening(): void;

  // ==================== Files ====================

  /**
   * Open file picker
   * @param types - Optional array of MIME types or UTI types
   * @returns Selected file with name and base64 data
   */
  pickFile(types?: string[]): Promise<PickedFile>;

  /**
   * Download file from URL
   * @param url - URL to download
   * @param filename - Filename to save as
   */
  downloadFile(url: string, filename: string): Promise<void>;

  /**
   * Save data as file
   * @param base64Data - Base64-encoded file data
   * @param filename - Filename
   * @param mimeType - MIME type
   */
  saveFile(base64Data: string, filename: string, mimeType: string): Promise<void>;

  // ==================== Location ====================

  /**
   * Get current position
   * @returns Position with latitude, longitude, accuracy
   */
  getCurrentPosition(): Promise<Position>;

  /**
   * Watch position for continuous updates
   * @param callback - Function called with new position
   * @returns Watch ID
   */
  watchPosition(callback: (position: Position) => void): string;

  /**
   * Clear position watch
   * @param watchId - Watch ID from watchPosition
   */
  clearWatch(watchId: string): void;

  // ==================== Sensors ====================

  /**
   * Start motion sensor updates (accelerometer + gyroscope)
   */
  startMotionUpdates(): void;

  /**
   * Stop motion sensor updates
   */
  stopMotionUpdates(): void;

  // ==================== Contacts ====================

  /**
   * Get all contacts
   * @returns Array of contacts
   */
  getContacts(): Promise<Contact[]>;

  /**
   * Add a new contact
   * @param contact - Contact data
   * @returns New contact ID
   */
  addContact(contact: NewContact): Promise<string>;

  /**
   * Open native contact picker
   * @param options - Picker options
   * @returns Selected contact(s)
   */
  pickContact(options?: { multiple?: boolean }): Promise<Contact | Contact[]>;

  // ==================== Calendar ====================

  /**
   * Get calendar events in date range
   * @param startDate - Start date (timestamp)
   * @param endDate - End date (timestamp)
   * @returns Array of events
   */
  getCalendarEvents(startDate: number, endDate: number): Promise<CalendarEvent[]>;

  /**
   * Create a calendar event
   * @param event - Event data
   * @returns New event ID
   */
  createCalendarEvent(event: NewCalendarEvent): Promise<string>;

  /**
   * Delete a calendar event
   * @param eventId - Event ID
   */
  deleteCalendarEvent(eventId: string): Promise<void>;

  // ==================== Local Notifications ====================

  /**
   * Schedule a local notification
   * @param notification - Notification data
   * @returns Notification ID
   */
  scheduleNotification(notification: NotificationData): Promise<string>;

  /**
   * Cancel a scheduled notification
   * @param id - Notification ID
   */
  cancelNotification(id: string): Promise<void>;

  /**
   * Cancel all scheduled notifications
   */
  cancelAllNotifications(): Promise<void>;

  /**
   * Get pending notifications (iOS only)
   */
  getPendingNotifications(): Promise<PendingNotification[]>;

  // ==================== In-App Purchase ====================

  /**
   * Get product information
   * @param productIds - Array of product IDs
   * @returns Array of products
   */
  getProducts(productIds: string[]): Promise<Product[]>;

  /**
   * Purchase a product
   * @param productId - Product ID
   * @returns Purchase result
   */
  purchase(productId: string): Promise<PurchaseResult>;

  /**
   * Restore previous purchases
   */
  restorePurchases(): Promise<void>;

  // ==================== Auth & Security ====================

  /**
   * Authenticate with biometrics (Face ID / Touch ID / Fingerprint)
   * @param reason - Authentication prompt text
   * @returns true if authenticated
   */
  authenticate(reason: string): Promise<boolean>;

  /**
   * Sign in with Apple (iOS only)
   * @returns User credentials
   */
  signInWithApple(): Promise<AppleUser>;

  /**
   * Sign in with Google (Android only)
   * @returns User credentials
   */
  signInWithGoogle(): Promise<GoogleUser>;

  /**
   * Register for push notifications
   * @returns Push token
   */
  registerPush(): Promise<string>;

  // ==================== Secure Storage ====================
  secureStore: {
    /**
     * Store value securely
     * @param key - Key
     * @param value - Value
     */
    set(key: string, value: string): Promise<void>;

    /**
     * Get value from secure storage
     * @param key - Key
     * @returns Value or null
     */
    get(key: string): Promise<string | null>;

    /**
     * Remove value from secure storage
     * @param key - Key
     */
    remove(key: string): Promise<void>;
  };

  // ==================== Clipboard ====================
  clipboard: {
    /**
     * Write text to clipboard
     * @param text - Text to copy
     */
    write(text: string): Promise<void>;

    /**
     * Read text from clipboard
     * @returns Clipboard text
     */
    read(): Promise<string>;
  };

  // ==================== Database ====================
  db: {
    /**
     * Execute SQL statement
     * @param sql - SQL statement
     * @param params - Optional parameters
     */
    execute(sql: string, params?: any[]): Promise<void>;

    /**
     * Query database
     * @param sql - SQL query
     * @param params - Optional parameters
     * @returns Query results
     */
    query(sql: string, params?: any[]): Promise<any[]>;
  };

  // ==================== Network & Connectivity ====================

  /**
   * Get current network status
   */
  getNetworkStatus(): NetworkStatus;

  /**
   * Listen for network status changes
   * @param callback - Function called on status change
   */
  onNetworkChange(callback: (status: NetworkStatus) => void): void;

  /**
   * Remove network change listener
   */
  offNetworkChange(): void;

  /**
   * Start Bluetooth LE scan
   */
  startBluetoothScan(): void;

  /**
   * Stop Bluetooth LE scan
   */
  stopBluetoothScan(): void;

  /**
   * Scan NFC tag
   * @returns Tag content
   */
  scanNFC(): Promise<string>;

  // ==================== System ====================

  /**
   * Set flashlight on/off
   * @param enabled - Enable or disable
   */
  setFlashlight(enabled: boolean): void;

  /**
   * Toggle flashlight
   */
  toggleFlashlight(): void;

  /**
   * Vibrate with pattern
   * @param pattern - Array of durations in ms [on, off, on, off, ...]
   */
  vibrate(pattern: number[]): void;

  /**
   * Open URL in external browser
   * @param url - URL to open
   */
  openURL(url: string): void;

  /**
   * Get current app state
   * @returns 'active', 'inactive', or 'background'
   */
  getAppState(): 'active' | 'inactive' | 'background';

  /**
   * Listen for app state changes
   * @param callback - Function called on state change
   */
  onAppStateChange(callback: (state: 'active' | 'inactive' | 'background') => void): void;

  /**
   * Remove app state change listener
   */
  offAppStateChange(): void;

  /**
   * Set app badge count
   * @param count - Badge count
   */
  setBadge(count: number): void;

  /**
   * Clear app badge
   */
  clearBadge(): void;

  /**
   * Request app review
   */
  requestReview(): Promise<void>;

  /**
   * Set keep screen awake
   * @param enabled - Enable or disable
   */
  setKeepAwake(enabled: boolean): void;

  /**
   * Lock screen orientation
   * @param orientation - 'portrait' or 'landscape'
   */
  lockOrientation(orientation: 'portrait' | 'landscape'): void;

  /**
   * Unlock screen orientation
   */
  unlockOrientation(): void;

  // ==================== Health/Fitness ====================

  /**
   * Request health data authorization (iOS)
   * @param types - Data types to request
   */
  requestHealthAuthorization(types: string[]): Promise<void>;

  /**
   * Get health data (iOS)
   * @param type - Data type
   * @param startDate - Start date
   * @param endDate - End date
   */
  getHealthData(type: string, startDate: Date, endDate: Date): Promise<any>;

  /**
   * Request fitness authorization (Android)
   */
  requestFitnessAuthorization(): Promise<void>;

  /**
   * Get fitness data (Android)
   * @param type - Data type
   * @param startDate - Start date
   * @param endDate - End date
   */
  getFitnessData(type: string, startDate: Date, endDate: Date): Promise<any>;

  // ==================== Background Tasks ====================
  backgroundTask: {
    /**
     * Register a background task
     * @param taskId - Task identifier
     */
    register(taskId: string): Promise<{ registered: boolean }>;

    /**
     * Schedule a background task
     * @param taskId - Task identifier
     * @param options - Schedule options
     */
    schedule(taskId: string, options: BackgroundTaskOptions): Promise<{ scheduled: boolean }>;

    /**
     * Cancel a background task
     * @param taskId - Task identifier
     */
    cancel(taskId: string): Promise<{ cancelled: boolean }>;

    /**
     * Cancel all background tasks
     */
    cancelAll(): Promise<{ cancelled: boolean }>;
  };

  // ==================== PDF Viewer ====================

  /**
   * Open PDF in native viewer
   * @param source - URL or base64 data
   * @param page - Optional starting page
   */
  openPDF(source: string, page?: number): Promise<{ opened: boolean }>;

  /**
   * Close PDF viewer
   */
  closePDF(): Promise<{ closed: boolean }>;

  // ==================== App Shortcuts ====================
  shortcuts: {
    /**
     * Set app shortcuts (3D Touch / long press)
     * @param shortcuts - Array of shortcuts
     */
    set(shortcuts: AppShortcut[]): Promise<{ set: boolean }>;

    /**
     * Clear all shortcuts
     */
    clear(): Promise<{ cleared: boolean }>;

    /**
     * Listen for shortcut activation
     * @param callback - Function called when shortcut activated
     */
    onShortcut(callback: (shortcut: { type: string }) => void): void;
  };

  // ==================== Shared Keychain ====================
  sharedKeychain: {
    /**
     * Store value in shared keychain/preferences
     * @param key - Key
     * @param value - Value
     * @param group - Optional access group (iOS) or preference file (Android)
     */
    set(key: string, value: string, group?: string): Promise<{ set: boolean }>;

    /**
     * Get value from shared keychain/preferences
     * @param key - Key
     * @param group - Optional access group (iOS) or preference file (Android)
     */
    get(key: string, group?: string): Promise<{ value: string | null }>;

    /**
     * Remove value from shared keychain/preferences
     * @param key - Key
     * @param group - Optional access group
     */
    remove(key: string, group?: string): Promise<{ removed: boolean }>;
  };

  // ==================== Auth Persistence ====================
  authPersistence: {
    /**
     * Enable biometric session persistence
     * @param duration - Duration in seconds
     */
    enable(duration: number): Promise<AuthPersistenceResult>;

    /**
     * Disable biometric session persistence
     */
    disable(): Promise<{ enabled: boolean }>;

    /**
     * Check if session is still valid
     */
    check(): Promise<{ isValid: boolean; remainingSeconds: number }>;

    /**
     * Clear session
     */
    clear(): Promise<{ cleared: boolean }>;
  };

  // ==================== AR (ARKit/ARCore) ====================
  ar: {
    /**
     * Start AR session
     * @param options - AR options
     */
    start(options?: AROptions): Promise<{ started: boolean }>;

    /**
     * Stop AR session
     */
    stop(): Promise<{ stopped: boolean }>;

    /**
     * Place 3D object in AR scene
     * @param model - Model name ('box', 'sphere', 'cylinder', 'cone') or .usdz/.scn URL
     * @param position - Position in 3D space
     */
    placeObject(model: string, position?: ARPosition): Promise<{ objectId: string; placed: boolean }>;

    /**
     * Remove object from AR scene
     * @param objectId - Object ID from placeObject
     */
    removeObject(objectId: string): Promise<{ removed: boolean }>;

    /**
     * Get detected planes
     */
    getPlanes(): Promise<ARPlane[]>;

    /**
     * Listen for plane detection events
     * @param callback - Function called when plane detected/updated/removed
     */
    onPlaneDetected(callback: (plane: ARPlaneEvent) => void): void;
  };

  // ==================== ML (Core ML / ML Kit) ====================
  ml: {
    /**
     * Classify image contents
     * @param imageBase64 - Base64-encoded image
     * @returns Classification results
     */
    classifyImage(imageBase64: string): Promise<ClassificationResult[]>;

    /**
     * Detect objects in image
     * @param imageBase64 - Base64-encoded image
     * @returns Object detection results
     */
    detectObjects(imageBase64: string): Promise<ObjectDetectionResult[]>;

    /**
     * Recognize text in image (OCR)
     * @param imageBase64 - Base64-encoded image
     * @returns Text recognition results
     */
    recognizeText(imageBase64: string): Promise<TextRecognitionResult[]>;
  };

  // ==================== Widgets (WidgetKit / AppWidgetProvider) ====================
  widget: {
    /**
     * Update widget data
     * @param data - Widget data to display
     */
    update(data: WidgetData): Promise<{ updated: boolean }>;

    /**
     * Reload all widgets
     */
    reload(): Promise<{ reloaded: boolean }>;
  };

  // ==================== Siri / Google Assistant ====================
  siri: {
    /**
     * Register a Siri shortcut (iOS) or App Action (Android)
     * @param phrase - The trigger phrase
     * @param action - Action identifier
     */
    register(phrase: string, action: string): Promise<{ registered: boolean; action: string; phrase: string }>;

    /**
     * Remove a Siri shortcut
     * @param action - Action identifier to remove
     */
    remove(action: string): Promise<{ removed: boolean; action: string }>;

    /**
     * Listen for Siri shortcut invocations
     * @param callback - Called when shortcut is invoked
     */
    onInvoke(callback: (detail: SiriInvocationEvent) => void): void;
  };

  // ==================== Watch Connectivity ====================
  watch: {
    /**
     * Send message to paired watch
     * @param message - Message data to send
     */
    send(message: Record<string, any>): Promise<Record<string, any>>;

    /**
     * Update application context (synced to watch)
     * @param context - Context data to sync
     */
    updateContext(context: Record<string, any>): Promise<{ updated: boolean }>;

    /**
     * Check if watch is reachable
     */
    isReachable(): Promise<{ reachable: boolean }>;

    /**
     * Listen for messages from watch
     * @param callback - Called when message received
     */
    onMessage(callback: (message: Record<string, any>) => void): void;

    /**
     * Listen for watch reachability changes
     * @param callback - Called when reachability changes
     */
    onReachabilityChange(callback: (status: { reachable: boolean }) => void): void;
  };

  // ==================== Deep Links ====================
  deepLinks: {
    /**
     * Get the URL that launched the app (if any)
     * Returns null if app was not launched via deep link
     */
    getInitialURL(): Promise<DeepLinkData | null>;

    /**
     * Listen for deep link events while app is running
     * @param callback - Called when a deep link is received
     */
    onLink(callback: (data: DeepLinkData) => void): void;
  };

  // ==================== OTA Updates ====================
  ota: {
    /**
     * Configure OTA update settings
     */
    configure(options: OTAConfig): void;

    /**
     * Check for available updates
     */
    checkForUpdate(): Promise<OTAUpdateInfo | null>;

    /**
     * Download available update
     * @param options - Download options
     */
    downloadUpdate(options?: { applyOnRestart?: boolean }): Promise<OTADownloadResult>;

    /**
     * Apply downloaded update (restarts app)
     */
    applyUpdate(): Promise<void>;

    /**
     * Rollback to previous bundle version
     */
    rollback(): Promise<OTARollbackResult>;

    /**
     * Get current bundle information
     */
    getCurrentBundle(): OTABundleInfo;

    /**
     * Listen for download progress
     */
    onProgress(callback: (progress: OTAProgress) => void): void;

    /**
     * Listen for update status changes
     */
    onStatusChange(callback: (status: OTAStatus) => void): void;
  };
}

// ==================== Type Definitions ====================

export type HapticStyle = 'light' | 'medium' | 'heavy' | 'success' | 'warning' | 'error' | 'selection';

export interface CraftError {
  /** Error message */
  message: string;
  /** Error code */
  code: CraftErrorCode;
  /** Timestamp when error occurred */
  timestamp: number;
}

/** Enhanced error detail with stack traces */
export interface CraftErrorDetail {
  /** Error message */
  message: string;
  /** Error code */
  code: CraftErrorCode;
  /** Timestamp when error occurred */
  timestamp: number;
  /** Native stack trace (iOS/Android) - available in debug mode */
  nativeStack?: string;
  /** JavaScript stack trace */
  jsStack?: string;
}

export interface CraftCallLogEntry {
  /** Bridge action that was called */
  action: string;
  /** Parameters passed to the action */
  params?: Record<string, any>;
  /** Timestamp when action was called */
  timestamp: number;
}

/** Console log entry captured in debug mode */
export interface ConsoleLogEntry {
  /** Log level: 'log', 'warn', 'error', 'info', 'debug' */
  level: 'log' | 'warn' | 'error' | 'info' | 'debug';
  /** Array of logged arguments (stringified) */
  args: string[];
  /** Timestamp when logged */
  timestamp: number;
}

/** Network request entry captured in debug mode */
export interface NetworkLogEntry {
  /** Request type: 'fetch' or 'xhr' */
  type: 'fetch' | 'xhr';
  /** Request URL */
  url: string;
  /** HTTP method */
  method: string;
  /** Request start time */
  startTime: number;
  /** HTTP status code or 'error' */
  status: number | 'error' | null;
  /** Request duration in ms */
  duration: number | null;
  /** Error message if request failed */
  error?: string;
}

/** Complete debug report */
export interface DebugReport {
  /** Whether debug mode is currently enabled */
  enabled: boolean;
  /** Last error that occurred */
  lastError: CraftErrorDetail | null;
  /** Recent error history (last 10) */
  errorHistory: CraftErrorDetail[];
  /** Recent bridge calls (last 20) */
  callLog: CraftCallLogEntry[];
  /** Recent network requests (last 20) */
  networkLog: NetworkLogEntry[];
  /** Recent console logs (last 50) */
  consoleLog: ConsoleLogEntry[];
  /** Timestamp when report was generated */
  timestamp: number;
}

export type CraftErrorCode =
  | 'CRAFT_ERROR'           // Generic error
  | 'PERMISSION_DENIED'     // Permission not granted
  | 'NOT_AVAILABLE'         // Feature not available on device
  | 'NOT_SUPPORTED'         // Feature not supported on platform
  | 'CANCELLED'             // User cancelled operation
  | 'TIMEOUT'               // Operation timed out
  | 'NETWORK_ERROR'         // Network-related error
  | 'INVALID_PARAMS'        // Invalid parameters provided
  | 'NOT_AUTHENTICATED'     // Authentication required
  | 'NOT_REACHABLE'         // Target not reachable (e.g., watch)
  | 'SESSION_EXPIRED'       // Session has expired
  | 'AUTH_FAILED'           // Authentication failed
  | 'NOT_FOUND'             // Resource not found
  | 'STORAGE_FULL';         // Storage is full

export interface CraftCapabilities {
  haptics: boolean;
  speechRecognition: boolean;
  share: boolean;
  camera: boolean;
  biometric: boolean;
  pushNotifications: boolean;
  secureStorage: boolean;
  geolocation: boolean;
  clipboard: boolean;
  contacts: boolean;
  calendar: boolean;
  localNotifications: boolean;
  inAppPurchase: boolean;
  keepAwake: boolean;
  orientationLock: boolean;
  deepLinks: boolean;
  flashlight: boolean;
  network: boolean;
  deviceInfo: boolean;
  badge: boolean;
  appReview: boolean;
}

export interface DeepLinkData {
  /** The full URL string */
  url: string;
  /** URL scheme (e.g., 'https', 'myapp') */
  scheme: string;
  /** Host portion of URL */
  host: string;
  /** Path portion of URL */
  path: string;
  /** Raw query string (without '?') */
  query: string;
  /** Parsed query parameters */
  queryParams?: Record<string, string>;
}

export interface ProfilingCallTiming {
  /** Bridge action that was called */
  action: string;
  /** Start timestamp (Date.now()) */
  startTime: number;
  /** End timestamp (Date.now()) */
  endTime: number;
  /** Duration in milliseconds */
  duration: number;
}

export interface MemoryInfo {
  /** Memory used in megabytes */
  usedMB: number;
  /** Resident size in bytes (iOS) */
  residentSize?: number;
  /** Virtual size in bytes (iOS) */
  virtualSize?: number;
  /** Max heap size in MB (Android) */
  maxMB?: number;
  /** Total heap size in MB (Android) */
  totalMB?: number;
}

export interface ProfilingReport {
  /** Total profiling duration in ms */
  duration: number;
  /** Total number of bridge calls */
  bridgeCalls: number;
  /** Individual call timings */
  callTimings: ProfilingCallTiming[];
  /** Memory usage */
  memory: {
    start: MemoryInfo | null;
    end: MemoryInfo | null;
  };
  /** Average call time in ms */
  avgCallTime: number;
}

export interface ProfilingData {
  /** Whether profiling is currently running */
  running: boolean;
  /** Duration since profiling started (ms) */
  duration: number;
  /** Number of bridge calls so far */
  bridgeCalls: number;
  /** Call timings so far */
  callTimings: ProfilingCallTiming[];
}

// ==================== OTA Update Types ====================

export interface OTAConfig {
  /** URL to check for updates */
  updateUrl: string;
  /** Check for updates on app launch */
  checkOnLaunch?: boolean;
  /** Interval (ms) between automatic checks */
  checkInterval?: number;
  /** Public key for bundle signature verification */
  publicKey?: string;
}

export interface OTAUpdateInfo {
  /** Whether an update is available */
  available: boolean;
  /** Version string of available update */
  version: string;
  /** Build number of available update */
  buildNumber: number;
  /** Release notes */
  releaseNotes?: string;
  /** Whether update is mandatory */
  mandatory: boolean;
  /** Download size in bytes */
  downloadSize: number;
  /** Minimum app version required */
  minAppVersion: string;
  /** When update was published */
  createdAt: string;
}

export interface OTADownloadResult {
  /** Whether download succeeded */
  success: boolean;
  /** Path to downloaded bundle */
  bundlePath?: string;
  /** Whether update will apply on restart */
  applyOnRestart: boolean;
}

export interface OTARollbackResult {
  /** Whether rollback succeeded */
  success: boolean;
  /** Version rolled back to */
  rolledBackTo: string;
}

export interface OTABundleInfo {
  /** Current bundle version */
  version: string;
  /** Current bundle build number */
  buildNumber: number;
  /** Bundle hash (SHA-256) */
  hash: string;
  /** Whether this is the original bundled version */
  isOriginal: boolean;
  /** When this bundle was installed */
  installedAt: string;
}

export interface OTAProgress {
  /** Download progress (0-100) */
  percent: number;
  /** Bytes downloaded */
  bytesDownloaded: number;
  /** Total bytes to download */
  totalBytes: number;
}

export type OTAStatus =
  | 'idle'
  | 'checking'
  | 'downloading'
  | 'installing'
  | 'up-to-date'
  | 'update-available'
  | 'update-ready'
  | 'error';

export interface DeviceInfo {
  model: string;
  manufacturer?: string; // Android
  systemVersion: string;
  screenWidth: number;
  screenHeight: number;
  pixelRatio: number;
  platform: 'ios' | 'android';
}

export interface PickedFile {
  name: string;
  data: string; // Base64
  mimeType?: string;
}

/**
 * A location fix, exactly as the bridge sends it.
 *
 * All eight fields are always present. The native dictionary is built
 * unconditionally from `CLLocation`'s non-optional properties, so there is no
 * path that omits one — and this type previously declared six of them, three
 * of those optional, which left `altitudeAccuracy` and `timestamp` unreachable
 * from TypeScript even though every fix carries them.
 *
 * `heading` and `speed` are `-1` when the device has no fix for them, which is
 * CoreLocation's own sentinel rather than an absent key. Android has no
 * geolocation surface, so nothing else fills this in.
 */
export interface Position {
  latitude: number;
  longitude: number;
  /** Horizontal accuracy in metres. */
  accuracy: number;
  altitude: number;
  /** Vertical accuracy in metres. */
  altitudeAccuracy: number;
  /** Course over ground in degrees, or `-1` when unavailable. */
  heading: number;
  /** Metres per second, or `-1` when unavailable. */
  speed: number;
  /** Milliseconds since the Unix epoch. */
  timestamp: number;
}

export interface Contact {
  id: string;
  displayName: string;
  givenName?: string; // iOS
  familyName?: string; // iOS
  phoneNumbers: string[];
  emailAddresses: string[];
}

export interface NewContact {
  displayName?: string;
  givenName?: string;
  familyName?: string;
  phone?: string;
  email?: string;
}

export interface CalendarEvent {
  id: string;
  title: string;
  location?: string;
  notes?: string; // iOS
  description?: string; // Android
  startDate: number;
  endDate: number;
  isAllDay: boolean;
}

export interface NewCalendarEvent {
  title: string;
  location?: string;
  notes?: string;
  description?: string;
  startDate: number;
  endDate: number;
  isAllDay?: boolean;
}

export interface NotificationData {
  id?: string;
  title: string;
  body: string;
  badge?: number;
  timestamp?: number;
  delay?: number;
}

export interface PendingNotification {
  id: string;
  title: string;
  body: string;
}

export interface Product {
  id: string;
  title: string;
  description: string;
  price: string;
  priceLocale?: string;
}

export interface PurchaseResult {
  transactionId?: string;
  purchaseToken?: string;
  productId: string;
}

export interface AppleUser {
  userId: string;
  email?: string;
  fullName?: string;
  identityToken: string;
}

export interface GoogleUser {
  userId: string;
  email: string;
  displayName?: string;
  idToken: string;
}

export interface NetworkStatus {
  isConnected: boolean;
  type: 'wifi' | 'cellular' | 'none' | 'unknown';
}

export interface BackgroundTaskOptions {
  delay?: number;
  requiresNetwork?: boolean;
  requiresCharging?: boolean;
}

export interface AppShortcut {
  type: string;
  title: string;
  subtitle?: string;
  iconName?: string; // SF Symbol (iOS) or Android drawable name
}

export interface AuthPersistenceResult {
  enabled: boolean;
  duration: number;
  expiresAt: number;
}

export interface AROptions {
  planeDetection?: boolean;
}

export interface ARPosition {
  x: number;
  y: number;
  z: number;
}

export interface ARPlane {
  id: string;
  alignment: 'horizontal' | 'vertical';
  center: { x: number; y: number; z: number };
  extent: { width: number; height: number };
}

export interface ARPlaneEvent extends ARPlane {
  type: 'added' | 'updated' | 'removed';
}

export interface ClassificationResult {
  label: string;
  confidence: number;
  index?: number;
}

export interface ObjectDetectionResult {
  labels: ClassificationResult[];
  boundingBox: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  confidence?: number;
  trackingId?: number;
}

export interface TextRecognitionResult {
  text: string;
  confidence: number;
  boundingBox?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
}

export interface WidgetData {
  /** Widget title */
  title?: string;
  /** Widget subtitle */
  subtitle?: string;
  /** Primary value to display */
  value?: string;
  /** SF Symbol name (iOS) or drawable name (Android) */
  icon?: string;
}

export interface SiriInvocationEvent {
  /** Action identifier that was invoked */
  action: string;
  /** Additional data from the invocation */
  data?: Record<string, any>;
}

export interface WatchMessage {
  [key: string]: any;
}

// ==================== Events ====================

export interface CraftReadyEvent extends CustomEvent {
  detail: CraftBridge;
}

export interface CraftSpeechStartEvent extends CustomEvent {
  detail: {};
}

export interface CraftSpeechResultEvent extends CustomEvent {
  detail: {
    transcript: string;
    isFinal: boolean;
  };
}

export interface CraftSpeechEndEvent extends CustomEvent {
  detail: {};
}

export interface CraftSpeechErrorEvent extends CustomEvent {
  detail: {
    error: string;
  };
}

export interface CraftMotionUpdateEvent extends CustomEvent {
  detail: {
    accelerometer: { x: number; y: number; z: number };
    gyroscope: { x: number; y: number; z: number };
  };
}

export interface CraftBluetoothDeviceEvent extends CustomEvent {
  detail: {
    name: string;
    address?: string; // Android
    uuid?: string; // iOS
    rssi: number;
  };
}

export interface CraftARPlaneEvent extends CustomEvent {
  detail: ARPlaneEvent;
}

/**
 * A home-screen quick action being tapped.
 *
 * **Never dispatched today.** `craft.shortcuts.set()` really does install the
 * items and they appear in the long-press menu, but no template implements
 * `application(_:performActionFor:completionHandler:)` or a scene-delegate
 * equivalent, so a tap launches the app and stops there. A listener registered
 * for this is never called.
 */
export interface CraftShortcutEvent extends CustomEvent {
  detail: {
    type: string;
  };
}

/**
 * A donated Siri shortcut being invoked.
 *
 * **Never dispatched today.** `craft.siri.register()` donates an
 * `NSUserActivity`, but the only `onContinueUserActivity` in the template is
 * bound to `NSUserActivityTypeBrowsingWeb` and routes to the deep-link
 * handler, so invoking a donated shortcut relaunches the app and is dropped.
 */
export interface CraftSiriShortcutEvent extends CustomEvent {
  detail: SiriInvocationEvent;
}

export interface CraftWatchMessageEvent extends CustomEvent {
  detail: WatchMessage;
}

export interface CraftWatchReachabilityEvent extends CustomEvent {
  detail: {
    reachable: boolean;
  };
}

export interface CraftWatchContextEvent extends CustomEvent {
  detail: Record<string, any>;
}

export interface CraftLocationUpdateEvent extends CustomEvent {
  detail: Position;
}

export interface CraftLocationErrorEvent extends CustomEvent {
  detail: {
    message: string;
  };
}

export interface CraftNetworkChangeEvent extends CustomEvent {
  detail: NetworkStatus;
}

export interface CraftPushTokenEvent extends CustomEvent {
  detail: {
    token: string;
  };
}

/**
 * The `userInfo` of the notification the user acted on, forwarded verbatim.
 * The bridge does not reshape it, so its keys are whatever was scheduled.
 */
export interface CraftNotificationResponseEvent extends CustomEvent {
  detail: Record<string, any>;
}

export interface CraftWatchUserInfoEvent extends CustomEvent {
  detail: Record<string, any>;
}

export interface CraftErrorEvent extends CustomEvent {
  detail: CraftError;
}

export interface CraftDeepLinkEvent extends CustomEvent {
  detail: DeepLinkData;
}

// Augment WindowEventMap for better event listener typing
declare global {
  interface WindowEventMap {
    craftReady: CraftReadyEvent;
    craftSpeechStart: CraftSpeechStartEvent;
    craftSpeechResult: CraftSpeechResultEvent;
    craftSpeechEnd: CraftSpeechEndEvent;
    craftSpeechError: CraftSpeechErrorEvent;
    craftMotionUpdate: CraftMotionUpdateEvent;
    craftBluetoothDevice: CraftBluetoothDeviceEvent;
    craftARPlane: CraftARPlaneEvent;
    craftLocationUpdate: CraftLocationUpdateEvent;
    craftLocationError: CraftLocationErrorEvent;
    craftNetworkChange: CraftNetworkChangeEvent;
    craftPushToken: CraftPushTokenEvent;
    craftNotificationResponse: CraftNotificationResponseEvent;
    craftWatchMessage: CraftWatchMessageEvent;
    craftWatchReachability: CraftWatchReachabilityEvent;
    craftWatchContext: CraftWatchContextEvent;
    craftWatchUserInfo: CraftWatchUserInfoEvent;
    craftError: CraftErrorEvent;
    craftDeepLink: CraftDeepLinkEvent;
    // Kept, and kept last, because nothing dispatches either one: the app
    // installs the shortcuts and donates the activities, and no template
    // implements the callback that would deliver a tap. Typed so the listener
    // an app writes today compiles against the shape it will receive if that
    // lands; see the note on each interface.
    craftShortcut: CraftShortcutEvent;
    craftSiriShortcut: CraftSiriShortcutEvent;
  }
}

export {};

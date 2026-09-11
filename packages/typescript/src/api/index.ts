/**
 * Craft API Modules
 * Native APIs available in Craft applications
 */

// Window API - Comprehensive window management
export {
  windowManager,
  win,
  window,
  createWindow,
  Window
} from './window.js'
export type {
  WindowPosition,
  WindowSize,
  WindowBounds,
  WindowState,
  WindowCreateOptions,
  WindowEventType,
  WindowEventMap,
  WindowEventHandler
} from './window.js'

// Tray/Menubar API - System tray and menubar apps
export {
  trayManager,
  tray,
  SystemTray,
  MenubarApp,
  createMenubarApp,
  buildMenu,
  separator,
  menuItem,
  checkbox,
  submenu
} from './tray.js'
export type {
  MenuItem,
  TrayClickEvent,
  TrayOptions,
  MenubarAppConfig,
  TrayEventType,
  TrayEventMap,
  TrayEventHandler
} from './tray.js'

// App API - Application lifecycle and system integration
export {
  appManager,
  app,
  quit,
  hide,
  show,
  focus,
  hideDockIcon,
  showDockIcon,
  setBadge,
  getInfo,
  getVersion,
  getName,
  getPath,
  isDarkMode,
  getLocale,
  notify,
  registerShortcut,
  unregisterShortcut
} from './app.js'
export type {
  AppInfo,
  SystemPreferences,
  DisplayInfo,
  BadgeOptions,
  NotificationOptions,
  AppEventType,
  AppEventMap,
  AppEventHandler,
  ShortcutHandler
} from './app.js'

// File System API
export { fs, readBinaryFile, writeBinaryFile, stat, copy, move, watch } from './fs.js'
export type { FileStats } from './fs.js'

// Database API
export { db, openDatabase, Database, KeyValueStore } from './db.js'
export type { ExecuteResult, TableColumn } from './db.js'

// HTTP Client API
export { http, HttpClient, WebSocketClient, createClient, HttpError } from './http.js'
export type { HttpClientOptions, RequestOptions, HttpResponse, WebSocketOptions } from './http.js'

// Crypto API
export {
  crypto,
  uuid,
  randomString,
  hmac,
  timingSafeEqual,
  hashPassword,
  verifyPassword
} from './crypto.js'

// Process API
export {
  env,
  getPlatform,
  isDesktop,
  isMobile,
  isCraft,
  getSystemInfo,
  exec,
  spawn,
  ChildProcess,
  cwd,
  homeDir,
  tempDir,
  exit,
  argv,
  open
} from './process.js'
export type { Platform, SystemInfo, ExecOptions, ExecResult, SpawnOptions } from './process.js'

// Mobile API - Unified cross-platform mobile features
export {
  device,
  haptics,
  permissions,
  camera,
  biometrics,
  secureStorage,
  location,
  share,
  lifecycle,
  notifications,
  notifications as notification
} from './mobile.js'
export type {
  DeviceInfo,
  DeviceCapabilities,
  HapticStyle,
  HapticNotificationType,
  PermissionType,
  PermissionStatus,
  CameraOptions as MobileCameraOptions,
  PhotoResult,
  BiometricType,
  Location,
  LocationOptions,
  ShareOptions,
  AppState,
  NotificationOptions as MobileNotificationOptions
} from './mobile.js'

// iOS Advanced Features
export {
  carplay,
  appClips,
  liveActivities,
  sharePlay,
  storeKit,
  appIntents,
  tipKit,
  focusFilters
} from './ios-advanced.js'
export type {
  CarPlayTemplateType,
  CarPlayListItem,
  CarPlayGridItem,
  CarPlayTemplate,
  AppClipInvocation,
  LiveActivityContentState,
  LiveActivityAttributes,
  LiveActivityConfig,
  LiveActivityHandle,
  SharePlaySessionState,
  SharePlayParticipant,
  SharePlayActivity,
  ProductType,
  Product,
  Transaction,
  IntentParameterType,
  IntentParameter,
  AppIntent,
  TipDisplayFrequency,
  Tip,
  FocusStatus,
  FocusFilter
} from './ios-advanced.js'

// Android Advanced Features
export {
  materialYou,
  photoPicker,
  workManager,
  foregroundService,
  predictiveBack,
  appLanguage,
  widgets as androidWidgets,
  playBilling
} from './android-advanced.js'
export type {
  MaterialYouColors,
  PhotoPickerMediaType,
  PhotoPickerResult,
  WorkConstraints,
  WorkRequest,
  WorkInfo,
  ForegroundServiceType,
  ForegroundNotification,
  BackEvent,
  WidgetSizeClass,
  WidgetConfig,
  WidgetData,
  PlayProduct,
  PlayPurchase
} from './android-advanced.js'

// macOS Advanced Features
export {
  touchBar,
  desktopWidgets,
  stageManager,
  handoff,
  sidecar,
  spotlight,
  quickActions,
  shareExtension,
  windowManagement
} from './macos-advanced.js'
export type {
  TouchBarItemType,
  TouchBarButton,
  TouchBarLabel,
  TouchBarSlider,
  TouchBarColorPicker,
  TouchBarScrubber,
  TouchBarSegmentedControl,
  TouchBarPopover,
  TouchBarSpacer,
  TouchBarGroup,
  TouchBarItem,
  WidgetFamily,
  WidgetTimelineEntry,
  WidgetConfiguration,
  UserActivity,
  SidecarDevice,
  SpotlightItem,
  QuickAction,
  WindowTabGroup
} from './macos-advanced.js'

// Windows Advanced Features
export {
  jumpList,
  taskbarProgress,
  toastNotifications,
  windowsHello,
  windowsWidgets,
  msixUpdate,
  shareTarget,
  startupTask,
  secondaryTiles
} from './windows-advanced.js'
export type {
  JumpListTask,
  JumpListCategory,
  TaskbarProgressState,
  ToastAction,
  ToastInput,
  ToastContent,
  WindowsHelloAvailability,
  WidgetTemplateType,
  WindowsWidgetContent,
  PackageVersion,
  UpdateInfo,
  SharedDataItem,
  SecondaryTile
} from './windows-advanced.js'

// Dialog API - Native file pickers and alerts
export {
  dialog,
  openFile,
  openFolder,
  saveFile,
  showAlert,
  showConfirm,
  showPrompt
} from './dialog.js'
export type {
  FileFilter,
  OpenDialogOptions,
  SaveDialogOptions,
  AlertStyle,
  AlertOptions,
  ConfirmOptions,
  OpenDialogResult,
  SaveDialogResult
} from './dialog.js'

// Clipboard API - System clipboard access
export {
  clipboard,
  writeText,
  readText,
  writeHTML,
  readHTML
} from './clipboard.js'
export type {
  ClipboardFormat,
  ClipboardData
} from './clipboard.js'

// Media API - Camera and microphone access
export { media } from './media.js'
export type {
  MediaDeviceInfo,
  CameraOptions as MediaCameraOptions,
  MicrophoneOptions,
  MediaStreamOptions
} from './media.js'

// Cross-Platform Sidebar API (macOS, Windows, Linux)
export {
  Sidebar,
  createSidebar,
  createFileSidebar,
  createSettingsSidebar,
  sidebar
} from './sidebar.js'
export type {
  SidebarItem,
  SidebarSection,
  SidebarConfig,
  MacOSSidebarConfig,
  WindowsSidebarConfig,
  LinuxSidebarConfig,
  SidebarSelectEvent,
  SidebarSearchEvent
} from './sidebar.js'

// Spaces API - native switcher for Arc-style sidebar spaces
export {
  spaces,
  createSpacesSidebar,
  hasNativeSpaces
} from './spaces.js'
export type {
  SpaceDescriptor,
  SpacesSidebarOptions,
  SpacesSidebarHandle,
  NativeUIAPI
} from './spaces.js'

// Gestures API - real trackpad swipe phases from the host's NSEvent
export {
  gestures,
  onSwipe,
  hasNativeGestures
} from './gestures.js'
export type {
  SwipeAxis,
  SwipePhase,
  SwipeEvent,
  SwipeListener,
  Unsubscribe
} from './gestures.js'

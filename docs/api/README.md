# Craft API Reference

Complete API reference for the Craft framework.

## Core APIs

- [Window API](./window.md) - Window management and configuration
- [Tray API](./tray.md) - System tray integration
- [Menu API](./menu.md) - Application and context menus
- [Dialog API](./dialog.md) - Native dialogs (open, save, message)
- [Notification API](./notification.md) - Desktop notifications

## System APIs

- [File System API](./fs.md) - File and directory operations
- [Database API](./db.md) - SQLite database operations
- [HTTP API](./http.md) - Network requests and downloads
- [Process API](./process.md) - Process management and execution
- [Crypto API](./crypto.md) - Cryptographic operations

## Mobile APIs

- [Runtime Compatibility](./mobile/runtime-compatibility.md) - Intentional validation and migration guidance
- [Device API](./mobile/device.md) - Device information and capabilities
- [Haptics API](./mobile/haptics.md) - Haptic feedback
- [Permissions API](./mobile/permissions.md) - Permission management
- [Camera API](./mobile/camera.md) - Camera and photo picker
- [Biometrics API](./mobile/biometrics.md) - Face ID, Touch ID, fingerprint
- [Secure Storage API](./mobile/secure-storage.md) - Keychain/Keystore storage
- [Location API](./mobile/location.md) - Geolocation services
- [Share API](./mobile/share.md) - Native share sheet
- [Lifecycle API](./mobile/lifecycle.md) - App lifecycle events

## Platform-Specific APIs

### iOS

- [CarPlay API](./ios/carplay.md)
- [App Clips API](./ios/app-clips.md)
- [Live Activities API](./ios/live-activities.md)
- [SharePlay API](./ios/shareplay.md)
- [StoreKit API](./ios/storekit.md)

### Android

- [Material You API](./android/material-you.md)
- [Photo Picker API](./android/photo-picker.md)
- [Work Manager API](./android/work-manager.md)
- [Widgets API](./android/widgets.md)

### macOS

- [Touch Bar API](./macos/touch-bar.md)
- [Desktop Widgets API](./macos/widgets.md)
- [Stage Manager API](./macos/stage-manager.md)
- [Handoff API](./macos/handoff.md)

### Windows

- [Jump Lists API](./windows/jump-lists.md)
- [Taskbar API](./windows/taskbar.md)
- [Toast Notifications API](./windows/toast.md)
- [Windows Hello API](./windows/hello.md)

## UI & Styling

- [Components API](./components.md) - React Native-style components
- [StyleSheet API](./stylesheet.md) - StyleSheet.create and utilities
- [Animated API](./animated.md) - Animation system
- [Headwind CSS](./headwind.md) - Tailwind-style utilities

## Framework Bindings

- [React Hooks](./react.md) - useCraft, useWindow, useTray, etc.
- [Vue Composables](./vue.md) - useCraft, useWindow, useTray, etc.
- [Svelte Stores](./svelte.md) - Svelte stores and actions

## Configuration

- [craft.config.ts](./config.md) - Application configuration
- [Platform Configuration](./platform-config.md) - Platform-specific options

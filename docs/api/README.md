# Craft API Reference

Complete API reference for the Craft framework.

This index lists reference pages that are published in the repository. For the
complete native message surface, see the [Bridge API](../BRIDGE_API.md).

## Core APIs

- [Components API](./components.md) - Native component primitives
- [Objective-C structure returns](./objc-runtime.md) - Shared Apple message ABI and native execution checks
- [Persistent JavaScript hosting](../guides/persistent-javascript.md) - Retained native callbacks and copied typed buffers
- [Native Metal surface](../guides/metal-surface.md) - Native view presentation, bounded buffers and drawable readback

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
- [Location recording API](./mobile/location.md) - Route recording and its power modes
- [Permissions API](./mobile/permissions.md) - Permission management
- [Biometrics API](./mobile/biometrics.md) - Face ID, Touch ID, fingerprint
- [Secure Storage API](./mobile/secure-storage.md) - Keychain/Keystore storage
- [Session API](./mobile/session.md) - The signed-in account and its changes (`craft.session`)
- [Background API](./mobile/background.md) - Silent pushes, scheduled refresh and `complete(ok, id)`

## Platform-Specific APIs

### iOS

- [Live Activities API](./ios/live-activities.md)

## UI & Styling

- [Headwind CSS](./headwind.md) - Tailwind-style utilities

## Framework Bindings

- [React Hooks](./react.md) - useCraft, useWindow, useTray, etc.
- [Vue Composables](./vue.md) - useCraft, useWindow, useTray, etc.
- [Svelte Stores](./svelte.md) - Svelte stores and actions

## Configuration

- [craft.config.ts](./config.md) - Application configuration

- [Background deadlines](./timers.md) - Cancellable native macOS timers for hidden pages

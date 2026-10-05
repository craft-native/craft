# Migrating from React Native

A guide to migrating your React Native application to Craft.

## Overview

| Aspect | React Native | Craft |
|--------|--------------|-------|
| UI | Native components | WebView + native APIs |
| Styling | StyleSheet | CSS / Headwind / StyleSheet |
| Language | JavaScript/TypeScript | JavaScript/TypeScript |
| Desktop | Limited (Windows/macOS) | Full support |
| Mobile | iOS & Android | iOS & Android |

## Key Differences

### UI Rendering

**React Native** renders to native UI components:
```jsx
<View style={styles.container}>
  <Text style={styles.title}>Hello</Text>
</View>
```

**Craft** renders HTML in a WebView:
```jsx
<div className="container">
  <h1 className="title">Hello</h1>
</div>
```

### Why Migrate

1. **Desktop support** - Full macOS, Windows, Linux support
2. **Web technologies** - Use any CSS framework, HTML5 features
3. **Simpler tooling** - No Metro bundler, no native build tools
4. **Smaller teams** - Web developers can build mobile apps

### What You Keep

- Your business logic
- API integrations
- State management (Redux, MobX, Zustand, etc.)
- TypeScript types

## API Mapping

### Components

| React Native | Craft (HTML) | Craft (Compatible) |
|--------------|--------------|-------------------|
| `<View>` | `<div>` | `<View>` |
| `<Text>` | `<p>`, `<span>` | `<Text>` |
| `<Image>` | `<img>` | `<Image>` |
| `<ScrollView>` | CSS overflow | `<ScrollView>` |
| `<FlatList>` | Virtual list lib | `<FlatList>` in native STX mode |
| `<TouchableOpacity>` | `<button>` | - |
| `<TextInput>` | `<input>` | - |

### StyleSheet

**React Native:**
```javascript
const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    padding: 16
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold'
  }
})
```

**Craft (CSS):**
```css
.container {
  display: flex;
  flex: 1;
  background-color: #fff;
  padding: 16px;
}

.title {
  font-size: 24px;
  font-weight: bold;
}
```

**Craft (Headwind):**
```typescript
import { tw } from 'craft-native'

const containerClass = tw`flex flex-1 bg-white p-4`
const titleClass = tw`text-2xl font-bold`
```

**Craft (Compatible API):**
```typescript
import { StyleSheet } from 'craft-native'

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    padding: 16
  }
})
```

### Platform Detection

**React Native:**
```javascript
import { Platform } from 'react-native'

if (Platform.OS === 'ios') {
  // iOS specific
}

const styles = StyleSheet.create({
  container: {
    paddingTop: Platform.OS === 'ios' ? 44 : 24
  }
})
```

**Craft:**
```typescript
import { Platform } from 'craft-native'

if (Platform.OS === 'ios') {
  // iOS specific
}

// Platform.select works the same
const paddingTop = Platform.select({
  ios: 44,
  android: 24,
  default: 0
})
```

### Animated API

**React Native:**
```javascript
import { Animated } from 'react-native'

const fadeAnim = new Animated.Value(0)

Animated.timing(fadeAnim, {
  toValue: 1,
  duration: 300,
  useNativeDriver: true
}).start()
```

**Craft:**
```typescript
import { Animated } from 'craft-native'

const fadeAnim = new Animated.Value(0)

Animated.timing(fadeAnim, {
  toValue: 1,
  duration: 300,
  useNativeDriver: true
}).start()
```

### AsyncStorage → secureStorage

**React Native:**
```javascript
import AsyncStorage from '@react-native-async-storage/async-storage'

await AsyncStorage.setItem('token', 'value')
const token = await AsyncStorage.getItem('token')
```

**Craft:**
```typescript
import { secureStorage } from 'craft-native'

await secureStorage.set('token', 'value')
const token = await secureStorage.get('token')
```

### Haptics

**React Native:**
```javascript
import * as Haptics from 'expo-haptics'

Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)
Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
```

**Craft:**
```typescript
import { haptics } from 'craft-native'

await haptics.impact('light')
await haptics.notification('success')
```

### Biometrics

**React Native:**
```javascript
import * as LocalAuthentication from 'expo-local-authentication'

const result = await LocalAuthentication.authenticateAsync({
  promptMessage: 'Authenticate'
})
```

**Craft:**
```typescript
import { biometrics } from 'craft-native'

const result = await biometrics.authenticate({
  reason: 'Authenticate'
})
```

### Camera

**React Native:**
```javascript
import { Camera } from 'expo-camera'

const { status } = await Camera.requestCameraPermissionsAsync()
```

**Craft:**
```typescript
import { camera, permissions } from 'craft-native'

await permissions.request('camera')
const photo = await camera.takePhoto()
```

### Location

**React Native:**
```javascript
import * as Location from 'expo-location'

const { coords } = await Location.getCurrentPositionAsync()
```

**Craft:**
```typescript
import { location } from 'craft-native'

const position = await location.getCurrentPosition()
```

### Navigation

**React Native (React Navigation):**
```javascript
import { NavigationContainer } from '@react-navigation/native'
import { createStackNavigator } from '@react-navigation/stack'

const Stack = createStackNavigator()

function App() {
  return (
    <NavigationContainer>
      <Stack.Navigator>
        <Stack.Screen name="Home" component={HomeScreen} />
        <Stack.Screen name="Details" component={DetailsScreen} />
      </Stack.Navigator>
    </NavigationContainer>
  )
}
```

**Craft (React Router or similar):**
```jsx
import { BrowserRouter, Routes, Route } from 'react-router-dom'

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<HomeScreen />} />
        <Route path="/details" element={<DetailsScreen />} />
      </Routes>
    </BrowserRouter>
  )
}
```

## Step-by-Step Migration

### 1. Create New Craft Project

```bash
bunx craft init my-app --template blank
cd my-app
bun add react react-dom react-router-dom
```

### 2. Set Up React

```typescript
// src/main.tsx
import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'

createRoot(document.getElementById('app')!).render(<App />)
```

### 3. Migrate Components

Convert React Native components to HTML/React:

**Before:**
```jsx
import { View, Text, TouchableOpacity } from 'react-native'

function MyComponent() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Hello</Text>
      <TouchableOpacity onPress={handlePress}>
        <Text>Press Me</Text>
      </TouchableOpacity>
    </View>
  )
}
```

**After:**
```jsx
import { tw } from 'craft-native'

function MyComponent() {
  return (
    <div className={tw`flex flex-col p-4`}>
      <h1 className={tw`text-2xl font-bold`}>Hello</h1>
      <button onClick={handlePress} className={tw`px-4 py-2 bg-blue-500 text-white rounded`}>
        Press Me
      </button>
    </div>
  )
}
```

### 4. Update Styles

Convert StyleSheet to CSS or Headwind:

```typescript
// Using Headwind (Tailwind-style)
import { tw, cx } from 'craft-native'

const styles = {
  container: tw`flex flex-1 bg-white p-4`,
  title: tw`text-2xl font-bold text-gray-900`,
  button: tw`px-4 py-2 bg-blue-500 text-white rounded-lg`
}
```

### 5. Replace Native Modules

Map React Native APIs to Craft:

```typescript
// Before
import AsyncStorage from '@react-native-async-storage/async-storage'
import * as Haptics from 'expo-haptics'
import * as LocalAuthentication from 'expo-local-authentication'

// After
import { secureStorage, haptics, biometrics } from 'craft-native'
```

### 6. Update Navigation

Replace React Navigation with web router:

```bash
bun add react-router-dom
```

### 7. Test on All Platforms

```bash
bun run dev              # Desktop
bun run build --platform ios     # iOS
bun run build --platform android # Android
```

## Compatible Component Library

Craft provides React Native-compatible components for easier migration:

```typescript
import {
  View,
  Text,
  Image,
  ScrollView,
  StyleSheet,
  Platform,
  Animated
} from 'craft-native/components'

// Use exactly like React Native
function App() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Hello Craft!</Text>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center'
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold'
  }
})
```

## Handling Platform Differences

### Safe Areas

**React Native:**
```jsx
import { SafeAreaView } from 'react-native-safe-area-context'

<SafeAreaView>
  <Content />
</SafeAreaView>
```

**Craft:**
```jsx
import { device } from 'craft-native'

function SafeArea({ children }) {
  const [insets, setInsets] = useState({ top: 0, bottom: 0 })

  useEffect(() => {
    device.getScreenInfo().then(info => {
      setInsets(info.safeAreaInsets)
    })
  }, [])

  return (
    <div style={{
      paddingTop: insets.top,
      paddingBottom: insets.bottom
    }}>
      {children}
    </div>
  )
}
```

### Keyboard Handling

**React Native:**
```jsx
import { KeyboardAvoidingView } from 'react-native'

<KeyboardAvoidingView behavior="padding">
  <TextInput />
</KeyboardAvoidingView>
```

**Craft:**
```css
/* CSS handles this automatically in WebView */
input:focus {
  /* Keyboard behavior handled by system */
}
```

## Troubleshooting

### "Cannot find module 'react-native'"

Replace with Craft components or HTML:
```typescript
// Use HTML elements
<div> instead of <View>
<p> instead of <Text>

// Or use compatible components
import { View, Text } from 'craft-native/components'
```

### Native modules not available

Replace with Craft APIs or web alternatives:
```typescript
// Expo Camera → Craft camera
import { camera } from 'craft-native'

// Native SQLite → Craft db
import { db } from 'craft-native'
```

### Layout differences

WebView uses CSS flexbox. Key differences:

- `flexDirection` defaults to `row` (not `column`)
- Use `display: flex` explicitly
- Dimensions in `px` not unitless

```css
/* Craft CSS equivalent of RN defaults */
.rn-view {
  display: flex;
  flex-direction: column;
  position: relative;
}
```

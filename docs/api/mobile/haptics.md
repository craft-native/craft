# Haptics API

Provide tactile feedback through device vibrations.

Haptics are feedback, so these methods never stop a flow for a capability the
app left off. On iOS, with `enableHaptics` off in `craft.config.json`, they
resolve without playing anything, the way the web fallback does on a device
with no vibration motor. They reject only when the native call itself fails.
The raw `window.craft.haptic()` is different: it rejects with
`CAPABILITY_DISABLED`, for code that needs to know.

## Import

```typescript
import { haptics } from 'craft-native'
```

## Methods

### haptics.impact(style)

Trigger an impact haptic feedback. Use for button presses, selections, and UI interactions.

```typescript
// Light impact - subtle tap
await haptics.impact('light')

// Medium impact - standard feedback
await haptics.impact('medium')

// Heavy impact - strong tap
await haptics.impact('heavy')

// Rigid impact (iOS only) - sharp, precise tap
await haptics.impact('rigid')

// Soft impact (iOS only) - gentle, rounded tap
await haptics.impact('soft')
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| style | `'light' \| 'medium' \| 'heavy' \| 'rigid' \| 'soft'` | Impact intensity |

**Returns:** `Promise<void>`

---

### haptics.notification(type)

Trigger a notification haptic. Use to indicate success, warning, or error states.

```typescript
// Success - positive feedback
await haptics.notification('success')

// Warning - cautionary feedback
await haptics.notification('warning')

// Error - negative feedback
await haptics.notification('error')
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| type | `'success' \| 'warning' \| 'error'` | Notification type |

**Returns:** `Promise<void>`

---

### haptics.selection()

Trigger a selection haptic. Use for selection changes like toggles, pickers, and sliders.

```typescript
// Selection feedback - very light tap
await haptics.selection()
```

**Returns:** `Promise<void>`

---

### haptics.vibrate(pattern?)

Trigger a vibration with optional pattern (primarily Android).

```typescript
// Simple vibration
await haptics.vibrate()

// Pattern: [wait, vibrate, wait, vibrate, ...]
await haptics.vibrate([0, 100, 50, 100])

// Long vibration
await haptics.vibrate([0, 500])
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| pattern | `number[]` | Vibration pattern in milliseconds |

**Returns:** `Promise<void>`

---

### haptics.isSupported()

Check if haptics are supported on the current device.

```typescript
const supported = await haptics.isSupported()

if (supported) {
  await haptics.impact('medium')
}
```

**Returns:** `Promise<boolean>`

## Example Usage

```typescript
import { haptics } from 'craft-native'

// Button press feedback
async function onButtonPress() {
  await haptics.impact('light')
  // Perform action...
}

// Toggle switch
async function onToggle(isOn: boolean) {
  await haptics.selection()
  updateToggleState(isOn)
}

// Form submission
async function onSubmit() {
  try {
    await submitForm()
    await haptics.notification('success')
    showSuccessMessage()
  } catch (error) {
    await haptics.notification('error')
    showErrorMessage(error)
  }
}

// Slider with continuous feedback
let lastValue = 0
async function onSliderChange(value: number) {
  // Only trigger haptic when crossing major values
  const roundedValue = Math.round(value / 10) * 10
  if (roundedValue !== lastValue) {
    lastValue = roundedValue
    await haptics.selection()
  }
}

// Delete confirmation
async function confirmDelete() {
  await haptics.notification('warning')
  const confirmed = await showConfirmDialog('Delete this item?')

  if (confirmed) {
    await deleteItem()
    await haptics.notification('success')
  }
}

// Long press action
async function onLongPress() {
  await haptics.impact('heavy')
  showContextMenu()
}

// Tab selection
async function onTabSelect(tabId: string) {
  await haptics.impact('light')
  switchToTab(tabId)
}

// Pull to refresh
async function onRefreshStart() {
  await haptics.impact('medium')
}

async function onRefreshComplete(success: boolean) {
  await haptics.notification(success ? 'success' : 'error')
}
```

## Best Practices

1. **Use sparingly** - Too much haptic feedback becomes annoying
2. **Match intensity to action** - Light for selections, heavy for important actions
3. **Be consistent** - Use the same haptic type for similar actions
4. **Respect user preferences** - Some users disable haptics for accessibility
5. **Test on real devices** - Simulators don't provide accurate haptic feedback

## Platform Differences

| Feature | iOS | Android |
|---------|-----|---------|
| Impact styles | All 5 styles | 3 styles (light/medium/heavy) |
| Notification types | All 3 types | Mapped to vibration patterns |
| Selection | Yes | Yes |
| Custom patterns | Limited | Full support |

## Types

```typescript
type ImpactStyle = 'light' | 'medium' | 'heavy' | 'rigid' | 'soft'

type NotificationType = 'success' | 'warning' | 'error'
```

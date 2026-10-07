/**
 * @fileoverview Craft Component Abstractions
 * @description React Native-style component primitives for cross-platform UI development.
 * These provide a consistent abstraction layer over native platform components.
 * @module @craft-native/components
 *
 * @example
 * ```tsx
 * import { View, Text, Image, ScrollView, Pressable } from '@craft-native/components'
 *
 * function MyComponent() {
 *   return (
 *     <View style={{ flex: 1, padding: 16 }}>
 *       <Text style={{ fontSize: 24, fontWeight: 'bold' }}>Hello World</Text>
 *       <Image source={{ uri: 'https://example.com/image.png' }} style={{ width: 100, height: 100 }} />
 *     </View>
 *   )
 * }
 * ```
 */

// ============================================================================
// Native Sidebar Components
// ============================================================================

export {
  Sidebar,
  createSidebar,
  createTahoeSidebar,
  createArcSidebar,
  createOrbStackSidebar,
  sidebarItem,
  sidebarSection,
  sidebarSeparator,
  tahoeStyle,
  arcStyle,
  orbstackStyle
} from './sidebar.js'
export type {
  SidebarItem,
  SidebarSection,
  ContextMenuItem,
  SidebarStyle,
  SidebarPosition,
  SidebarConfig,
  SidebarHeaderConfig,
  SidebarFooterConfig,
  SidebarEventType,
  SidebarEventMap,
  SidebarEventHandler
} from './sidebar.js'

// ============================================================================
// Native UI Components
// ============================================================================

export {
  // Split View
  createSplitView,
  SplitViewInstance,

  // File Browser
  createFileBrowser,
  FileBrowserInstance,

  // Outline View (Tree)
  createOutlineView,
  OutlineViewInstance,

  // Table View
  createTableView,
  TableViewInstance,

  // Quick Look
  showQuickLook,
  hideQuickLook,
  canQuickLook,

  // Pickers
  showColorPicker,
  showFontPicker,
  showDatePicker,

  // Progress
  createProgress,
  ProgressInstance,

  // Toolbar
  setToolbar,
  updateToolbarItem,
  setToolbarVisible,

  // Touch Bar
  setTouchBar,
  updateTouchBarItem
} from './native.js'
export type {
  ComponentProps,
  ComponentInstance,
  SplitViewOrientation,
  SplitViewDividerStyle,
  SplitViewConfig,
  FileBrowserConfig,
  FileBrowserSelection,
  OutlineItem,
  OutlineViewConfig,
  TableColumn,
  TableRow,
  TableViewConfig,
  QuickLookConfig,
  ColorPickerConfig,
  FontPickerConfig,
  FontResult,
  DatePickerConfig,
  ProgressConfig,
  ToolbarItem,
  ToolbarConfig,
  TouchBarItem,
  TouchBarConfig
} from './native.js'

// ============================================================================
// Style Types
// ============================================================================

/**
 * Flexbox style properties.
 */
export interface FlexStyle {
  /** Flex grow factor */
  flex?: number
  /** Flex grow factor */
  flexGrow?: number
  /** Flex shrink factor */
  flexShrink?: number
  /** Flex basis */
  flexBasis?: number | string
  /** Flex direction */
  flexDirection?: 'row' | 'column' | 'row-reverse' | 'column-reverse'
  /** Flex wrap */
  flexWrap?: 'nowrap' | 'wrap' | 'wrap-reverse'
  /** Justify content (main axis) */
  justifyContent?: 'flex-start' | 'flex-end' | 'center' | 'space-between' | 'space-around' | 'space-evenly'
  /** Align items (cross axis) */
  alignItems?: 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'baseline'
  /** Align self (override parent alignItems) */
  alignSelf?: 'auto' | 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'baseline'
  /** Align content (multi-line) */
  alignContent?: 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'space-between' | 'space-around'
  /** Gap between items */
  gap?: number
  /** Row gap */
  rowGap?: number
  /** Column gap */
  columnGap?: number
}

/**
 * Layout style properties.
 */
export interface LayoutStyle {
  /** Width */
  width?: number | string
  /** Height */
  height?: number | string
  /** Min width */
  minWidth?: number | string
  /** Max width */
  maxWidth?: number | string
  /** Min height */
  minHeight?: number | string
  /** Max height */
  maxHeight?: number | string
  /** Aspect ratio */
  aspectRatio?: number
  /** Position type */
  position?: 'relative' | 'absolute'
  /** Top position */
  top?: number | string
  /** Right position */
  right?: number | string
  /** Bottom position */
  bottom?: number | string
  /** Left position */
  left?: number | string
  /** Z-index */
  zIndex?: number
  /** Overflow */
  overflow?: 'visible' | 'hidden' | 'scroll'
  /** Display */
  display?: 'flex' | 'none'
}

/**
 * Spacing style properties.
 */
export interface SpacingStyle {
  /** Margin all sides */
  margin?: number | string
  /** Margin top */
  marginTop?: number | string
  /** Margin right */
  marginRight?: number | string
  /** Margin bottom */
  marginBottom?: number | string
  /** Margin left */
  marginLeft?: number | string
  /** Margin horizontal */
  marginHorizontal?: number | string
  /** Margin vertical */
  marginVertical?: number | string
  /** Padding all sides */
  padding?: number | string
  /** Padding top */
  paddingTop?: number | string
  /** Padding right */
  paddingRight?: number | string
  /** Padding bottom */
  paddingBottom?: number | string
  /** Padding left */
  paddingLeft?: number | string
  /** Padding horizontal */
  paddingHorizontal?: number | string
  /** Padding vertical */
  paddingVertical?: number | string
}

/**
 * Border style properties.
 */
export interface BorderStyle {
  /** Border width all sides */
  borderWidth?: number
  /** Border top width */
  borderTopWidth?: number
  /** Border right width */
  borderRightWidth?: number
  /** Border bottom width */
  borderBottomWidth?: number
  /** Border left width */
  borderLeftWidth?: number
  /** Border color */
  borderColor?: string
  /** Border top color */
  borderTopColor?: string
  /** Border right color */
  borderRightColor?: string
  /** Border bottom color */
  borderBottomColor?: string
  /** Border left color */
  borderLeftColor?: string
  /** Border radius all corners */
  borderRadius?: number
  /** Border top left radius */
  borderTopLeftRadius?: number
  /** Border top right radius */
  borderTopRightRadius?: number
  /** Border bottom left radius */
  borderBottomLeftRadius?: number
  /** Border bottom right radius */
  borderBottomRightRadius?: number
  /** Border style */
  borderStyle?: 'solid' | 'dotted' | 'dashed'
}

/**
 * Background and color style properties.
 */
export interface ColorStyle {
  /** Background color */
  backgroundColor?: string
  /** Opacity */
  opacity?: number
}

/**
 * Shadow style properties.
 */
export interface ShadowStyle {
  /** Shadow color */
  shadowColor?: string
  /** Shadow offset */
  shadowOffset?: { width: number; height: number }
  /** Shadow opacity */
  shadowOpacity?: number
  /** Shadow radius */
  shadowRadius?: number
  /** Elevation (Android) */
  elevation?: number
}

/**
 * Transform style properties.
 */
export interface TransformStyle {
  /** Array of transforms */
  transform?: Array<
    | { translateX: number }
    | { translateY: number }
    | { scale: number }
    | { scaleX: number }
    | { scaleY: number }
    | { rotate: string }
    | { rotateX: string }
    | { rotateY: string }
    | { rotateZ: string }
    | { skewX: string }
    | { skewY: string }
  >
}

/**
 * Combined View style type.
 */
export type ViewStyle = FlexStyle & LayoutStyle & SpacingStyle & BorderStyle & ColorStyle & ShadowStyle & TransformStyle

/**
 * Text-specific style properties.
 */
export interface TextStyleProps {
  /** Text color */
  color?: string
  /** Font family */
  fontFamily?: string
  /** Font size */
  fontSize?: number
  /** Font style */
  fontStyle?: 'normal' | 'italic'
  /** Font weight */
  fontWeight?: 'normal' | 'bold' | '100' | '200' | '300' | '400' | '500' | '600' | '700' | '800' | '900'
  /** Letter spacing */
  letterSpacing?: number
  /** Line height */
  lineHeight?: number
  /** Text alignment */
  textAlign?: 'auto' | 'left' | 'right' | 'center' | 'justify'
  /** Text decoration line */
  textDecorationLine?: 'none' | 'underline' | 'line-through' | 'underline line-through'
  /** Text decoration style */
  textDecorationStyle?: 'solid' | 'double' | 'dotted' | 'dashed'
  /** Text decoration color */
  textDecorationColor?: string
  /** Text shadow color */
  textShadowColor?: string
  /** Text shadow offset */
  textShadowOffset?: { width: number; height: number }
  /** Text shadow radius */
  textShadowRadius?: number
  /** Text transform */
  textTransform?: 'none' | 'capitalize' | 'uppercase' | 'lowercase'
}

/**
 * Combined Text style type.
 */
export type TextStyle = ViewStyle & TextStyleProps

/**
 * Image-specific style properties.
 */
export interface ImageStyleProps {
  /** Resize mode */
  resizeMode?: 'cover' | 'contain' | 'stretch' | 'repeat' | 'center'
  /** Tint color */
  tintColor?: string
}

/**
 * Combined Image style type.
 */
export type ImageStyle = ViewStyle & ImageStyleProps

// ============================================================================
// Component Props Types
// ============================================================================

/**
 * Base props for all components.
 */
export interface BaseProps {
  /** Unique identifier */
  id?: string
  /** Test ID for testing */
  testID?: string
  /** Accessibility label */
  accessibilityLabel?: string
  /** Accessibility hint */
  accessibilityHint?: string
  /** Accessibility value announced by the native host */
  accessibilityValue?: string | number
  /** Accessibility state exposed to assistive technologies */
  accessibilityState?: AccessibilityState
  /** Accessibility role */
  accessibilityRole?: 'none' | 'button' | 'link' | 'image' | 'text' | 'header' | 'search' | 'menu'
  /** Children elements */
  children?: any
}

export interface AccessibilityState {
  disabled?: boolean
  selected?: boolean
  checked?: boolean
}

/**
 * View component props.
 */
export interface ViewProps extends BaseProps {
  /** Style object or array */
  style?: ViewStyle | ViewStyle[]
  /** Press handler */
  onPress?: () => void
  /** Long press handler */
  onLongPress?: () => void
  /** Layout change handler */
  onLayout?: (event: LayoutEvent) => void
  /** Pointer events behavior */
  pointerEvents?: 'auto' | 'none' | 'box-none' | 'box-only'
}

/**
 * Text component props.
 */
export interface TextProps extends BaseProps {
  /** Style object or array */
  style?: TextStyle | TextStyle[]
  /** Number of lines before truncation */
  numberOfLines?: number
  /** Ellipsize mode */
  ellipsizeMode?: 'head' | 'middle' | 'tail' | 'clip'
  /** Selectable text */
  selectable?: boolean
  /** Press handler */
  onPress?: () => void
  /** Long press handler */
  onLongPress?: () => void
}

/**
 * Image source type.
 */
export type ImageSource =
  | { uri: string; width?: number; height?: number; headers?: Record<string, string> }
  | number // For bundled images

/**
 * Image component props.
 */
export interface ImageProps extends BaseProps {
  /** Image source */
  source: ImageSource
  /** Style object or array */
  style?: ImageStyle | ImageStyle[]
  /** Resize mode */
  resizeMode?: 'cover' | 'contain' | 'stretch' | 'repeat' | 'center'
  /** Load start handler */
  onLoadStart?: () => void
  /** Load handler */
  onLoad?: () => void
  /** Load end handler */
  onLoadEnd?: () => void
  /** Error handler */
  onError?: (error: Error) => void
  /** Default source while loading */
  defaultSource?: ImageSource
  /** Blur radius */
  blurRadius?: number
  /** Fade duration (ms) */
  fadeDuration?: number
  /** Alt text for accessibility */
  alt?: string
}

/**
 * ScrollView component props.
 */
export interface ScrollViewProps extends ViewProps {
  /** Horizontal scrolling */
  horizontal?: boolean
  /** Show horizontal scroll indicator */
  showsHorizontalScrollIndicator?: boolean
  /** Show vertical scroll indicator */
  showsVerticalScrollIndicator?: boolean
  /** Paging enabled */
  pagingEnabled?: boolean
  /** Bounce enabled */
  bounces?: boolean
  /** Always bounce vertical */
  alwaysBounceVertical?: boolean
  /** Always bounce horizontal */
  alwaysBounceHorizontal?: boolean
  /** Scroll enabled */
  scrollEnabled?: boolean
  /** Scroll handler */
  onScroll?: (event: ScrollEvent) => void
  /** Scroll begin drag handler */
  onScrollBeginDrag?: () => void
  /** Scroll end drag handler */
  onScrollEndDrag?: () => void
  /** Momentum scroll begin handler */
  onMomentumScrollBegin?: () => void
  /** Momentum scroll end handler */
  onMomentumScrollEnd?: () => void
  /** Content container style */
  contentContainerStyle?: ViewStyle
  /** Keyboard dismiss mode */
  keyboardDismissMode?: 'none' | 'on-drag' | 'interactive'
  /** Keyboard should persist taps */
  keyboardShouldPersistTaps?: 'always' | 'never' | 'handled'
  /** Refresh control component */
  refreshControl?: any
}

/**
 * Pressable component props.
 */
export interface PressableProps extends ViewProps {
  /** Disabled state */
  disabled?: boolean
  /** Press in handler */
  onPressIn?: () => void
  /** Press out handler */
  onPressOut?: () => void
  /** Hit slop for touch area */
  hitSlop?: number | { top?: number; right?: number; bottom?: number; left?: number }
  /** Press retention offset */
  pressRetentionOffset?: number | { top?: number; right?: number; bottom?: number; left?: number }
  /** Android ripple effect */
  android_ripple?: { color?: string; borderless?: boolean; radius?: number }
  /** Delay for long press */
  delayLongPress?: number
}

/**
 * TextInput component props.
 */
export interface TextInputProps extends BaseProps {
  /** Style object or array */
  style?: TextStyle | TextStyle[]
  /** Current value */
  value?: string
  /** Default value */
  defaultValue?: string
  /** Placeholder text */
  placeholder?: string
  /** Placeholder text color */
  placeholderTextColor?: string
  /** Keyboard type */
  keyboardType?: 'default' | 'email-address' | 'numeric' | 'phone-pad' | 'decimal-pad' | 'url'
  /** Return key type */
  returnKeyType?: 'done' | 'go' | 'next' | 'search' | 'send'
  /** Auto capitalize */
  autoCapitalize?: 'none' | 'sentences' | 'words' | 'characters'
  /** Auto correct */
  autoCorrect?: boolean
  /** Auto focus */
  autoFocus?: boolean
  /** Secure text entry (password) */
  secureTextEntry?: boolean
  /** Multi-line input */
  multiline?: boolean
  /** Number of lines for multiline */
  numberOfLines?: number
  /** Max length */
  maxLength?: number
  /** Editable state */
  editable?: boolean
  /** Selection color */
  selectionColor?: string
  /** Change text handler */
  onChangeText?: (text: string) => void
  /** Focus handler */
  onFocus?: () => void
  /** Blur handler */
  onBlur?: () => void
  /** Submit editing handler */
  onSubmitEditing?: () => void
  /** End editing handler */
  onEndEditing?: () => void
}

/**
 * FlatList component props.
 */
export interface FlatListProps<T> extends ScrollViewProps {
  /** Data array */
  data: T[]
  /** Render item function */
  renderItem: (info: { item: T; index: number }) => any
  /** Key extractor function */
  keyExtractor?: (item: T, index: number) => string
  /** Item separator component */
  ItemSeparatorComponent?: any
  /** List header component */
  ListHeaderComponent?: any
  /** List footer component */
  ListFooterComponent?: any
  /** Empty list component */
  ListEmptyComponent?: any
  /** Number of columns */
  numColumns?: number
  /** Initial number to render */
  initialNumToRender?: number
  /** Max to render per batch */
  maxToRenderPerBatch?: number
  /** Window size */
  windowSize?: number
  /** Get item layout for optimization */
  getItemLayout?: (data: T[] | null, index: number) => { length: number; offset: number; index: number }
  /** End reached handler */
  onEndReached?: () => void
  /** End reached threshold */
  onEndReachedThreshold?: number
  /** Refresh handler */
  onRefresh?: () => void
  /** Refreshing state */
  refreshing?: boolean
}

// ============================================================================
// Event Types
// ============================================================================

/**
 * Layout event.
 */
export interface LayoutEvent {
  nativeEvent: {
    layout: {
      x: number
      y: number
      width: number
      height: number
    }
  }
}

/**
 * Scroll event.
 */
export interface ScrollEvent {
  nativeEvent: {
    contentOffset: { x: number; y: number }
    contentSize: { width: number; height: number }
    layoutMeasurement: { width: number; height: number }
  }
}

// ============================================================================
// Platform Utilities
// ============================================================================

/**
 * Platform-specific value selection.
 *
 * @example
 * ```typescript
 * const fontSize = Platform.select({
 *   ios: 17,
 *   android: 16,
 *   default: 16
 * })
 *
 * const Component = Platform.select({
 *   ios: IOSComponent,
 *   android: AndroidComponent,
 *   default: WebComponent
 * })
 * ```
 */
export const Platform = {
  /** Current platform */
  OS: detectOS() as 'ios' | 'android' | 'web',

  /** Platform version */
  Version: getOSVersion() as string,

  /**
   * Check if running on iOS.
   */
  isIOS(): boolean {
    return this.OS === 'ios'
  },

  /**
   * Check if running on Android.
   */
  isAndroid(): boolean {
    return this.OS === 'android'
  },

  /**
   * Check if running on web.
   */
  isWeb(): boolean {
    return this.OS === 'web'
  },

  /**
   * Select platform-specific value.
   *
   * @param specifics - Object with platform-specific values
   * @returns Value for current platform
   */
  select<T>(specifics: { ios?: T; android?: T; web?: T; default?: T }): T | undefined {
    if (this.OS === 'ios' && specifics.ios !== undefined) return specifics.ios
    if (this.OS === 'android' && specifics.android !== undefined) return specifics.android
    if (this.OS === 'web' && specifics.web !== undefined) return specifics.web
    return specifics.default
  }
}

/**
 * Create platform-specific stylesheet.
 *
 * @example
 * ```typescript
 * const styles = StyleSheet.create({
 *   container: {
 *     flex: 1,
 *     backgroundColor: '#fff',
 *     padding: 16
 *   },
 *   title: {
 *     fontSize: 24,
 *     fontWeight: 'bold'
 *   }
 * })
 * ```
 */
export const StyleSheet = {
  /**
   * Create a stylesheet from style definitions.
   */
  create<T extends Record<string, ViewStyle | TextStyle | ImageStyle>>(styles: T): T {
    return styles
  },

  /**
   * Flatten an array of styles into a single object.
   */
  flatten<T>(style: T | T[] | undefined): T | undefined {
    if (!style) return undefined
    if (Array.isArray(style)) {
      return Object.assign({}, ...style)
    }
    return style
  },

  /**
   * Get the absolute fill style (full parent).
   */
  absoluteFill: {
    position: 'absolute' as const,
    top: 0,
    left: 0,
    right: 0,
    bottom: 0
  },

  /**
   * Get hairline width (1px on device).
   */
  hairlineWidth: (typeof window !== 'undefined' ? 1 / (window.devicePixelRatio || 1) : 1) as number
}

/**
 * Animated API for animations.
 * Simplified version for common animations.
 *
 * @example
 * ```typescript
 * const opacity = new Animated.Value(0)
 *
 * // Fade in
 * Animated.timing(opacity, {
 *   toValue: 1,
 *   duration: 300,
 *   useNativeDriver: true
 * }).start()
 *
 * // Spring animation
 * Animated.spring(scale, {
 *   toValue: 1.2,
 *   friction: 3,
 *   useNativeDriver: true
 * }).start()
 * ```
 */
class AnimatedValue {
  private _value: number
  private _listeners: Array<(value: number) => void> = []

  constructor(value: number) {
    this._value = value
  }

  setValue(value: number): void {
    this._value = value
    this._listeners.forEach(listener => listener(value))
  }

  getValue(): number {
    return this._value
  }

  addListener(callback: (value: number) => void): string {
    this._listeners.push(callback)
    return String(this._listeners.length - 1)
  }

  removeListener(id: string): void {
    const index = parseInt(id, 10)
    if (index >= 0 && index < this._listeners.length) {
      this._listeners.splice(index, 1)
    }
  }

  removeAllListeners(): void {
    this._listeners = []
  }
}

type AnimationResult = { start(callback?: (result: { finished: boolean }) => void): void; stop(): void }
type TimingConfig = { toValue: number; duration?: number; delay?: number; easing?: (t: number) => number; useNativeDriver?: boolean }
type SpringConfig = { toValue: number; friction?: number; tension?: number; useNativeDriver?: boolean }

function animatedTiming(value: AnimatedValue, config: TimingConfig): AnimationResult {
  return {
    start(callback?: (result: { finished: boolean }) => void) {
      const startValue = value.getValue()
      const startTime = Date.now()
      const duration = config.duration || 300

      const animate = () => {
        const elapsed = Date.now() - startTime - (config.delay || 0)
        if (elapsed < 0) {
          requestAnimationFrame(animate)
          return
        }

        const progress = Math.min(elapsed / duration, 1)
        const easedProgress = config.easing ? config.easing(progress) : progress
        const currentValue = startValue + (config.toValue - startValue) * easedProgress

        value.setValue(currentValue)

        if (progress < 1) {
          requestAnimationFrame(animate)
        }
else {
          callback?.({ finished: true })
        }
      }

      requestAnimationFrame(animate)
    },
    stop() {
      // Stop animation
    },
  }
}

export const Animated: {
  Value: typeof AnimatedValue
  timing(value: AnimatedValue, config: TimingConfig): AnimationResult
  spring(value: AnimatedValue, config: SpringConfig): AnimationResult
  parallel(animations: Array<{ start: (callback?: (result: { finished: boolean }) => void) => void }>): AnimationResult
  sequence(animations: Array<{ start: (callback?: (result: { finished: boolean }) => void) => void }>): AnimationResult
} = {
  /**
   * Animated value class.
   */
  Value: AnimatedValue,

  /**
   * Create a timing animation.
   */
  timing: animatedTiming,

  /**
   * Create a spring animation.
   */
  spring(
    value: AnimatedValue,
    config: SpringConfig,
  ) {
    return {
      start(callback?: (result: { finished: boolean }) => void) {
        // Simplified spring using timing with ease-out
        const duration = 300 * (config.friction || 7) / 7
        animatedTiming(value, {
          toValue: config.toValue,
          duration,
          easing: (t: number) => 1 - (1 - t) ** 3,
          useNativeDriver: config.useNativeDriver,
        }).start(callback)
      },
      stop() {
        // Stop animation
      },
    }
  },

  /**
   * Run animations in parallel.
   */
  parallel(
    animations: Array<{ start: (callback?: (result: { finished: boolean }) => void) => void }>
  ) {
    return {
      start(callback?: (result: { finished: boolean }) => void) {
        let completed = 0
        const total = animations.length

        if (total === 0) {
          callback?.({ finished: true })
          return
        }

        animations.forEach(anim => {
          anim.start(() => {
            completed++
            if (completed === total) {
              callback?.({ finished: true })
            }
          })
        })
      },
      stop() {
        // Stop all animations
      }
    }
  },

  /**
   * Run animations in sequence.
   */
  sequence(
    animations: Array<{ start: (callback?: (result: { finished: boolean }) => void) => void }>
  ) {
    return {
      start(callback?: (result: { finished: boolean }) => void) {
        const runNext = (index: number) => {
          if (index >= animations.length) {
            callback?.({ finished: true })
            return
          }
          animations[index].start(() => runNext(index + 1))
        }
        runNext(0)
      },
      stop() {
        // Stop animations
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

function detectOS(): 'ios' | 'android' | 'web' {
  if (typeof window === 'undefined') return 'web'
  const ua = navigator.userAgent.toLowerCase()
  if (/iphone|ipad|ipod/.test(ua)) return 'ios'
  if (/android/.test(ua)) return 'android'
  return 'web'
}

function getOSVersion(): string {
  if (typeof window === 'undefined') return 'unknown'
  const ua = navigator.userAgent
  const match = ua.match(/(?:iPhone|iPad|iPod).*?OS (\d+)/) ||
                ua.match(/Android (\d+)/)
  return match ? match[1] : 'unknown'
}

// ============================================================================
// Exports
// ============================================================================

const components: {
  Platform: typeof Platform
  StyleSheet: typeof StyleSheet
  Animated: typeof Animated
} = {
  Platform: Platform,
  StyleSheet: StyleSheet,
  Animated: Animated
}

export default components

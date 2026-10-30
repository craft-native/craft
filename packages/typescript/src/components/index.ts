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
  /** Flex/grid sibling order; equal values retain source order */
  order?: number
  /** Justify content (main axis) */
  justifyContent?: 'flex-start' | 'flex-end' | 'center' | 'space-between' | 'space-around' | 'space-evenly'
  /** Align items (cross axis); baseline aligns text-bearing children by their first baseline */
  alignItems?: 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'baseline'
  /** Align self (override parent alignItems), including first-baseline alignment */
  alignSelf?: 'auto' | 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'baseline'
  /** Align content (multi-line) */
  alignContent?: 'flex-start' | 'flex-end' | 'center' | 'stretch' | 'space-between' | 'space-around' | 'space-evenly'
  /** Gap between items */
  gap?: number
  /** Row gap */
  rowGap?: number
  /** Column gap */
  columnGap?: number
}

/** Hit targeting at an authored native component boundary. */
export type PointerEvents = 'auto' | 'none' | 'box-none' | 'box-only'

/**
 * Layout style properties.
 */
export interface LayoutStyle {
  /** Native pointer policy; a non-null prop overrides this style value. */
  pointerEvents?: PointerEvents | null
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
  display?: 'flex' | 'none' | 'grid'
  /** Equal-width grid track count or CSS-shaped `repeat(N, 1fr)` tracks. */
  gridTemplateColumns?: number | string
  /** Equal-height grid track count or CSS-shaped `repeat(N, 1fr)` tracks. */
  gridTemplateRows?: number | string
  /** Legacy numeric alias for the grid track count. */
  gridColumns?: number
  /** Intrinsic or fixed height for automatically-created grid rows. */
  gridAutoRows?: number | string
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
  /** Linear-gradient direction used by native hosts. */
  gradientDirection?: 'to-t' | 'to-tr' | 'to-r' | 'to-br' | 'to-b' | 'to-bl' | 'to-l' | 'to-tl'
  /** Linear-gradient start color. */
  gradientFrom?: string
  /** Optional linear-gradient middle stop. */
  gradientVia?: string
  /** Linear-gradient end color. */
  gradientTo?: string
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
  fontWeight?: number | 'normal' | 'bold' | '100' | '200' | '300' | '400' | '500' | '600' | '700' | '800' | '900'
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
  resizeMode?: 'cover' | 'contain' | 'stretch' | 'center'
  /** Tint color */
  tintColor?: string
}

/**
 * Combined Image style type.
 */
export type ImageStyle = ViewStyle & ImageStyleProps

/** A native style may be nested or conditionally omitted in any component's `style` prop. */
export type StyleValue<T> = T | StyleValue<T>[] | null | false | undefined

// ============================================================================
// Component Props Types
// ============================================================================

/**
 * Base props for all components.
 */
export interface BaseProps {
  /** Native hit targeting. Null clears the override and falls back to style. */
  pointerEvents?: PointerEvents | null
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
  accessibilityRole?:
    | 'none'
    | 'button'
    | 'link'
    | 'image'
    | 'text'
    | 'header'
    | 'search'
    | 'adjustable'
    | 'menu'
    | 'summary'
    | 'alert'
    | 'checkbox'
    | 'combobox'
    | 'menuitem'
    | 'progressbar'
    | 'radio'
    | 'tablist'
    | 'radiogroup'
    | 'list'
    | 'menubar'
    | 'spinbutton'
    | 'switch'
    | 'tab'
    | 'timer'
    | 'toolbar'
    | 'scrollbar'
  /** Native list chrome slot for keyed FlatList/SectionList children. */
  listRole?: 'header' | 'item' | 'separator' | 'empty' | 'footer'
  /** Matches a view across an animated state change. */
  transitionID?: string
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
  style?: StyleValue<ViewStyle>
  /** Press handler */
  onPress?: () => void
  /** DOM-compatible press alias accepted by native hosts. */
  onClick?: () => void
  /** Long press handler */
  onLongPress?: () => void
  /** Layout change handler */
  onLayout?: (event: LayoutEvent) => void
}

/** Safe-area container props used by native iOS and Android screens. */
export interface SafeAreaViewProps extends ViewProps {
  /** Insets to apply; omitted means all edges. */
  edges?: Array<'top' | 'right' | 'bottom' | 'left'>
}

/** Keyboard-aware container props used by native screens. */
export interface KeyboardAvoidingViewProps extends ViewProps {
  behavior?: 'height' | 'position' | 'padding'
  keyboardVerticalOffset?: number
}

/** Native status-bar appearance for the current screen. */
export interface StatusBarProps extends BaseProps {
  barStyle?: 'default' | 'light-content' | 'dark-content'
  hidden?: boolean
}

/** Pull-to-refresh control consumed by a parent ScrollView or FlatList. */
export interface RefreshControlProps extends BaseProps {
  refreshing?: boolean
  onRefresh?: () => void
  tintColor?: string
}

/**
 * Text component props.
 */
export interface TextProps extends BaseProps {
  /** Style object or array */
  style?: StyleValue<TextStyle>
  /** Allow the user to select and copy the rendered text. */
  selectable?: boolean
  /** Number of lines before truncation */
  numberOfLines?: number
  /** Ellipsize mode */
  ellipsizeMode?: 'head' | 'middle' | 'tail' | 'clip'
  /** Press handler */
  onPress?: () => void
  /** DOM-compatible press alias accepted by native hosts. */
  onClick?: () => void
  /** Long press handler */
  onLongPress?: () => void
}

/** Native button/link action props. */
export interface ButtonProps extends BaseProps {
  title?: string
  /** Text and layout styling applied by the native button hosts. */
  style?: StyleValue<TextStyle>
  onPress?: () => void
  onClick?: () => void
  disabled?: boolean
  color?: string
}

/** Link is a button with link semantics in the native renderer. */
export interface LinkProps extends ButtonProps {
  href?: string
  to?: string
}

export interface TouchableOpacityProps extends ViewProps {
  activeOpacity?: number
  disabled?: boolean
}

export interface TouchableHighlightProps extends ViewProps {
  underlayColor?: string
  activeOpacity?: number
  disabled?: boolean
  onShowUnderlay?: () => void
  onHideUnderlay?: () => void
}

/**
 * Image source type.
 */
export type ImageSource =
  | string
  | { uri: string; headers?: Record<string, string> }

export interface ImageErrorEvent {
  nativeEvent: {
    error: {
      message: string
    }
  }
}

/**
 * Image component props.
 */
export interface ImageProps extends BaseProps {
  /** Image source */
  source: ImageSource
  /** Style object or array */
  style?: StyleValue<ImageStyle>
  /** Resize mode */
  resizeMode?: 'cover' | 'contain' | 'stretch' | 'center'
  /** Load start handler */
  onLoadStart?: () => void
  /** Load handler */
  onLoad?: () => void
  /** Load end handler */
  onLoadEnd?: () => void
  /** Error handler; native failures are exposed as nativeEvent.error.message. */
  onError?: (event: ImageErrorEvent) => void
  /** Default source while loading */
  defaultSource?: ImageSource
  /** Alt text for accessibility */
  alt?: string
}

export interface IconProps extends BaseProps {
  style?: StyleValue<TextStyle>
  name?: string
  symbol?: string
  color?: string
}

export interface VideoProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  source?: string | { uri: string }
  src?: string
  controls?: boolean
  autoplay?: boolean
  autoPlay?: boolean
  loop?: boolean
  muted?: boolean
  /** Controlled playback position in seconds. */
  currentTime?: number
  paused?: boolean
  resizeMode?: 'contain' | 'cover' | 'stretch'
  /** The source began loading. */
  onLoadStart?: () => void
  /** The source became ready for playback. */
  onLoadEnd?: () => void
  /**
   * Carries on in a floating window (Picture in Picture) when the app goes to
   * the background or another app opens while it plays, and comes back into
   * its place with the app. iOS needs `enableBackgroundAudio`. A video with
   * sound plays mixed with the person's music either way.
   */
  pictureInPicture?: boolean
  onLoad?: (event: { duration: number }) => void
  onPlay?: () => void
  onPause?: () => void
  onEnd?: () => void
  onProgress?: (event: { currentTime: number; duration: number }) => void
  onError?: (event: { message: string }) => void
  /** It went into the floating window, and came back out (iOS). */
  onPictureInPictureStart?: () => void
  onPictureInPictureStop?: () => void
}

export interface MapRegion {
  center: { latitude: number; longitude: number }
  span: { latitudeDelta: number; longitudeDelta: number }
}

/** A keyed route overlay supplied as map data instead of a child node. */
export interface MapPolylineOverlay {
  id: string
  geometry: number[]
  strokeColor?: string
  strokeWidth?: number
}

/** A keyed marker supplied as map data instead of a child node. */
export interface MapMarkerOverlay {
  id: string
  geometry: number[]
  title?: string
  pinColor?: string
  bearing?: number
}

export interface MapProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  region?: MapRegion
  /** Initial camera region; applied once, then controlled by subsequent props. */
  initialRegion?: MapRegion
  /** A native raster basemap, with required provider attribution. */
  tileOverlay?: { urlTemplate: string, attribution: string }
  /** Logical points reserved for floating controls when fitting overlays. */
  edgePadding?: { top?: number, right?: number, bottom?: number, left?: number }
  fitToBounds?: boolean
  showsUserLocation?: boolean
  scrollEnabled?: boolean
  zoomEnabled?: boolean
  rotateEnabled?: boolean
  /** Map styles implemented consistently by the maintained iOS and Android hosts. */
  mapType?: 'standard' | 'satellite' | 'hybrid'
  showsCompass?: boolean
  showsScale?: boolean
  /** Allow tilt gestures and camera pitch updates on the native map. */
  pitchEnabled?: boolean
  /** Requested tilt in degrees; the platform may lower it for the current altitude or map type. */
  cameraPitch?: number
  cameraHeading?: number
  /** Keyed overlays for large collections; child nodes remain supported. */
  polylines?: MapPolylineOverlay[]
  markers?: MapMarkerOverlay[]
  /** A coordinate tapped on the map, excluding annotation presses. */
  onPress?: (event: { nativeEvent: { latitude: number, longitude: number } }) => void
  /** Settled camera after a person pans, rotates, zooms or tilts the map. */
  onRegionChangeComplete?: (event: { nativeEvent: MapRegion & { heading: number, pitch: number } }) => void
  onMarkerPress?: (event: { nativeEvent: { id: string } }) => void
}

export interface MapPolylineProps extends BaseProps {
  geometry: number[]
  strokeColor?: string
  strokeWidth?: number
}

export interface MapPolygonProps extends BaseProps {
  /** Flat latitude/longitude pairs; the host closes the ring for drawing. */
  geometry: number[]
  fillColor?: string
  strokeColor?: string
  strokeWidth?: number
}

export interface MapMarkerProps extends BaseProps {
  geometry: number[]
  id: string
  title?: string
  /** Tint for the native marker pin; `label` and `secondaryLabel` follow the current system appearance. */
  pinColor?: string
  /** A direction arrow in place of the default marker, clockwise from north. */
  bearing?: number
  onPress?: (event: { nativeEvent: { id: string } }) => void
  onMarkerPress?: (event: { nativeEvent: { id: string } }) => void
}

export interface ImageBackgroundProps extends ImageProps {
}

/** Shared paint and accessibility props for DOM-free native SVG nodes. */
export interface SvgPaintProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  fill?: string
  stroke?: string
  strokeWidth?: number
  strokeDasharray?: number[] | string
  strokeDashoffset?: number
  strokeLinecap?: 'butt' | 'round' | 'square'
  strokeLinejoin?: 'miter' | 'round' | 'bevel'
  strokeMiterlimit?: number
  strokeOpacity?: number
  fillOpacity?: number
  fillRule?: 'nonzero' | 'evenodd'
  vectorEffect?: 'none' | 'non-scaling-stroke'
  color?: string
  opacity?: number
  /** Font weight inherited by descendant native SVG text. */
  fontWeight?: string | number
}

/** Root native SVG drawing surface. */
export interface SvgProps extends SvgPaintProps {
  viewBox?: [number, number, number, number] | string
  preserveAspectRatio?: string
}

/** Native SVG group inheriting paint from its parent. */
export interface GProps extends SvgPaintProps {}

/** Shared generated geometry prop for native SVG shape nodes. */
export interface SvgShapeProps extends SvgPaintProps {
  geometry?: number[]
}

export interface PathProps extends SvgShapeProps {}
export interface LineProps extends SvgShapeProps {}
export interface RectProps extends SvgShapeProps {}
export interface CircleProps extends SvgShapeProps {}
export interface EllipseProps extends SvgShapeProps {}
export interface PolylineProps extends SvgShapeProps {}
export interface PolygonProps extends SvgShapeProps {}

/** Native SVG text painted in the root viewBox. */
export interface SvgTextProps extends SvgPaintProps {
  x?: number
  y?: number
  fontSize?: number
  textAnchor?: 'start' | 'middle' | 'end' | string
  dominantBaseline?: string
}

/** Shared scroll-container props consumed by ScrollView and FlatList. */
interface ScrollViewBaseProps extends ViewProps {
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
  /** Scroll a child into view when this target changes. */
  scrollTarget?: string | { id: string; animated?: boolean; key?: string } | null
  /** Controlled native pull-to-refresh component. */
  refreshControl?: RefreshControlProps
}

/**
 * ScrollView component props.
 */
export interface ScrollViewProps extends ScrollViewBaseProps {
  /** Keep indexed vertical children pinned while scrolling. */
  stickyHeaderIndices?: number[]
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
}

/**
 * TextInput component props.
 */
export interface TextInputProps extends BaseProps {
  /** Runtime acknowledgement of the latest native edit; stale controlled echoes are ignored. */
  mostRecentEventCount?: number
  clearButtonMode?: 'never' | 'while-editing' | 'unless-editing' | 'always'
  /** Style object or array */
  style?: StyleValue<TextStyle>
  /** Current value */
  value?: string
  /** Default value */
  defaultValue?: string
  /** Placeholder text */
  placeholder?: string
  /** Placeholder text color */
  placeholderTextColor?: string
  /** Keyboard type */
  keyboardType?: KeyboardType
  /** Return key type */
  returnKeyType?: ReturnKeyType
  /** Auto capitalize */
  autoCapitalize?: 'none' | 'sentences' | 'words' | 'characters'
  /** Auto correct */
  autoCorrect?: boolean
  /** Auto focus */
  autoFocus?: boolean
  /** Secure text entry (password) */
  secureTextEntry?: boolean
  /** Platform autofill content type (for example `username` or `oneTimeCode`). */
  textContentType?: string
  /** HTML-style autofill hint (for example `current-password`). */
  autoComplete?: string
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
  /** DOM-compatible change alias accepted by native hosts. */
  onChange?: (text: string) => void
  /** Focus handler */
  onFocus?: () => void
  /** Blur handler */
  onBlur?: () => void
  /** Submit editing handler */
  onSubmitEditing?: () => void
  /** End editing handler */
  onEndEditing?: () => void
}

export type KeyboardType =
  | 'default'
  | 'email-address'
  | 'numeric'
  | 'phone-pad'
  | 'number-pad'
  | 'decimal-pad'
  | 'url'
  | 'web-search'
  | 'visible-password'

export type ReturnKeyType =
  | 'done'
  | 'go'
  | 'next'
  | 'search'
  | 'send'
  | 'join'
  | 'route'
  | 'continue'
  | 'emergency-call'
  | 'default'

export interface SwitchProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  /** Controlled boolean state; malformed native bridge values stay off. */
  value?: boolean
  /** Compatibility alias used when `value` is null; `value` takes precedence. */
  checked?: boolean
  onValueChange?: (value: boolean) => void
  onChange?: (value: boolean) => void
  disabled?: boolean
  trackColor?: { false?: string; true?: string }
  thumbColor?: string
  ios_backgroundColor?: string
  /** iOS-only solid UIControl switch: opaque thumb and immediate transitions. Defaults to native UISwitch. */
  ios_solid?: boolean
}

export interface CheckboxProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  /** Controlled boolean state; malformed native bridge values stay off. */
  value?: boolean
  /** Compatibility alias; `checked` takes precedence when both are provided. */
  checked?: boolean
  indeterminate?: boolean
  label?: string
  onValueChange?: (value: boolean) => void
  onChange?: (value: boolean) => void
  disabled?: boolean
  color?: string
}

export interface SliderProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  value?: number
  minimumValue?: number
  maximumValue?: number
  step?: number
  onValueChange?: (value: number) => void
  onChange?: (value: number) => void
  onSlidingComplete?: (value: number) => void
  disabled?: boolean
  minimumTrackTintColor?: string
  maximumTrackTintColor?: string
  thumbTintColor?: string
}

export interface PickerOption {
  label: string
  /** String or finite number; other bridge values are ignored by native hosts. */
  value: string | number
}

export interface PickerProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  /** Typed options; child options remain supported when omitted. */
  items?: PickerOption[]
  /** Controlled selection alias; `selectedValue` takes precedence when set. */
  value?: string | number
  selectedValue?: string | number
  onValueChange?: (value: string | number, index: number) => void
  onChange?: (value: string | number, index: number) => void
  disabled?: boolean
}

/** Platform-owned segmented selection (UISegmentedControl / Android RadioGroup). */
export interface SegmentedControlProps extends BaseProps {
  items: Array<PickerOption & { disabled?: boolean, spoken?: string }>
  value?: string | number
  disabled?: boolean
  tintColor?: string
  onValueChange?: (event: { value: string, index: number }) => void
}

export interface DatePickerChange {
  value: string
  iso: string
  timestamp: number
}

export interface DatePickerProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  mode?: 'date' | 'time' | 'datetime' | 'datetime-local' | 'countdown'
  value?: string | number
  minimumDate?: string | number
  maximumDate?: string | number
  minuteInterval?: number
  onValueChange?: (event: DatePickerChange) => void
  onChange?: (event: DatePickerChange) => void
  disabled?: boolean
}

export interface ActivityIndicatorProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  color?: string
  animating?: boolean
  hidesWhenStopped?: boolean
  size?: 'small' | 'large' | number
}

/**
 * FlatList component props.
 */
export interface FlatListProps<T> extends ScrollViewBaseProps {
  /** Number of columns in the keyed child tree. */
  numColumns?: number
  /** Render rows in reverse order along the scroll axis. */
  inverted?: boolean
  /** End reached handler */
  onEndReached?: () => void
  /** End reached threshold */
  onEndReachedThreshold?: number
  /** Refresh handler */
  onRefresh?: () => void
  /** Refreshing state */
  refreshing?: boolean
}

/**
 * @deprecated Grouped SectionList data is deferred until the versioned native
 * list-data protocol exists. Use keyed child rows with `listRole` instead.
 */
export interface SectionListSection<T> {
  data: T[]
  key?: string
  title?: string
}

export interface SectionListProps<T> extends ScrollViewProps {
  // Grouped section data is intentionally not part of the native protocol
  // yet. Both maintained hosts use this node as a child-based ScrollView.
}

export interface ModalProps extends BaseProps {
  style?: StyleValue<ViewStyle>
  visible?: boolean
  transparent?: boolean
  /** Keep the popup interactive without blocking the screen behind it. */
  nonModal?: boolean
  /** When non-modal, consume an outside tap and call onRequestClose. */
  dismissOnOutsideTap?: boolean
  presentationStyle?: 'fullScreen' | 'pageSheet' | 'formSheet' | 'overFullScreen'
  sheetDetents?: Array<'medium' | 'large'>
  selectedDetent?: 'medium' | 'large'
  grabberVisible?: boolean
  animationType?: 'none' | 'fade' | 'slide'
  onShow?: () => void
  onDismiss?: () => void
  onRequestClose?: () => void
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
   * Flatten nested style arrays and ignore falsy conditional entries.
   */
  flatten<T>(style: StyleValue<T>): T | undefined {
    if (!style) return undefined
    const flattened: Record<string, unknown> = {}
    const merge = (value: unknown): void => {
      if (!value) return
      if (Array.isArray(value)) {
        value.forEach(merge)
        return
      }
      if (typeof value === 'object') Object.assign(flattened, value)
    }
    merge(style)
    return flattened as T
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

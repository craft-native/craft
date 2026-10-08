import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

const root = join(import.meta.dir, '..')
const ios = readFileSync(join(root, 'packages/ios/templates/CraftNativeScreen.swift'), 'utf8')
const iosFlatList = readFileSync(join(root, 'packages/ios/templates/CraftNativeFlatList.swift'), 'utf8')
const android = readFileSync(join(root, 'packages/android/templates/MainActivityNative.kt.template'), 'utf8')
const androidFlatList = readFileSync(join(root, 'packages/android/templates/CraftNativeFlatList.kt.template'), 'utf8')

/** One host-neutral vocabulary, asserted against every generated renderer. */
const COMPONENTS: Array<[string, string, string]> = [
  ['SafeAreaView', 'case "View", "SafeAreaView":', '"View", "SafeAreaView" ->'],
  ['Text', 'case "Text":', '"Text" ->'],
  ['Button', 'case "Button", "Link":', '"Button" ->'],
  ['Link', 'case "Button", "Link":', '"Link" ->'],
  ['Switch', 'case "Switch":', '"Switch" ->'],
  ['TextInput', 'case "TextInput":', '"TextInput" ->'],
  ['ActivityIndicator', 'case "ActivityIndicator":', '"ActivityIndicator" ->'],
  ['Image', 'case "Image":', '"Image" ->'],
  ['ScrollView', 'case "ScrollView":', '"ScrollView" ->'],
  ['FlatList', 'case "FlatList":', '"FlatList" ->'],
]

describe('native renderer component contract', () => {
  it('keeps the same host-neutral controls on iOS and Android', () => {
    for (const [name, iosMarker, androidMarker] of COMPONENTS) {
      expect(ios, `${name} missing from iOS renderer`).toContain(iosMarker)
      expect(android, `${name} missing from Android renderer`).toContain(androidMarker)
    }
  })

  it('applies text transforms to native action labels on both hosts', () => {
    expect(ios).toContain('let transformedTitle = transformedText(title, style: style)')
    expect(ios).toContain('private func transformedText(_ text: String, style: [String: Any])')
    expect(ios).toContain('buttonTitleAttributes(style, color: titleColor, font: font, forceUnderline: type == "Link")')
    expect(ios).toContain('button.contentHorizontalAlignment = buttonAlignment(style["textAlign"])')
    expect(android).toContain('configureText(this, title, style)')
  })

  it('keeps TextInput text styles aligned across hosts', () => {
    expect(ios).toContain('field.defaultTextAttributes = inputTextAttributes(')
    expect(ios).toContain('textView.typingAttributes = attributes')
    expect(android).toContain('configureTextStyle(this, style)')
  })

  it('keeps native capability and WebView fallback gates intact', () => {
    expect(ios).toContain('mutationProtocolVersion: 1')
    expect(android).toContain('mutationProtocolVersion: 1')
    expect(ios).toContain('Missing dist/native-screen.js')
    expect(android).toContain('Missing native-screen.js')
  })

  it('keeps responsive layout events aligned across hosts', () => {
    expect(ios).toContain('events["onLayout"]')
    expect(ios).toContain('lastLayoutFrames[id] != frame')
    expect(android).toContain('events.optString("onLayout")')
    expect(android).toContain('lastLayoutBounds[view] != bounds')
    expect(ios).toContain('"nativeEvent": ["layout": [')
    expect(android).toContain('.put("layout", JSONObject()')
  })

  it('keeps the native root inside each host safe area', () => {
    expect(ios).toContain('view.safeAreaLayoutGuide.topAnchor')
    expect(ios).toContain('view.safeAreaLayoutGuide.bottomAnchor')
    expect(android).toContain('setOnApplyWindowInsetsListener(root)')
    expect(android).toContain('WindowInsetsCompat.Type.systemBars()')
  })

  it('keeps reverse row scroll containers horizontal on both hosts', () => {
    expect(ios).toContain('|| flexDirection == "row-reverse"')
    expect(android).toContain('in setOf("row", "row-reverse")')
  })

  it('applies the shared gap fallback on both flex axes', () => {
    expect(ios).toContain('stack.rowGap = number(style["rowGap"]) ?? gap')
    expect(ios).toContain('stack.columnGap = number(style["columnGap"]) ?? gap')
    expect(android).toContain('val crossGap = if (orientation == HORIZONTAL) rowGap else columnGap')
    expect(android).toContain('crossOffset += line.cross + crossGap')
  })

  it('keeps intrinsic grid tracks equal across hosts', () => {
    expect(ios).toContain('CGFloat(columns) * columnWidth')
    expect(android).toContain('val cellWidth = columnWidths.maxOrNull() ?: 0')
    expect(android).toContain('cellWidth * columns')
  })

  it('keeps per-edge margins in native flex and grid layout', () => {
    expect(ios).toContain('marginTop: CGFloat')
    expect(ios).toContain('let horizontalMargin = number(raw["marginHorizontal"]) ?? margin')
    expect(ios).toContain('mainMargins(styles[index])')
    expect(android).toContain('style.optDouble("marginLeft", horizontal)')
    expect(android).toContain('setMargins(')
    expect(android).toContain('entry.height + (lp?.topMargin ?: 0) + (lp?.bottomMargin ?: 0)')
    expect(android).toContain('val availableWidth = max(0, layout.cellWidth - marginLeft - marginRight)')
    expect(android).toContain('val crossLeading = if (orientation == HORIZONTAL)')
  })

  it('keeps elevation visible on both native hosts', () => {
    expect(ios).toContain('let elevation = max(0, number(style["elevation"]) ?? 0)')
    expect(ios).toContain('view.layer.shadowOpacity = elevation > 0')
    expect(android).toContain('view.elevation = dp(style.optDouble("elevation", 0.0)).toFloat()')
  })

  it('keeps horizontal list rows intrinsically sized across hosts', () => {
    expect(iosFlatList).toContain('flowLayout.scrollDirection = horizontal ? .horizontal : .vertical')
    expect(iosFlatList).toContain('withHorizontalFittingPriority: .fittingSizeLevel')
    expect(iosFlatList).toContain('attributes.size.width = max(1, measured.width)')
    expect(iosFlatList).not.toContain('bounds.width * 0.8')
    expect(androidFlatList).toContain('if (horizontal) LayoutParams.WRAP_CONTENT else LayoutParams.MATCH_PARENT')
  })

  it('keeps vertical list rows intrinsically sized across hosts', () => {
    expect(iosFlatList).toContain('let target = CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height)')
    expect(iosFlatList).toContain('withHorizontalFittingPriority: .required')
    expect(iosFlatList).toContain('attributes.size.height = max(1, measured.height)')
    expect(androidFlatList).toContain('renderedLayout?.height ?: LayoutParams.WRAP_CONTENT')
    expect(androidFlatList).toContain('holder.host.addView(view, hostedLayout)')
  })

  it('keeps image source lifecycles and resize modes aligned', () => {
    expect(ios).toContain('imageTasks.removeValue(forKey: id)?.cancel()')
    expect(ios).toContain('guard self.imageSources[ObjectIdentifier(view)] == uri else { return }')
    expect(ios).toContain('image.withRenderingMode(tintedImages.contains(ObjectIdentifier(view)) ? .alwaysTemplate : .alwaysOriginal)')
    expect(ios).toContain('case "cover": return .scaleAspectFill')
    expect(android).toContain('imageJobs.remove(view)?.cancel(true)')
    expect(android).toContain('if (imageSources[view] != uri) return@runOnUiThread')
    expect(android).toContain('"cover" -> ImageView.ScaleType.CENTER_CROP')
    expect(android).toContain('view.clearColorFilter()')
  })

  it('resets removed accessibility metadata on both hosts', () => {
    expect(ios).toContain('} else if type != "TextInput" {\n            view.accessibilityValue = nil')
    expect(android).toContain('view.tooltipText = props.optString("accessibilityHint").takeIf { it.isNotBlank() }')
  })

  it('resets removed text-input colors to each host theme', () => {
    expect(ios).toContain('field.attributedPlaceholder = nil')
    expect(ios).toContain('field.tintColor = color(props["selectionColor"])')
    expect(android).toContain('inputHintDefaults.getOrPut(this)')
    expect(android).toContain('inputHighlightDefaults.getOrPut(this)')
    expect(android).toContain('inputHintDefaults.remove(it)')
  })

  it('restores native backgrounds when custom styles are removed', () => {
    expect(ios).toContain('view.backgroundColor = color(style["backgroundColor"]) ?? .clear')
    expect(android).toContain('if (defaultBackgrounds.containsKey(view))')
    expect(android).toContain('} else view.background = defaultBackground')
    expect(android).toContain('released.forEach(defaultBackgrounds::remove)')
  })

  it('refreshes theme-default native controls when traits change', () => {
    expect(ios).toContain('mutationDocument.node("root")')
    expect(ios).toContain('renderCommitted(document)')
    expect(android).toContain('override fun onConfigurationChanged(newConfig: Configuration)')
    expect(android).toContain('screen.mutations.node("root")?.let { renderCommitted(screen, it) }')
    expect(android).toContain('refreshInputDefaultsForTraitChange()')
    expect(android).toContain('val probe = EditText(this)')
  })
})

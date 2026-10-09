import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

const root = join(import.meta.dir, '..')
const ios = readFileSync(join(root, 'packages/ios/templates/CraftNativeScreen.swift'), 'utf8')
const iosFlatList = readFileSync(join(root, 'packages/ios/templates/CraftNativeFlatList.swift'), 'utf8')
const android = readFileSync(join(root, 'packages/android/templates/MainActivityNative.kt.template'), 'utf8')
const androidFlatList = readFileSync(join(root, 'packages/android/templates/CraftNativeFlatList.kt.template'), 'utf8')
const navigationHome = readFileSync(join(root, 'packages/ios/fixtures/native-navigation/Home.stx'), 'utf8')
const navigationDetails = readFileSync(join(root, 'packages/ios/fixtures/native-navigation/Details.stx'), 'utf8')
const iosNavigationScript = readFileSync(join(root, 'packages/ios/scripts/test-native-navigation.ts'), 'utf8')
const guide = readFileSync(join(root, 'docs/guides/native-stx.md'), 'utf8')

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

  it('uses image alt text as the native accessibility fallback', () => {
    expect(ios).toContain('(type == "Image" ? props["alt"] as? String : nil)')
    expect(android).toContain('props.optString("alt").takeIf { type == "Image" && it.isNotBlank() }')
    expect(guide).toContain('`Image.alt` supplies the native accessibility label')
  })

  it('applies text transforms to native action labels on both hosts', () => {
    expect(ios).toContain('let transformedTitle = transformedText(title, style: style)')
    expect(ios).toContain('private func transformedText(_ text: String, style: [String: Any])')
    expect(ios).toContain('buttonTitleAttributes(style, color: titleColor, font: font, forceUnderline: type == "Link")')
    expect(ios).toContain('let titleColor = color(props["color"]) ?? color(style["color"]) ?? .systemBlue')
    expect(ios).toContain('button.contentHorizontalAlignment = buttonAlignment(style["textAlign"])')
    expect(android).toContain('configureText(this, title, style)')
    expect(android).toContain('props.optString("color").takeIf { it.isNotBlank() }?.let { setTextColor(color(it, defaultTextColor)) }')
    expect(android).toContain('val linkColor = props.optString("color").takeIf { it.isNotBlank() } ?: style.optString("color")')
    expect(android).toContain('setTextColor(color(linkColor, Color.rgb(33, 150, 243)))')
    expect(android).toContain('(previous as? TextView)?.takeUnless { it is Button } ?: TextView(this)')
  })

  it('keeps capitalize semantics aligned across hosts', () => {
    expect(ios).toContain('text.split(separator: " ", omittingEmptySubsequences: false)')
    expect(ios).toContain('String(first).uppercased() + String(word.dropFirst())')
    expect(android).toContain('value.split(\' \').joinToString(" ")')
  })

  it('keeps native text truncation props aligned across hosts', () => {
    expect(ios).toContain('label.numberOfLines = max(0, (props["numberOfLines"] as? NSNumber)?.intValue ?? 0)')
    expect(ios).toContain('label.lineBreakMode = textLineBreakMode(props["ellipsizeMode"])')
    expect(ios).toContain('case "middle": return .byTruncatingMiddle')
    expect(android).toContain('maxLines = props.optInt("numberOfLines", 0).takeIf { it > 0 } ?: Int.MAX_VALUE')
    expect(android).toContain('"middle" -> TextUtils.TruncateAt.MIDDLE')
    expect(android).toContain('"tail" -> TextUtils.TruncateAt.END')
    expect(guide).toContain('`Text` supports positive `numberOfLines` values')
  })

  it('keeps justified text alignment active across hosts', () => {
    expect(ios).toContain('case "justify": return .justified')
    expect(android).toContain('import android.text.Layout')
    expect(android).toContain('Layout.JUSTIFICATION_MODE_INTER_WORD')
    expect(android).toContain('Layout.JUSTIFICATION_MODE_NONE')
    expect(navigationHome).toContain('testID="justified-text"')
  })

  it('keeps TextInput text styles aligned across hosts', () => {
    expect(ios).toContain('field.defaultTextAttributes = inputTextAttributes(')
    expect(ios).toContain('textView.typingAttributes = attributes')
    expect(ios).toContain('updateAuxiliaryHandler(events["onSubmitEditing"], in: &submitHandlers, for: textView)')
    expect(ios).toContain('if text == "\\n", let handler = submitHandlers[ObjectIdentifier(textView)]')
    expect(ios).toContain('textView.keyboardType = keyboardType(props["keyboardType"])')
    expect(ios).toContain('case "numeric", "number-pad": return .numberPad')
    expect(ios).toContain('case "web-search": return .webSearch')
    expect(ios).toContain('case "visible-password": return .asciiCapable')
    expect(ios).toContain('textView.returnKeyType = returnKeyType(props["returnKeyType"])')
    expect(ios).toContain('textView.isSecureTextEntry = props["secureTextEntry"] as? Bool == true')
    expect(android).toContain('configureTextStyle(this, style)')
    expect(android).toContain('"numeric", "number-pad" -> InputType.TYPE_CLASS_NUMBER')
    expect(android).toContain('"web-search" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT')
    expect(android).toContain('"visible-password" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD')
    expect(android).toContain('if (props.optBoolean("autoFocus", false) && !isFocused) post')
    expect(android).toContain('if (!isFocused) {\n                        requestFocus()')
    expect(android).toContain('reusableInput?.takeIf { it.isSingleLine == !props.optBoolean("multiline", false) }')
    expect(android).toContain('val controlledValue = props.opt("value")?.takeUnless { it == JSONObject.NULL }?.toString()')
    expect(android).toContain('setTextPreservingSelection(this, controlledValue)')
    expect(android).toContain('!props.isNull("defaultValue")')
    expect(android).toContain('screen.suppressedTextChanges.add(this)')
    expect(android).toContain('if (screen.suppressedTextChanges.remove(this@apply)) return')
    expect(android).toContain('screen.suppressedTextChanges.remove(it)')
    expect(android).toContain('val requestedValue = props.opt("value")')
    expect(android).toContain('props.optBoolean("checked", false)')
    expect(android).toContain('style.optString("tintColor").takeIf { it.isNotBlank() }')
    expect(android).toContain('style.optDouble("lineHeight", Double.NaN)')
    expect(android).toContain('field.setSelection(minOf(boundedStart, boundedEnd), maxOf(boundedStart, boundedEnd))')
    expect(android).toContain('if (seekBar.progress != snappedProgress)')
    expect(android).toContain('seekBar.progress = snappedProgress')
    expect(ios).toContain('private var inputDrafts: [String: String] = [:]')
    expect(ios).toContain('inputDrafts[current.identity] ?? props["defaultValue"] as? String')
    expect(ios).toContain('inputIdentities[id].map { inputDrafts[$0] = textView.text ?? "" }')
  })

  it('uses the shared 16-point default text size across hosts', () => {
    expect(ios).toContain('textFont(style, default: .systemFont(ofSize: 16))')
    expect(ios).toContain('field.font = textFont(style, default: .systemFont(ofSize: 16))')
    expect(ios).toContain('textView.font = textFont(style, default: .systemFont(ofSize: 16))')
    expect(android).toContain('style.optDouble("fontSize", 16.0)')
  })

  it('keeps TextInput keyboard traits aligned across hosts', () => {
    expect(ios).toContain('case "email-address": return .emailAddress')
    expect(ios).toContain('case "decimal-pad": return .decimalPad')
    expect(ios).toContain('case "done": return .done')
    expect(ios).toContain('case "characters": return .allCharacters')
    expect(android).toContain('"email-address" -> InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS')
    expect(android).toContain('"decimal-pad" -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL')
    expect(android).toContain('"done" -> EditorInfo.IME_ACTION_DONE')
    expect(android).toContain('"characters" -> InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS')
  })

  it('keeps blur and end-editing callbacks independent across hosts', () => {
    expect(ios).toContain('"nativeEvent": ["text": textView.text ?? ""]')
    expect(ios).toContain('"nativeEvent": ["text": sender.text ?? ""]')
    expect(android).toContain('val nativeEvent = JSONObject().put("text", text.toString())')
    expect(ios).toContain('updateAuxiliaryHandler(events["onBlur"], in: &blurHandlers, for: field)')
    expect(ios).toContain('updateAuxiliaryHandler(events["onEndEditing"], in: &endEditingHandlers, for: field)')
    expect(ios).toContain('if let handler = endEditingHandlers[id]')
    expect(android).toContain('val onBlur = events.optString("onBlur")')
    expect(android).toContain('val onEndEditing = events.optString("onEndEditing")')
    expect(android).toContain('screen.endEditingHandlers[view]?.let')
  })

  it('initializes uncontrolled text inputs from defaultValue only once', () => {
    expect(ios).toContain('defaultValue: previous?.view === textView')
    expect(ios).toContain('updateTextView(textView, value: (props["value"] as? String) ?? defaultValue)')
    expect(ios).toContain('else if previous?.view !== field {\n                updateField(field, value: inputDrafts[current.identity] ?? props["defaultValue"] as? String)')
    expect(android).toContain('else if (this !== previous && props.has("defaultValue") && !props.isNull("defaultValue")) setText(props.optString("defaultValue"))')
    expect(guide).toContain('`defaultValue` initializes an uncontrolled')
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

  it('keeps flex distribution inside declared min and max bounds', () => {
    expect(ios).toContain('clamp(max(0, size.width + delta), min: style.minWidth, max: style.maxWidth)')
    expect(ios).toContain('clamp(max(0, size.height + delta), min: style.minHeight, max: style.maxHeight)')
    expect(android).toContain('clamp(primary, line.entries[index].style.minWidth, line.entries[index].style.maxWidth)')
    expect(android).toContain('clamp(distributed, entry.style.minHeight, entry.style.maxHeight)')
  })

  it('treats null layout values as unset on both hosts', () => {
    expect(ios).toContain('func number(_ value: Any?) -> CGFloat?')
    expect(android).toContain('if (!raw.has(name) || raw.isNull(name)) return null')
    expect(android).toContain('raw.optDouble(name, Double.NaN)')
    expect(android).toContain('style.has("backgroundColor") && !style.isNull("backgroundColor")')
    expect(android).toContain('val width = style.optDouble("width", Double.NaN)')
    expect(android).toContain('width ?: ViewGroup.LayoutParams.WRAP_CONTENT')
    expect(android).toContain('gridAutoRows = style.optDouble("gridAutoRows", Double.NaN)')
    expect(android).toContain('raw.opt("alignSelf")')
    expect(android).toContain('raw.opt("position")')
    expect(navigationHome).toContain('style={{"width":textWidthUnset ? null : 160')
    expect(navigationHome).toContain('testID="toggle-null-width"')
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
    expect(androidFlatList).toContain('updateVisibleHolderLayoutParams()')
    expect(androidFlatList).toContain('holder.host.layoutParams = holderLayoutParams()')
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

  it('treats a null image style resize mode as unset', () => {
    expect(ios).toContain('let requestedResizeMode = style["resizeMode"] as? String ?? props["resizeMode"] as? String')
    expect(ios).toContain('image.contentMode = imageContentMode(requestedResizeMode)')
    expect(android).toContain('style.optString("resizeMode").ifBlank { props.optString("resizeMode") }')
  })

  it('preserves image failure accessibility details across reconciliation', () => {
    expect(ios).toContain('private var imageErrors: [ObjectIdentifier: String] = [:]')
    expect(ios).toContain('imageErrors[ObjectIdentifier(view)] = message')
    expect(ios).toContain('if type == "Image", let message = imageErrors[ObjectIdentifier(view)]')
    expect(android).toContain('if (control is ImageView) imageErrors[control]?.let')
    expect(android).toContain('if (!current.contains(message))')
    expect(android).toContain('current.ifBlank { view.tag?.toString() ?: "Image" }')
    expect(android).toContain('joinToString(", ")')
  })

  it('keeps activity indicator visibility and sizing props aligned', () => {
    expect(ios).toContain('if let numericSize = requestedSize as? NSNumber')
    expect(ios).toContain('indicator.transform = CGAffineTransform(scaleX: scale, y: scale)')
    expect(ios).toContain('indicator.hidesWhenStopped = props["hidesWhenStopped"] as? Bool ?? true')
    expect(ios).toContain('indicator.stopAnimating()')
    expect(android).toContain('val requestedSize = props.opt("size")')
    expect(android).toContain('is Number -> (requestedSize.toDouble() / 24.0).toFloat().coerceAtLeast(0.5f)')
    expect(android).toContain('isIndeterminate = animating')
    expect(android).toContain('props.optBoolean("hidesWhenStopped", true)')
  })

  it('snaps controlled slider values on initial render across hosts', () => {
    expect(ios).toContain('slider.value = snappedSliderValue(value, for: slider)')
    expect(android).toContain('val requested = props.optDouble("value", minimum)')
    expect(android).toContain('val value = if (step != null) minimum + ((requested - minimum) / step).roundToInt() * step else requested')
    expect(android).toContain('progress = (((value - minimum) / (maximum - minimum)) * max).roundToInt()')
  })

  it('resets removed accessibility metadata on both hosts', () => {
    expect(ios).toContain('} else if type != "TextInput" {\n            view.accessibilityValue = nil')
    expect(android).toContain('view.contentDescription = when {')
    expect(android).toContain('else -> null')
    expect(android).toContain('view.tooltipText = props.optString("accessibilityHint").takeIf { it.isNotBlank() }')
    expect(android).toContain('info.hintText = host.tooltipText')
    expect(android).toContain('info.isEnabled = host.isEnabled && !disabled')
  })

  it('keeps generic pressable views interactive without disabling scroll containers', () => {
    expect(ios).toContain('if !(view is UIScrollView) { view.isUserInteractionEnabled = handler != nil || longPressHandlers[id] != nil || view is CraftNativeFlowView }')
    expect(ios).toContain('if let handler, !handler.isEmpty { handlers[id] = handler }')
    expect(ios).toContain('let handler = handler?.isEmpty == false ? handler : nil')
    expect(ios).toContain('list.onMomentumScrollEnd = nonEmptyHandler(events["onMomentumScrollEnd"]).map')
    expect(ios).toContain('private func nonEmptyHandler(_ handler: String?) -> String?')
    expect(ios).toContain('nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"])')
    expect(ios).toContain('nonEmptyHandler(events["onChange"]) ?? nonEmptyHandler(events["onChangeText"])')
    expect(ios).toContain('nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"])')
    expect(android).toContain('control.isClickable = true')
    expect(android).toContain('control.setOnClickListener {')
  })

  it('delivers long-press events and releases their native handlers', () => {
    expect(ios).toContain('private var longPressHandlers: [ObjectIdentifier: String] = [:]')
    expect(ios).toContain('UILongPressGestureRecognizer(target: self, action: #selector(viewLongPressed(_:)))')
    expect(ios).toContain('guard sender.state == .began')
    expect(ios).toContain('longPressRecognizers.removeValue(forKey: id)')
    expect(ios).toContain('handlers[ObjectIdentifier(view)] != nil || longPressHandlers[ObjectIdentifier(view)] != nil')
    expect(android).toContain('val longPressHandlers = mutableMapOf<View, String>()')
    expect(android).toContain('events.optString("onLongPress")')
    expect(android).toContain('control.setOnLongClickListener {')
    expect(android).toContain('screen.longPressHandlers.keys.removeAll(released)')
    expect(guide).toContain('`onLongPress`')
    expect(ios).toContain('if !(view is UIScrollView) { view.isUserInteractionEnabled = true }')
    expect(ios).toContain('view.isUserInteractionEnabled = handlers[id] != nil || view is CraftNativeFlowView')
  })

  it('lets accessibility disabled state disable controls without re-enabling them', () => {
    expect(ios).toContain('if let control = view as? UIControl {')
    expect(ios).toContain('else if handlers[ObjectIdentifier(view)] != nil || longPressHandlers[ObjectIdentifier(view)] != nil {')
    expect(android).toContain('} else if (disabled) {\n            view.isEnabled = false')
    expect(android).not.toContain('if (state != null && state.has("disabled")) view.isEnabled = !disabled')
  })

  it('restores generic Android pressables when accessibility disabled clears', () => {
    expect(android).toContain('if (type !in setOf("Button", "Link", "TextInput", "Switch", "Slider", "ActivityIndicator")) {\n            view.isEnabled = !disabled')
  })

  it('dismisses the keyboard from native scroll containers on drag', () => {
    expect(ios).toContain('scroll.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])')
    expect(ios).toContain('case "interactive": return .interactive')
    expect(android).toContain('keyboardDismissMode: String')
    expect(android).toContain('keyboardDismissMode in setOf("on-drag", "interactive")')
    expect(android).toContain('hideSoftInputFromWindow(nativeScroll.windowToken, 0)')
    expect(ios).toContain('list.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])')
    expect(android).toContain('setKeyboardDismissMode(props.optString("keyboardDismissMode"))')
    expect(androidFlatList).toContain('fun setKeyboardDismissMode(mode: String, dismissKeyboard: () -> Unit)')
    expect(androidFlatList).toContain('android.view.MotionEvent.ACTION_MOVE')
    expect(navigationHome).toContain('<ScrollView testID="native-scroll" keyboardDismissMode="on-drag"')
    expect(guide).toContain('both hosts, including keyboard and return-key traits on multiline inputs')
    expect(guide).toContain('`ScrollView` and `FlatList` emit the scroll callbacks described above, accept')
  })

  it('delivers ScrollView momentum callbacks on both hosts', () => {
    expect(ios).toContain('events["onMomentumScrollBegin"]')
    expect(ios).toContain('scrollViewWillBeginDecelerating')
    expect(ios).toContain('scrollViewDidEndDecelerating')
    expect(android).toContain('scrollMomentumBeginHandlers')
    expect(android).toContain('onMomentumBegin: (() -> Unit)?')
    expect(android).toContain('if (moved && !momentumActive)')
    expect(guide).toContain('`onMomentumScrollBegin` and `onMomentumScrollEnd`')
  })

  it('forwards FlatList scroll and momentum callbacks through virtualized hosts', () => {
    expect(ios).toContain('list.onScrollEvent = nonEmptyHandler(events["onScroll"])')
    expect(iosFlatList).toContain('var onMomentumScrollBegin: ((UIScrollView) -> Void)?')
    expect(iosFlatList).toContain('func scrollViewDidEndDecelerating')
    expect(android).toContain('list.onScrollEvent = events.optString("onScroll")')
    expect(androidFlatList).toContain('var onMomentumScrollEnd: (() -> Unit)? = null')
    expect(androidFlatList).toContain('RecyclerView.SCROLL_STATE_SETTLING')
  })

  it('falls back from null FlatList thresholds consistently', () => {
    expect(android).toContain('props.opt("onEndReachedThreshold")')
    expect(android).toContain('takeUnless { it == JSONObject.NULL }')
    expect(android).toContain('props.optDouble("threshold", 0.1)')
    expect(navigationDetails).toContain('onEndReachedThreshold={null}')
    expect(navigationDetails).toContain('threshold={0.8}')
  })

  it('emits onLayout for virtualized rows on both hosts', () => {
    expect(ios).toContain('flatListRows[ObjectIdentifier(list)]?.values.forEach { emitLayoutEvents(for: $0) }')
    expect(android).toContain('private fun emitLayoutEvents(screen: Screen, view: View)')
    expect(androidFlatList).toContain('var onLayoutChanged: (() -> Unit)? = null')
    expect(androidFlatList).toContain('onLayoutChanged?.invoke()')
    expect(androidFlatList).toContain('override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int)')
    expect(android).toContain('list.onLayoutChanged = {')
    expect(iosFlatList).toContain('onLayoutChanged?()')
  })

  it('keeps the native navigation fixture honest about recycled row layouts', () => {
    const details = readFileSync(join(root, 'packages/ios/fixtures/native-navigation/Details.stx'), 'utf8')
    const iosTests = readFileSync(join(root, 'packages/ios/fixtures/native-navigation/NativeNavigationUITests.swift'), 'utf8')
    const androidTests = readFileSync(join(root, 'packages/android/fixtures/native-navigation/NativeNavigationTest.kt'), 'utf8')
    expect(details).toContain('onLayout={captureRowLayout}')
    expect(details).toContain('testID="people-layout-status"')
    expect(iosTests).toContain('FlatList did not report a row layout after recycling')
    expect(androidTests).toContain('awaitLayoutIncrease(activity, "people-layout-status", initialRowLayouts)')
    expect(androidTests).not.toContain('Rows laid out: ${initialRowLayouts + 1}')
    expect(iosNavigationScript).toContain("const prepareOnly = process.argv.includes('--prepare-only')")
    expect(iosNavigationScript).toContain("console.log('iOS native navigation fixture prepared')")
  })

  it('retains keyed iOS input drafts while FlatList rows recycle', () => {
    expect(ios).toContain('self.forgetHandlers(row, preservingInputDrafts: true)')
    expect(ios).toContain('private func forgetHandlers(_ node: RenderedNode, preservingInputDrafts: Bool = false)')
    expect(android).toContain('screen.drafts[identity] = updated')
    expect(android).toContain('val inputIdentities = mutableMapOf<EditText, String>()')
    expect(android).toContain('if (!preservingInputDrafts) identity?.let(screen.drafts::remove)')
    expect(android).toContain('releaseViewState(screen, controls.values.toList(), preservingInputDrafts = true)')
  })

  it('releases replaced iOS row roots when a keyed identity changes type', () => {
    expect(ios).toContain('if let previous, previous.view !== next.view {')
    expect(ios).toContain('self.forgetHandlers(previous)')
  })

  it('resets FlatList end-reached state when any data row changes', () => {
    expect(iosFlatList).toContain('private var dataContentSignature = ""')
    expect(iosFlatList).toContain('dataContentSignature = contentSignature')
    expect(iosFlatList).toContain('let signature = dataContentSignature')
    expect(iosFlatList).not.toContain('let signature = "\\(dataIndices.count):\\(lastIdentity)"')
    expect(androidFlatList).toContain('private var dataContentSignature = ""')
    expect(androidFlatList).toContain('dataContentSignature = contentSignature')
    expect(androidFlatList).toContain('val signature = dataContentSignature')
    expect(androidFlatList).not.toContain('val signature = "${dataPositions.size}:$lastIdentity"')
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
    expect(ios).toContain('private func refreshTraitDefaults()')
    expect(ios).toContain('refreshTraitDefaults()')
    expect(ios).toContain('override func viewWillAppear(_ animated: Bool)')
    expect(android).toContain('override fun onConfigurationChanged(newConfig: Configuration)')
    expect(android).toContain('screen.mutations.node("root")?.let { renderCommitted(screen, it) }')
    expect(android).toContain('private fun refreshScreenTheme(screen: Screen)')
    expect(android).toContain('refreshScreenTheme(screen)')
    expect(android).toContain('private fun refreshThemeDefaults()')
    expect(android).toContain('refreshThemeDefaults()')
    expect(android).toContain('refreshInputDefaultsForTraitChange()')
    expect(android).toContain('val probe = EditText(this)')
  })

  it('rebinds unchanged virtualized rows when theme traits change', () => {
    expect(iosFlatList).toContain('func refreshThemeDefaults()')
    expect(iosFlatList).toContain('snapshot.reconfigureItems(identities)')
    expect(iosFlatList).toContain('private var pendingThemeRefresh = false')
    expect(iosFlatList).toContain('pendingThemeRefresh = true')
    expect(iosFlatList).toContain('if self.pendingThemeRefresh')
    expect(iosFlatList).toContain('isApplyingSnapshot = true')
    expect(ios).toContain('refreshTraitDefaults(in: renderedRoot)')
    expect(androidFlatList).toContain('fun refreshThemeDefaults()')
    expect(androidFlatList).toContain('notifyItemRangeChanged(0, listAdapter.itemCount)')
    expect(androidFlatList).toContain('private var pendingThemeRefresh = false')
    expect(androidFlatList).toContain('if (isSubmittingList)')
    expect(androidFlatList).toContain('if (pendingThemeRefresh)')
    expect(android).toContain('filterIsInstance<CraftNativeFlatList>().forEach { it.refreshThemeDefaults() }')
  })

  it('keeps scroll bounce behavior aligned across hosts', () => {
    expect(ios).toContain('scroll.bounces = props["bounces"] as? Bool ?? true')
    expect(ios).toContain('list.bounces = props["bounces"] as? Bool ?? true')
    expect(android).toContain('fun setBounces(value: Boolean)')
    expect(android).toContain('setBounces(props.optBoolean("bounces", true))')
    expect(android).toContain('private fun applyBounceModes()')
    expect(android).toContain('if (bounces && alwaysBounceVertical) View.OVER_SCROLL_ALWAYS')
    expect(guide).toContain('`bounces`, `alwaysBounceVertical`, and `alwaysBounceHorizontal` to control the')
  })

  it('keeps ScrollView paging behavior aligned across hosts', () => {
    expect(ios).toContain('scroll.isPagingEnabled = props["pagingEnabled"] as? Bool ?? false')
    expect(android).toContain('fun setPagingEnabled(value: Boolean)')
    expect(android).toContain('if (pagingEnabled) snapToPage(scroller)')
    expect(android).toContain('setPagingEnabled(props.optBoolean("pagingEnabled", false))')
    expect(guide).toContain('`pagingEnabled` snaps `ScrollView` content')
  })

  it('keeps ScrollView bounce axes aligned across hosts', () => {
    expect(ios).toContain('scroll.alwaysBounceVertical = props["alwaysBounceVertical"] as? Bool ?? (direction == .vertical)')
    expect(ios).toContain('scroll.alwaysBounceHorizontal = props["alwaysBounceHorizontal"] as? Bool ?? (direction == .horizontal)')
    expect(android).toContain('fun setAlwaysBounce(vertical: Boolean, horizontal: Boolean)')
    expect(android).toContain('alwaysBounceVertical')
    expect(android).toContain('alwaysBounceHorizontal')
    expect(android).toContain('setAlwaysBounce(')
  })
})

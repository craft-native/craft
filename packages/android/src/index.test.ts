import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { gunzipSync } from 'node:zlib'
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'bun:test'
import { compressNativeSources, ANDROID_MIN_SDK, build, init, installRuntime, renderAndroidDeepLinks, renderAndroidPermissions, resolveRuntimeDir, runPostGenerateHook, syncAndroidWebAssets, syncNativeFonts } from './index'
import { createTempDir, removeAllTempDirs } from '../../typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

function generatedFiles(path: string): string[] {
  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = join(path, entry.name)
    return entry.isDirectory() ? generatedFiles(entryPath) : [entryPath]
  })
}

describe('Craft Android builder', () => {
  it('runs a declared postGenerate command from the project root with metadata', async () => {
    const output = createTempDir('craft-android-post-generate-')
    await init({ name: 'Hook App', output, runtimeDir: null, config: {
      postGenerate: { command: 'sh', args: ['-c', 'printf "%s|%s|%s" "$PWD" "$CRAFT_PLATFORM" "$CRAFT_GENERATE_PHASE" > hook.txt'] },
    } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.postGenerate).toEqual({ command: 'sh', args: ['-c', 'printf "%s|%s|%s" "$PWD" "$CRAFT_PLATFORM" "$CRAFT_GENERATE_PHASE" > hook.txt'] })
    runPostGenerateHook(config.postGenerate, output)
    expect(readFileSync(join(output, 'hook.txt'), 'utf8')).toBe(`${realpathSync(output)}|android|build`)
  })

  it('runs the postGenerate hook during the Android build before compilation', async () => {
    const output = createTempDir('craft-android-post-generate-build-')
    await init({ name: 'Hook Build', output, runtimeDir: null, config: {
      postGenerate: { command: 'sh', args: ['-c', 'printf "%s" "$CRAFT_GENERATE_PHASE" > hook-phase.txt'] },
    } })
    await build({ output, compile: false })
    expect(readFileSync(join(output, 'hook-phase.txt'), 'utf8')).toBe('build')
  })

  it('reports invalid Android postGenerate commands and non-zero exits', () => {
    const output = createTempDir('craft-android-post-generate-errors-')
    expect(() => runPostGenerateHook({ command: '' }, output)).toThrow('postGenerate.command must be a non-empty executable')
    expect(() => runPostGenerateHook({ command: join(output, 'missing-hook') }, output)).toThrow('postGenerate hook could not start')
    expect(() => runPostGenerateHook({ command: 'sh', args: ['-c', 'printf "patch failed" >&2; exit 7'] }, output))
      .toThrow('postGenerate hook failed')
  })

  it('generates static tab-bar selection appearance and validates its shape', async () => {
    const output = createTempDir('craft-android-tab-bar-appearance-')
    await init({ name: 'Tab Bar', output, runtimeDir: null, config: {
      renderer: 'native',
      tabBar: { selection: { cornerRadius: 8, color: '#123456' } },
    } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const shell = readFileSync(join(output, 'app/src/main/java/com/craft/tabbar/CraftNativeShell.kt'), 'utf8')
    const activity = readFileSync(join(output, 'app/src/main/java/com/craft/tabbar/MainActivity.kt'), 'utf8')
    expect(config.tabBar).toEqual({ selection: { cornerRadius: 8, color: '#123456' } })
    expect(shell).toContain('data class CraftNativeTabBarAppearance')
    expect(shell).toContain('private fun tabCellBackground(index: Int, dark: Boolean)')
    expect(activity).toContain('routes.tabBarAppearance')
    await expect(init({ name: 'Invalid Tab Bar', output: join(output, 'invalid'), runtimeDir: null, config: {
      renderer: 'native', tabBar: { selection: { cornerRadius: -1 } },
    } })).rejects.toThrow('cornerRadius must be a finite non-negative number')
    await expect(init({ name: 'Invalid Tab Color', output: join(output, 'invalid-color'), runtimeDir: null, config: {
      renderer: 'native', tabBar: { selection: { color: 'red' } },
    } })).rejects.toThrow('color must be a #RRGGBB color')
  })


  it('bundles custom fonts with their licenses and removes retired fonts', async () => {
    const root = createTempDir('craft-native-fonts-')
    const font = join(root, 'Signature.ttf')
    const license = join(root, 'OFL.txt')
    const output = join(root, 'app')
    writeFileSync(font, new Uint8Array([0, 1, 0, 0, 7, 8]))
    writeFileSync(license, 'Test font license')
    await init({ name: 'Font App', packageName: 'com.craft.native', output, runtimeDir: null, config: {
      renderer: 'native', nativeFonts: { 'Signature-Regular': { src: font, license } },
    } })
    const bundled = join(output, 'app/src/main/assets/NativeFonts')
    const activity = readFileSync(join(output, 'app/src/main/java/com/craft/native/MainActivity.kt'), 'utf8')
    expect(activity).toContain('Typeface.createFromAsset(assets, "NativeFonts/$filename")')
    expect(activity).toContain('bundledFonts[name]')
    expect([...readFileSync(join(bundled, 'Signature-Regular.ttf'))]).toEqual([0, 1, 0, 0, 7, 8])
    expect(readFileSync(join(bundled, 'Signature-Regular.LICENSE.txt'), 'utf8')).toBe('Test font license')
    expect(() => syncNativeFonts({ Signature: { src: join(bundled, 'Signature-Regular.ttf') } }, output)).toThrow('sources must be outside')
    expect(existsSync(join(bundled, 'Signature-Regular.ttf'))).toBe(true)
    expect(() => syncNativeFonts({ Signature: { src: font }, signature: { src: font } }, output)).toThrow('Duplicate native font')
    syncNativeFonts({}, output)
    expect(existsSync(bundled)).toBe(false)
    expect(() => syncNativeFonts({ '../escape': { src: font } }, output)).toThrow('Invalid native font')
    expect(() => syncNativeFonts({ Missing: { src: join(root, 'missing.ttf') } }, output)).toThrow('existing TTF or OTF')
    expect(() => syncNativeFonts({ Signature: { src: font, license: join(root, 'missing-license') } }, output)).toThrow('license not found')
  })

  it('packages a compiled STX bundle only for native projects', async () => {
    const root = createTempDir('craft-android-native-bundle-')
    try {
      const native = join(root, 'native')
      const web = join(root, 'web')
      const bundle = join(root, 'screen.js')
      writeFileSync(bundle, 'globalThis.__stxNativeRoute = "home";')
      await init({ name: 'Native', output: native, runtimeDir: null, config: { renderer: 'native' } })
      await init({ name: 'Web', output: web, runtimeDir: null })

      expect(JSON.parse(readFileSync(join(native, 'craft.config.json'), 'utf8')).renderer).toBe('native')
      expect(JSON.parse(readFileSync(join(web, 'craft.config.json'), 'utf8')).renderer).toBe('web')
      const nativeActivity = readFileSync(join(native, 'app/src/main/java/com/craft/native/MainActivity.kt'), 'utf8')
      const nativeCapabilities = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeCapabilities.kt'), 'utf8')
      const notificationReceiver = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeNotificationReceiver.kt'), 'utf8')
      const nativeLayout = readFileSync(join(native, 'app/src/main/res/layout/activity_main.xml'), 'utf8')
      expect(nativeActivity).toContain('class MainActivity : AppCompatActivity()')
      expect(nativeActivity).toContain('JavaScriptSandbox.isSupported()')
      expect(nativeActivity).toContain('createMessageChannel')
      expect(nativeActivity).toContain('Native STX requires Android JavaScriptSandbox, which is unavailable on this device.')
      expect(nativeActivity).toContain('JS_FEATURE_MESSAGE_PORTS')
      expect(nativeActivity).toContain('JS_FEATURE_PROMISE_RETURN')
      expect(nativeActivity).toContain('JS_FEATURE_CONSOLE_MESSAGING')
      expect(nativeActivity).toContain('Native STX bridge:')
      expect(nativeActivity).toContain('CraftNativeSandbox.connect(applicationContext)')
      expect(readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeBackground.kt'), 'utf8')).toContain('internal object CraftNativeSandbox')
      expect(nativeActivity).not.toContain('sandbox?.close()')
      expect(nativeActivity).toContain('receiveSafely(current, message.string)')
      expect(nativeActivity).toContain('Native STX message failed for $route')
      expect(nativeActivity).toContain('mutationProtocolVersion: 1')
      expect(nativeActivity).toContain('globalThis.__stxNativeUnmount && globalThis.__stxNativeUnmount()')
      expect(nativeActivity).toContain("platform: 'android'")
      expect(nativeActivity).toContain('capabilityProtocolVersion: $CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION')
      expect(nativeActivity).toContain('capabilityTimeoutMs: $CRAFT_NATIVE_CAPABILITY_TIMEOUT_MS')
      expect(nativeActivity).toContain('private fun performView(')
      expect(nativeActivity).toContain('put("viewFocus")')
      expect(nativeActivity).toContain('put("viewMeasure")')
      expect(nativeActivity).toContain('"VIEW_NOT_MOUNTED"')
      expect(nativeActivity).toContain('.put("code", "TIMEOUT")')
      expect(nativeActivity).toContain('screen.capabilityTimeouts.remove(token)?.let(capabilityHandler::removeCallbacks)')
      expect(nativeActivity).toContain('initialAppState: ${JSONObject.quote(nativeAppState)}')
      expect(nativeActivity).toContain('send(activeScreen, "DEEP_LINK", deepLinkData(launchLink).put("initial", true))')
      expect(nativeActivity).toContain('initialDeepLink = savedInstanceState?.getString("craft.initialDeepLink")?.let(Uri::parse) ?: intent?.data')
      const chrome = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeShell.kt'), 'utf8')
      expect(chrome).toContain('options.optJSONArray("leftButtons")')
      expect(chrome).toContain('leadingButtons.addView(navButton(button))')
      expect(chrome).toContain('button.optString("variant") == "neutral"')
      expect(nativeActivity).toContain('internal fun consumeInitialDeepLink(): Uri?')
      expect(nativeActivity).toContain('outState.putBoolean("craft.initialDeepLinkClaimed", initialDeepLinkClaimed)')
      expect(nativeCapabilities).toContain('internal const val CRAFT_NATIVE_CAPABILITY_PROTOCOL_VERSION = 1')
      expect(nativeCapabilities).toContain('"Storage" -> mainHandler.post {')
      expect(nativeCapabilities).toContain('val answer = runCatching { storage(method, args) }')
      expect(nativeCapabilities).toContain('"Database" -> {')
      expect(nativeCapabilities).toContain('"Notifications" -> notifications(requestToken, method, args, completion)')
      expect(nativeCapabilities).toContain('listOf("device", "clipboard", "haptics", "storage", "lifecycle", "fetch", "files")')
      expect(nativeCapabilities).toContain('"Network" -> {')
      expect(nativeCapabilities).toContain('CRAFT_NATIVE_FETCH_MAX_RESPONSE_BYTES')
      expect(nativeCapabilities).toContain('fetchConnections.remove(requestToken)?.disconnect()')
      expect(nativeCapabilities).toContain('fetch body must be a string')
      expect(nativeCapabilities).toContain('A GET or HEAD request cannot have a body')
      expect(nativeCapabilities).toContain('fetch header values must be strings')
      expect(nativeCapabilities).toContain('private fun files(requestToken: String, method: String, args: JSONArray): CraftNativeCapabilityResult {')
      expect(nativeCapabilities).not.toContain('private fun files(requestToken: String, method: String, args: JSONArray): CraftNativeCapabilityResult = when')
      expect(nativeCapabilities).toContain('"SecureStorage" -> {')
      expect(nativeCapabilities).toContain('"Biometrics" -> biometrics(requestToken, method, args, completion)')
      expect(nativeCapabilities).toContain('EncryptedSharedPreferences.create(')
      expect(nativeCapabilities).toContain('private val encryptedSecureStorage by lazy')
      expect(nativeCapabilities).toContain('BiometricPrompt.AuthenticationCallback()')
      expect(nativeCapabilities).toContain('val key = validKey(args.opt(0)) ?: return failure')
      expect(nativeCapabilities).not.toContain('CraftNative.secure')
      expect(nativeCapabilities).toContain('alarm.setAndAllowWhileIdle(')
      expect(nativeCapabilities).toContain('private fun jsonString(value: Any?): String?')
      expect(nativeCapabilities).toContain('emptyArray<String>(), "")')
      expect(nativeCapabilities).toContain('activity?.let { host -> host.consumeInitialDeepLink()?.let(host::deepLinkData) }')
      // A background refresh has no activity: the capabilities take a Context.
      expect(nativeCapabilities).toContain('private val activity: MainActivity? get() = context as? MainActivity')
      expect(notificationReceiver).toContain('internal class CraftNativeNotificationReceiver : BroadcastReceiver()')
      expect(notificationReceiver).toContain('manager.notify(id, 0, notification)')
      expect(readFileSync(join(native, 'app/src/main/AndroidManifest.xml'), 'utf8'))
        .toContain('<receiver android:name=".CraftNativeNotificationReceiver" android:exported="false" />')
      expect(readFileSync(join(web, 'app/src/main/AndroidManifest.xml'), 'utf8'))
        .not.toContain('CraftNativeNotificationReceiver')
      expect(nativeActivity).toContain('"MUTATE" -> try')
      expect(nativeActivity).toContain('screen.mutations.apply(payload)')
      expect(nativeActivity).toContain('A reused View may still carry a')
      expect(nativeActivity).toContain('val requestedChecked = props.opt("checked")')
      expect(nativeActivity).toContain('else if (requestedChecked is Boolean)')
      expect(nativeActivity).toContain('val checkboxChecked = props.opt("checked")')
      expect(nativeActivity).toContain('checkboxValue is Boolean -> checkboxValue')
      expect(nativeActivity).toContain('val indeterminate = (props.opt("indeterminate") as? Boolean) == true')
      expect(nativeActivity).toContain('type == "Checkbox" && (props.opt("indeterminate") as? Boolean) == true')
      expect(nativeActivity).toContain('is String -> value.takeIf { it.isNotEmpty() }')
      expect(nativeActivity).toContain('is Number -> value.toDouble().takeIf { it.isFinite() }?.toString()')
      expect(nativeActivity).not.toContain('(child.layoutParams?.width ?: ViewGroup.LayoutParams.WRAP_CONTENT).takeIf { it >= 0 }')
      expect(nativeActivity).not.toContain('(child.layoutParams?.height ?: ViewGroup.LayoutParams.WRAP_CONTENT).takeIf { it >= 0 }')
      const mutation = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeMutation.kt'), 'utf8')
      const flatList = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeFlatList.kt'), 'utf8')
      const refreshableFlatList = readFileSync(join(native, 'app/src/main/java/com/craft/native/CraftNativeRefreshableFlatList.kt'), 'utf8')
      expect(mutation).toContain('class CraftNativeMutationDocument')
      expect(mutation).toContain('"moveChild" -> {')
      expect(flatList).toContain('class CraftNativeFlatList(context: Context) : RecyclerView(context)')
      expect(refreshableFlatList).toContain('class CraftNativeRefreshableFlatList(context: Context) : SwipeRefreshLayout(context)')
      expect(readFileSync(join(native, 'app/build.gradle.kts'), 'utf8')).toContain('androidx.swiperefreshlayout:swiperefreshlayout:1.1.0')
      expect(refreshableFlatList).toContain('override fun onDetachedFromWindow()')
      expect(refreshableFlatList).toContain('isRefreshing = false')
      expect(flatList).toContain('fun setKeyboardDismissMode(mode: String, dismissKeyboard: () -> Unit)')
      expect(nativeActivity).toContain('setKeyboardDismissMode(craftNativeOptionalString(props.opt("keyboardDismissMode")).orEmpty())')
      expect(nativeActivity).toContain('private val frameCallback = android.view.Choreographer.FrameCallback')
      expect(nativeActivity).toContain('android.view.Choreographer.getInstance().postFrameCallback(frameCallback)')
      expect(nativeActivity).toContain('android.view.Choreographer.getInstance().removeFrameCallback(frameCallback)')
      expect(nativeActivity).toContain('requestAnimationFrame')
      expect(flatList).toContain('renderedLayout?.height ?: LayoutParams.WRAP_CONTENT')
      expect(nativeActivity).toContain('val nestedLists = refreshableLists.map { it.list }.toSet()')
      expect(nativeActivity).toContain('released.addAll(nestedLists)')
      expect(flatList).toContain('holder.host.addView(view, hostedLayout)')
      expect(flatList).toContain('ListAdapter<Item, Holder>')
      expect(flatList).toContain('GridLayoutManager(context, columns)')
      expect(flatList).toContain('if (horizontal) LayoutParams.WRAP_CONTENT else LayoutParams.MATCH_PARENT')
      expect(flatList).toContain('updateVisibleHolderLayoutParams()')
      expect(flatList).toContain('holder.host.layoutParams = holderLayoutParams()')
      expect(flatList).toContain('dataPositions.indexOfLast')
      expect(flatList).toContain('else view.layoutParams = hostedLayout')
      expect(nativeActivity).toContain('Color.luminance(background)')
      expect(nativeActivity).toContain('ContextCompat.getColor(this, R.color.background)')
      expect(nativeActivity).toContain('WindowInsetsCompat.Type.systemBars()')
      expect(nativeActivity).toContain('WindowInsetsCompat.Type.displayCutout()')
      expect(nativeActivity).toContain('ViewCompat.requestApplyInsets(root)')
      expect(nativeActivity).toContain('rows.add(mutableListOf())')
      expect(nativeActivity).toContain('internal class CraftNativeFlexLayout(context: Context) : LinearLayout(context)')
      expect(nativeActivity).toContain('private fun craftNativeNumber(value: Any?): Double?')
      expect(nativeActivity).toContain('craftNativeNumber(style?.opt(name))')
      expect(nativeActivity).toContain('private fun craftNativeFontWeight(value: Any?): String?')
      expect(nativeActivity).toContain('Typeface.create(Typeface.create("sans-serif", Typeface.NORMAL), weight, false)')
      expect(nativeActivity).toContain('val geometry = outline(node) ?: return')
      expect(nativeActivity).toContain('craftNativeNumber(values.opt(0))')
      expect(nativeActivity).toContain('if (value == null || value == JSONObject.NULL) return null')
      expect(nativeActivity).toContain('fun number(name: String): Int?')
      expect(nativeActivity).toContain('(raw.opt(name) as? Number)?.toDouble()')
      expect(nativeActivity).not.toContain('raw.optDouble(name, Double.NaN)')
      expect(nativeActivity).toContain('style.has("backgroundColor") && !style.isNull("backgroundColor")')
      expect(nativeActivity).toContain('style.width?.resolve(base)')
      expect(nativeActivity).toContain('ViewGroup.LayoutParams.WRAP_CONTENT')
      expect(nativeActivity).toContain('gridAutoRows = CraftNativeLength.from(style.opt("gridAutoRows"), density)')
      expect(nativeActivity).toContain('gridAutoRows?.resolve(contentHeight)?.toFloat()')
      expect(nativeActivity).toContain('val gridAutoRows: CraftNativeLength?')
      expect(nativeActivity).toContain('gridAutoRows = nested?.gridAutoRows')
      expect(nativeActivity).not.toContain('if (gridAutoRows != null) return null')
      expect(nativeActivity).toContain('if (autoRowsAware) {')
      expect(nativeActivity).toContain('CraftNative.layoutTreeV4(width.toFloat(), height.toFloat(), nodeData, treeMeta)')
      expect(nativeActivity).toContain('put(base, 33, sharedLength(node.gridAutoRows, contentHeight))')
      expect(nativeActivity).toContain('maxLines = craftNativeInt(props.opt("numberOfLines"), 0).takeIf { it > 0 } ?: Int.MAX_VALUE')
      expect(nativeActivity).toContain('"middle" -> TextUtils.TruncateAt.MIDDLE')
      expect(nativeActivity).toContain('wrap = flexWrap == "wrap" || flexWrap == "wrap-reverse"')
      expect(nativeActivity).toContain('wrapReverse = flexWrap == "wrap-reverse"')
      expect(nativeActivity).toContain('it.style.flexShrink ?: defaultFlexShrink(it.view)')
      expect(nativeActivity).toContain('view is TextView && view !is Button && view !is EditText && horizontal')
      expect(nativeActivity).toContain('alignContent = craftNativeOptionalString(style.opt("alignContent")) ?: "flex-start"')
      expect(nativeActivity).toContain('alignContentCode(),')
      expect(nativeActivity).toContain('crossOffset += lineCross + crossBetween')
      expect(nativeActivity).toContain('sharedPositions?.get(line.entries.size + index)')
      expect(nativeActivity).toContain('style.position == "absolute"')
      expect(nativeActivity).toContain('style.minWidth')
      expect(nativeActivity).toContain('flexGrow')
      const craftNative = readFileSync(join(native, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')
      expect(craftNative).toContain('private external fun nativeLayoutTreeV4(')
      expect(craftNative).toContain('fun layoutTreeV4(width: Float, height: Float, nodeData: FloatArray, treeMeta: FloatArray)')
      expect(craftNative).toContain('private external fun nativeLayoutTreeV5(')
      expect(craftNative).toContain('fun layoutTreeV5(width: Float, height: Float, nodeData: FloatArray, treeMeta: FloatArray)')
      expect(nativeActivity).toContain('private fun fallbackFlexWidths(line: Line, available: Int, gap: Float): IntArray')
      expect(nativeActivity).toContain('var bounded = raw')
      expect(nativeActivity).toContain('entry.style.alignSelf ?: alignItems')
      expect(nativeActivity).toContain('alignSelf = craftNativeOptionalString(raw.opt("alignSelf"))?.takeUnless { it == "auto" }')
      expect(nativeActivity).toContain('flex?.takeIf { it > 0.0 }?.let { CraftNativeLength(points = 0) }')
      expect(nativeActivity).toContain('flex?.coerceAtLeast(0.0) ?: 0.0')
      expect(nativeActivity).toContain('View.MeasureSpec.UNSPECIFIED')
      expect(nativeActivity).toContain('fun spacing(name: String, fallback: Float): Float')
      expect(nativeActivity).toContain('pixels.isFinite() && narrowed.isFinite()')
      expect(nativeActivity).toContain('rowGap = spacing("rowGap", gap)')
      expect(nativeActivity).toContain('internal fun craftNativeFiniteFloat(style: JSONObject?, name: String, fallback: Float): Float')
      expect(nativeActivity).toContain('craftNativeFiniteFloat(style, "opacity", 1f)')
      expect(nativeActivity).toContain('screen.pressActiveOpacities[this] = craftNativeFiniteFloat(props, "activeOpacity", 0.5f)')
      expect(nativeActivity).toContain('val authoredOffset = craftNativeFiniteDouble(props, "keyboardVerticalOffset", 0.0)')
      expect(nativeActivity).toContain('val pixelOffset = (authoredOffset * density.toDouble()).takeIf { it.isFinite() } ?: 0.0')
      expect(nativeActivity).toContain('val minimum = craftNativeFiniteNumber(props, "minimumValue", 0.0)')
      expect(nativeActivity).toContain('val maximumCandidate = craftNativeFiniteNumber(props, "maximumValue", 1.0)')
      expect(nativeActivity).toContain('val requested = craftNativeFiniteNumber(props, "value", minimum)')
      expect(nativeActivity).toContain('maxLines = craftNativeInt(props.opt("numberOfLines"), 0).takeIf { it > 0 } ?: Int.MAX_VALUE')
      expect(nativeActivity).toContain('val maxLength = craftNativeInt(props.opt("maxLength"), 0)')
      expect(nativeActivity).toContain('minuteInterval = craftNativeInt(props.opt("minuteInterval"), 1)')
      expect(nativeActivity).toContain('columns = craftNativeInt(props.opt("numColumns"), 1)')
      expect(nativeActivity).toContain('map.uiSettings.isScrollGesturesEnabled = craftNativeBoolean(pendingProps.opt("scrollEnabled"), true)')
      expect(nativeActivity).toContain('craftNativeBoolean(pendingProps.opt("fitToBounds"))')
      expect(nativeActivity).toContain('val hidden = if (props.has("hidden") && !props.isNull("hidden")) craftNativeBoolean(props.opt("hidden")) else null')
      expect(nativeActivity).toContain('val correction = if (craftNativeBoolean(props.opt("autoCorrect"), true))')
      expect(nativeActivity).toContain('val width = craftNativeFiniteDouble(style, "width", Double.NaN)')
      expect(nativeActivity).toContain('dp(craftNativeFiniteDouble(style, "marginLeft", horizontal))')
      expect(nativeActivity).toContain('view.translationX += dp(craftNativeFiniteDouble(transform, key, 0.0)).toFloat()')
      expect(nativeActivity).toContain('val authoredThreshold = craftNativeNonNegativeDouble(props, "onEndReachedThreshold", threshold)')
      expect(nativeActivity).toContain('private fun dp(value: Double): Int')
      expect(nativeActivity).toContain('craftNativeFiniteDouble(style, "letterSpacing", Double.NaN)')
      expect(nativeActivity).toContain('craftNativeFiniteDouble(style, "lineHeight", Double.NaN).takeIf { it.isFinite() }')
      expect(nativeActivity).toContain('craftNativeFiniteDouble(style, "textShadowRadius", 0.0)')
      expect(nativeActivity).toContain('craftNativeFiniteFloat(style, "fontSize", 16f)')
      expect(nativeActivity).toContain('value("opacity")?.toFloatOrNull()?.takeIf { it.isFinite() } ?: 1f')
      expect(nativeActivity).toContain('value("strokeWidth")?.toFloatOrNull()?.takeIf { it.isFinite() } ?: strokeWidth')
      expect(nativeActivity).toContain('var x = craftNativeNumber(props.opt("x"))?.toFloat()?.takeIf { it.isFinite() } ?: 0f')
      expect(nativeActivity).toContain('takeIf { it.isFinite() }?.toFloat()?.coerceAtLeast(0.5f) ?: 1f')
      expect(nativeActivity).toContain('if (!milliseconds.isFinite()) return null')
      expect(nativeActivity).toContain('if (geometry.any { !it.isFinite() }) return')
      expect(nativeActivity).toContain('internal fun craftNativeNonNegativeDouble(style: JSONObject?, name: String, fallback: Double): Double')
      expect(nativeActivity).toContain('val border = craftNativeNonNegativeDouble(style, "borderWidth", 0.0)')
      expect(nativeActivity).toContain('internal fun craftNativeFiniteDouble(style: JSONObject?, name: String, fallback: Double): Double')
      expect(nativeActivity).toContain('val shadowRadius = craftNativeNonNegativeDouble(style, "shadowRadius", 0.0)')
      expect(nativeActivity).toContain('"Image" -> (previous as? ImageView')
      expect(nativeActivity).toContain('isAllCaps = false')
      expect(nativeActivity).toContain('includeFontPadding = false')
      expect(nativeActivity).toContain('is String -> TextView(this).apply {')
      expect(nativeActivity).toContain('imageJobs.remove(view)?.cancel(true)')
      expect(nativeActivity).toContain('if (imageSources[view] != requestKey) return@runOnUiThread')
      expect(nativeActivity).toContain('private fun loadsImage(uri: Uri): Boolean')
      expect(nativeActivity).toContain('host == "10.0.2.2"')
      expect(nativeActivity).toContain('host.endsWith(".localhost")')
      expect(nativeActivity).toContain('if (!loadsImage(Uri.parse(requestUri)))')
      expect(nativeActivity).toContain('current.ifBlank { view.tag?.toString() ?: "Image" }')
      expect(nativeActivity).toContain('val inputIdentities = mutableMapOf<EditText, String>()')
      expect(nativeActivity).toContain('preservingInputDrafts: Boolean = false')
      expect(nativeActivity).toContain('"cover" -> ImageView.ScaleType.CENTER_CROP')
      expect(nativeActivity).toContain('view.clearColorFilter()')
      expect(nativeActivity).toContain('"ScrollView", "SectionList" -> (previous as? CraftNativeScrollView')
      expect(nativeActivity).toContain('"sectionlist" -> "SectionList"')
      expect(nativeActivity).toContain('internal class CraftNativeScrollView(context: Context) : SwipeRefreshLayout(context)')
      expect(nativeActivity).toContain('val propRefresh = props.optJSONObject("refreshControl")')
      expect(nativeActivity).toContain('setRefreshHandler(refreshHandler, craftNativeBoolean(refreshProps.opt("refreshing"), craftNativeBoolean(props.opt("refreshing"))))')
      expect(nativeActivity).toContain('transparent = craftNativeBoolean(props.opt("transparent"))')
      expect(nativeActivity).toContain('list.setScrollEnabled(craftNativeBoolean(props.opt("scrollEnabled"), true))')
      expect(nativeActivity).toContain('"FlatList" -> (previous as? CraftNativeRefreshableFlatList')
      expect(nativeActivity).toContain('val propRefresh = props.optJSONObject("refreshControl") ?: JSONObject()')
      expect(nativeActivity).toContain('setRefreshAppearance(propRefresh, refreshTintFallback(screen))')
      expect(nativeActivity).toContain('private fun refreshTintFallback(screen: Screen): Int')
      expect(refreshableFlatList).toContain('fun setRefreshAppearance(props: JSONObject, fallback: Int)')
      expect(refreshableFlatList).toContain('runCatching { craftNativeColor(it) }.getOrNull() } ?: fallback')
      expect(nativeActivity).toContain('val wantedType = inputTypeFor(props)')
      expect(nativeActivity).toContain('val wantedIme = imeOptionsFor(props)')
      // Setting these unchanged put the caret back at the start of the field.
      expect(nativeActivity).toContain('if (inputType != wantedType) inputType = wantedType')
      expect(nativeActivity).toContain('screen.inputEchoes')
      expect(nativeActivity).toContain('val autofillHint = autofillHintFor(props)')
      expect(nativeActivity).toContain('if (autofillHint == null) setAutofillHints(*emptyArray()) else setAutofillHints(autofillHint)')
      expect(nativeActivity).toContain('"numeric", "number-pad" -> InputType.TYPE_CLASS_NUMBER')
      expect(nativeActivity).toContain('"web-search" -> base or InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT')
      expect(nativeActivity).toContain('"visible-password" -> base or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD')
      expect(nativeActivity).toContain('"givenname", "firstname" -> "personGivenName"')
      expect(nativeActivity).toContain('"creditcardnumber", "ccnumber" -> "creditCardNumber"')
      expect(nativeActivity).toContain('"join", "route", "emergency-call" -> EditorInfo.IME_ACTION_GO')
      expect(nativeActivity).toContain('"continue" -> EditorInfo.IME_ACTION_NEXT')
      expect(nativeActivity).toContain('screen.suppressedTextChanges.add(this)')
      expect(nativeActivity).toContain('if (screen.suppressedTextChanges.remove(this@apply)) return')
      expect(nativeActivity).toContain('val wantedLines = if (multiline)')
      expect(nativeActivity).toContain('numberOfLines')
      expect(nativeActivity).toContain('InputFilter.LengthFilter(maxLength)')
      expect(nativeActivity).toContain('placeholderTextColor')
      expect(nativeActivity).toContain('selectionColor')
      expect(nativeActivity).toContain('"ActivityIndicator" ->')
      expect(nativeActivity).toContain('private var preparedPlayer: MediaPlayer? = null')
      expect(nativeActivity).toContain('MediaPlayer.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING')
      expect(nativeActivity).toContain('private fun craftNativeResizeMode(style: JSONObject, props: JSONObject): String')
      expect(nativeActivity).toContain('private fun craftNativeEventName(events: JSONObject, vararg names: String): String')
      expect(nativeActivity).toContain('?.takeUnless { it == "null" || it == "undefined" }')
      expect(nativeActivity).toContain('return craftNativeOptionalString(style.opt("resizeMode"))')
      expect(nativeActivity).toContain('val label = craftNativeOptionalString(props.opt("accessibilityLabel"))')
      expect(nativeActivity).toContain('val hidden = if (props.has("hidden") && !props.isNull("hidden")) craftNativeBoolean(props.opt("hidden")) else null')
      expect(nativeActivity).toContain('view.tooltipText = craftNativeOptionalString(props.opt("accessibilityHint"))')
      expect(nativeActivity).toContain('private fun imageUri(source: Any?): String')
      expect(nativeActivity).toContain('craftNativeOptionalString(source.opt("uri"))')
      expect(nativeActivity).toContain('is JSONObject -> craftNativeOptionalString(source.opt("uri")).orEmpty()')
      expect(nativeActivity).toContain('val id = craftNativeOptionalString(props.opt("id"))')
      expect(nativeActivity).toContain('?: craftNativeOptionalString(child.opt("id"))')
      expect(nativeActivity).toContain('listOf(events.opt("onPress"), events.opt("onMarkerPress"))')
      expect(nativeActivity).toContain('val symbol = craftNativeOptionalString(props.opt("symbol"))')
      expect(nativeActivity).toContain('resizeMode = craftNativeResizeMode(style, props)')
      expect(nativeActivity).toContain('indeterminateTintList')
      expect(nativeActivity).toContain('isIndeterminate = animating')
      expect(nativeActivity).toContain('hidesWhenStopped')
      expect(nativeActivity).toContain('isEnabled = !craftNativeBoolean(props.opt("disabled"))')
      expect(nativeActivity).toContain('"Slider" -> (previous as? SeekBar ?: SeekBar(this))')
      expect(nativeActivity).toContain('ceil((maximum - minimum) / it).toLong()')
      expect(nativeActivity).toContain('.coerceIn(1L, Int.MAX_VALUE.toLong())')
      expect(nativeActivity).toContain('onSlidingComplete')
      expect(nativeActivity).toContain('setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener')
      expect(nativeActivity).toContain('JSONObject().put("value", value)')
      expect(nativeActivity).toContain('ViewTreeObserver.OnPreDrawListener')
      expect(nativeActivity).toContain('private fun invalidateMeasurements()')
      expect(nativeActivity).toContain('memos.clear()')
      expect(nativeActivity).toContain('lastProbe.clear()')
      expect(nativeActivity).toContain('fun invalidateMeasurementAncestors(start: ViewParent?)')
      expect(nativeActivity).toContain('is CraftNativeKeyboardAvoidingView -> ancestor.content.invalidateMeasurements()')
      expect(nativeActivity).toContain('is CraftNativeScrollView -> ancestor.invalidateContentLayout()')
      expect(nativeActivity).toContain('invalidateMeasurementAncestors(parent)')
      expect(nativeActivity).toContain('override fun onViewAdded(child: View)')
      expect(nativeActivity).toContain('val parentBeforeRemoval = parent')
      expect(nativeActivity).toContain('observer.removeOnPreDrawListener(this)')
      expect(nativeActivity).toContain('observer.addOnPreDrawListener(listener)')
      expect(nativeActivity).toContain('screen.view.postOnAnimation { if (screen.active) emitLayoutEvents(screen) }')
      expect(nativeActivity).toContain('screen.view.forceLayout()')
      expect(nativeActivity).toContain('MeasureSpec.makeMeasureSpec(intrinsicSpec, View.MeasureSpec.AT_MOST)')
      expect(nativeActivity).toContain('longest-word (min-content) width')
      expect(nativeActivity).toContain('view.forceLayout()\n        view.requestLayout()\n        while (parent != null)')
      expect(nativeActivity).toContain('parent.forceLayout()')
      expect(nativeActivity).toContain('(parent as? View)?.let')
      expect(nativeActivity).toContain('is CraftNativeScrollView')
      expect(nativeActivity).toContain('View.OnLayoutChangeListener')
      expect(nativeActivity).toContain('view.addOnLayoutChangeListener(listener)')
      expect(nativeActivity).toContain('view.removeOnLayoutChangeListener(listener)')
      expect(nativeActivity).toContain('released.filterIsInstance<CraftNativeMapView>().forEach { it.destroy() }')
      expect(nativeActivity).toContain('onMarkerTap?.invoke(id)\n            // The native contract dispatches the marker event itself.')
      expect(nativeActivity).toContain('nextMarkers[id] = point to (props.opt("title") as? String)')
      expect(nativeActivity).toContain('if (fitToBounds()) initialCameraKey = key')
      expect(nativeActivity).toContain('override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int)')
      expect(nativeActivity).toContain('craftNativeBoolean(pendingProps.opt("fitToBounds")) && initialCameraKey == null')
      expect(nativeActivity).toContain('fun setStickyHeaderIndices(value: JSONArray?)')
      expect(nativeActivity).toContain('fun setScrollTarget(value: Any?)')
      expect(nativeActivity).toContain('private fun updateStickyHeaders()')
      expect(nativeActivity).toContain('private fun scrollToPendingTarget(attempt: Int)')
      expect(nativeActivity).toContain('            true\n        }')
      expect(nativeActivity).toContain('private var lifecycleStarted = false')
      expect(nativeActivity).toContain('mapView.onDestroy()')
      expect(nativeActivity).toContain('if (destroyed) return\n        googleMap = map')
      expect(nativeActivity).toContain('fun lowMemory()')
      expect(nativeActivity).toContain('override fun onLowMemory()')
      expect(nativeActivity).toContain('mapViews().forEach { it.lowMemory() }')
      expect(nativeActivity).toContain('drawNodes(canvas, drawing.optJSONArray("children") ?: JSONArray(), SvgPaint().merge(drawing))')
      expect(nativeActivity).toContain('val strokeDasharray: List<Float> = emptyList()')
      expect(nativeActivity).toContain('DashPathEffect(pattern, style.strokeDashoffset)')
      // A chart stretched to its box keeps its strokes' width.
      expect(nativeActivity).toContain('optString("preserveAspectRatio")?.trim() == "none"')
      expect(nativeActivity).toContain('style.vectorEffect == "non-scaling-stroke"')
      expect(nativeActivity).toContain('import android.graphics.Matrix')
      expect(nativeActivity).toContain('val pattern: FloatArray')
      expect(nativeActivity).toContain('control.onLayoutChanged = { if (screen.active) emitLayoutEvents(screen) }')
      expect(nativeActivity).toContain('released.filterIsInstance<CraftNativeFlexLayout>().forEach { it.onLayoutChanged = null }')
      expect(nativeActivity).toContain('"Picker" -> (previous as? Spinner ?: Spinner(this)).apply')
      expect(nativeActivity).toContain('private class CraftNativeDatePickerView(context: Context) : FrameLayout(context)')
      expect(nativeActivity).toContain('private var defaultDateBounds: Pair<Long, Long>? = null')
      expect(nativeActivity).toContain('defaultDateBounds = picker.minDate to picker.maxDate')
      expect(nativeActivity).toContain('datePicker?.minDate = pickerDate(props.opt("minimumDate"))?.timeInMillis ?: defaults?.first')
      expect(nativeActivity).toContain('datePicker?.maxDate = pickerDate(props.opt("maximumDate"))?.timeInMillis ?: defaults?.second')
      expect(nativeActivity).toContain('"DatePicker" -> (previous as? CraftNativeDatePickerView ?: CraftNativeDatePickerView(this)).apply')
      // A date-only picker has no TimePicker; its change must still reach the screen.
      expect(nativeActivity).not.toContain('val picker = timePicker ?: return')
      expect(nativeActivity).toContain('SimpleDateFormat("yyyy-MM-dd\'T\'HH:mm:ss.SSSXXX", Locale.US)')
      expect(nativeActivity).toContain('"yyyy-MM-dd\'T\'HH:mm:ss.SSS",')
      expect(nativeActivity).toContain('JSONObject().put("value", value).put("iso", iso).put("timestamp", current.timeInMillis)')
      expect(nativeActivity).toContain('"datepicker", "date-picker", "date" -> "DatePicker"')
      expect(nativeActivity).toContain('setOnCheckedChangeListener { _, checked ->')
      expect(nativeActivity).toContain('JSONObject().put("value", checked)')
      expect(nativeActivity).toContain('private class CraftNativeModalView(context: Context) : FrameLayout(context)')
      expect(nativeActivity).toContain('if (event.action == MotionEvent.ACTION_UP) requestClose(reason = "backdrop")')
      expect(nativeActivity).toContain('setSelection(selected, false)')
      expect(nativeActivity).toContain('onItemSelectedListener = null')
      expect(nativeActivity).toContain('Both operations can synchronously dispatch an Android selection')
      expect(nativeActivity).not.toContain('if (type == "Modal" && !props.optBoolean("visible", false)) control.visibility = View.GONE')
      expect(nativeActivity).toContain('style.has("display") && craftNativeOptionalString(style.opt("display")) != "none"')
      expect(nativeActivity).toContain('if (view !is CraftNativeModalView)')
      expect(nativeActivity).toContain('craftNativeBoolean(props.opt("visible"))')
      expect(nativeActivity).toContain('val requestClose = craftNativeOptionalString(events.opt("onRequestClose")).orEmpty()')
      expect(nativeActivity).toContain('craftNativeOptionalString(events.opt("onShow"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(events.opt("onDismiss"))')
      expect(nativeActivity).toContain('val visible = if (props.has("visible") && !props.isNull("visible"))')
      expect(nativeActivity).toContain('progressTintList')
      expect(nativeActivity).toContain('roundToInt()')
      expect(nativeActivity).toContain('val requested = craftNativeFiniteNumber(props, "value", minimum)')
      expect(nativeActivity).toContain('polylines.keys.filter { nextPolylines[it] == null }.forEach')
      expect(nativeActivity).toContain('val dataMarkers = pendingProps.optJSONArray("markers")')
      expect(nativeActivity).toContain('val dataPolylines = pendingProps.optJSONArray("polylines")')
      expect(nativeActivity).toContain('val point = coordinates(overlay.optJSONArray("geometry")).firstOrNull()')
      expect(nativeActivity).toContain('polyline.points = value.first')
      expect(nativeActivity).toContain('polyline.color = value.second')
      expect(nativeActivity).toContain('polyline.width = value.third')
      expect(nativeActivity).toContain('val rawWidth = props.opt("strokeWidth")')
      expect(nativeActivity).toContain('color(craftNativeOptionalString(props.opt("strokeColor")).orEmpty())')
      expect(nativeActivity).toContain('if (!authoredWidth.isFinite() || !width.isFinite() || width <= 0f) continue')
      expect(nativeActivity).toContain('val value = (if (step != null) minimum + ((requested - minimum) / step).roundToInt() * step else requested)')
      expect(nativeActivity).toContain('progress = if (step != null)')
      expect(nativeActivity).toContain('((value - minimum) / step).roundToInt().coerceIn(0, max)')
      expect(nativeActivity).toContain('trackTintList = if ((falseRaw != null && falseColor == null) || (trueRaw != null && trueColor == null))')
      expect(nativeActivity).toContain('trackTintList = tint?.let')
      expect(nativeActivity).toContain('val tint = craftNativeOptionalString(props.opt("tintColor"))')
      expect(nativeActivity).toContain('val background = craftNativeOptionalString(props.opt("progressBackgroundColor"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(props.opt("thumbColor"))')
      expect(nativeActivity).toContain('?.let { runCatching { craftNativeColor(it) }.getOrNull() }')
      expect(nativeActivity).toContain('craftNativeOptionalString(props.opt("minimumTrackTintColor"))')
      expect(nativeActivity).toContain('progressTintList = craftNativeOptionalString(props.opt("minimumTrackTintColor"))')
      expect(nativeActivity).toContain('progressBackgroundTintList = craftNativeOptionalString(props.opt("maximumTrackTintColor"))')
      expect(nativeActivity).toContain('thumbTintList = craftNativeOptionalString(props.opt("thumbTintColor"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(props.opt("color"))')
      expect(nativeActivity).toContain('indeterminateTintList = (craftNativeOptionalString(props.opt("color")) ?: craftNativeOptionalString(style.opt("color")))')
      expect(nativeActivity).toContain('inputHintDefaults.getOrPut(this)')
      expect(nativeActivity).toContain('inputHighlightDefaults.getOrPut(this)')
      expect(nativeActivity).toContain('setHintTextColor(')
      expect(nativeActivity).toContain('inputHintDefaults.remove(it)')
      expect(nativeActivity).toContain('screen.suppressedTextChanges.remove(it)')
      expect(nativeActivity).toContain('if (defaultBackgrounds.containsKey(view))')
      expect(nativeActivity).toContain('} else view.background = if (view is EditText && style.has("borderWidth")) {')
      expect(nativeActivity).toContain('released.forEach(defaultBackgrounds::remove)')
      expect(nativeActivity).toContain('val cellWidth = columnWidths.maxOrNull() ?: 0')
      expect(nativeActivity).toContain('cellWidth * columns')
      expect(nativeActivity).toContain('override fun onConfigurationChanged(newConfig: Configuration)')
      expect(nativeActivity).toContain('screen.mutations.document()?.let { renderCommitted(screen, it) }')
      expect(nativeActivity).toContain('private fun refreshInputDefaultsForTraitChange()')
      expect(nativeActivity).toContain('val probe = EditText(this)')
      expect(nativeActivity).toContain('if (screen.active) send(screen, "APPEARANCE", appearance)')
      // stx applies sm:/md:/lg: classes for the window's width in dp, at launch and on every change.
      expect(nativeActivity).toContain('viewportWidth: ${resources.configuration.screenWidthDp},')
      expect(nativeActivity).toContain('publishViewport(newConfig)')
      expect(nativeActivity).toContain('allScreens().forEach { screen -> if (!screen.headless) send(screen, "VIEWPORT", payload) }')
      expect(nativeActivity).toContain('private fun appearance(): JSONObject')
      expect(nativeActivity).toContain('.put("fontScale", (scale * 1000).roundToInt() / 1000.0)')
      expect(nativeActivity).toContain('import android.animation.ValueAnimator')
      expect(nativeActivity).toContain('.put("reduceMotion", !ValueAnimator.areAnimatorsEnabled())')
      expect(nativeActivity).toContain('private val animationScaleObserver = object : ContentObserver')
      expect(nativeActivity).toContain('Settings.Global.ANIMATOR_DURATION_SCALE')
      expect(nativeActivity).toContain('contentResolver.unregisterContentObserver(animationScaleObserver)')
      expect(nativeActivity).toContain('Configuration.UI_MODE_NIGHT_MASK')
      expect(nativeActivity).toContain('colorScheme: ${JSONObject.quote(colorScheme())}')
      expect(readFileSync(join(native, 'app/src/main/AndroidManifest.xml'), 'utf8'))
        .toContain('screenLayout|keyboardHidden|uiMode|fontScale')
      expect(nativeActivity).toContain('imageLoadStartHandlers')
      expect(nativeActivity).toContain('imageLoadEndHandlers')
      expect(nativeActivity).toContain('emitImageEvent')
      expect(nativeActivity).toContain('setOnEditorActionListener')
      expect(nativeActivity).toContain('screen.submitHandlers')
      expect(nativeActivity).toContain('showSoftInput')
      expect(nativeActivity).toContain('if (craftNativeBoolean(props.opt("autoFocus")) && !isFocused) post')
      expect(nativeActivity).toContain('if (!isFocused) {\n                        requestFocus()')
      expect(nativeActivity).toContain('isNestedScrollingEnabled = true')
      expect(nativeActivity).toContain('setNativeNestedScrollingEnabled(true)')
      expect(nativeActivity).toContain('setOnScrollChangeListener')
      expect(nativeActivity).toContain('if (horizontalMode != true) updateStickyHeaders()')
      expect(nativeActivity).toContain('setScrollListeners')
      expect(nativeActivity).toContain('list.onScrollEvent = craftNativeEventName(events, "onScroll")')
      expect(nativeActivity).toContain('list.onScrollBeginDrag = craftNativeEventName(events, "onScrollBeginDrag")')
      expect(nativeActivity).toContain('list.onScrollEndDrag = craftNativeEventName(events, "onScrollEndDrag")')
      expect(nativeActivity).toContain('list.onMomentumScrollBegin = craftNativeEventName(events, "onMomentumScrollBegin")')
      expect(nativeActivity).toContain('list.onMomentumScrollEnd = craftNativeEventName(events, "onMomentumScrollEnd")')
      expect(nativeActivity).toContain('flatListScrollEvent(list)')
      expect(nativeActivity).toContain('keyboardDismissMode: String')
      expect(nativeActivity).toContain('keyboardDismissMode in setOf("on-drag", "interactive")')
      expect(nativeActivity).toContain('hideSoftInputFromWindow(nativeScroll.windowToken, 0)')
      expect(nativeActivity).toContain('scrollBeginHandlers')
      expect(nativeActivity).toContain('ACTION_DOWN')
      expect(nativeActivity).toContain('scrollEndHandlers')
      expect(nativeActivity).toContain('layoutMeasurement')
      expect(nativeActivity).toContain('nativeScroll.height))))')
      expect(nativeActivity).toContain('screen.scrollHandlers')
      expect(nativeActivity).toContain('contentOffset')
      expect(nativeActivity).toContain('craftNativeEventName(events, "onLayout")')
      expect(nativeActivity).toContain('emitLayoutEvents(activeScreen)')
      expect(nativeActivity).toContain('lastLayoutBounds[view] != bounds')
      expect(nativeActivity).toContain('.put("layout", JSONObject()')
      expect(nativeActivity).toContain('left.toDouble() / density.toDouble()')
      expect(nativeActivity).toContain('info.isChecked')
      expect(nativeActivity).toContain('info.isSelected')
      expect(nativeActivity).toContain('info.isEnabled = host.isEnabled && !disabled')
      expect(nativeActivity).toContain('info.roleDescription')
      expect(nativeActivity).toContain('if (host.tooltipText != null) info.hintText = host.tooltipText')
      expect(nativeActivity).toContain('view.contentDescription = when {')
      expect(nativeActivity).toContain('?: craftNativeOptionalString(props.opt("alt"))?.takeIf { type == "Image" || type == "ImageBackground" }')
      expect(nativeActivity).toContain('else -> null')
      expect(nativeActivity).toContain('IMPORTANT_FOR_ACCESSIBILITY_NO')
      expect(nativeActivity).toContain('} else if (disabled) {\n            view.isEnabled = false')
      expect(nativeActivity).toContain('if (type !in setOf("Button", "Link", "Checkbox", "TextInput", "Picker", "SegmentedControl", "DatePicker", "Modal", "Switch", "Slider", "ActivityIndicator")) {\n            view.isEnabled = !disabled')
      expect(nativeActivity).toContain('ViewCompat.setStateDescription(')
      expect(nativeActivity).toContain('if (type == "Checkbox" && (props.opt("indeterminate") as? Boolean) == true) "mixed" else null')
      expect(nativeActivity).toContain('val checkboxColor = craftNativeOptionalString(props.opt("color"))\n                    ?: craftNativeOptionalString(style.opt("color"))')
      expect(nativeActivity).toContain('buttonTintList = checkboxColor\n                    ?.let { runCatching { craftNativeColor(it) }.getOrNull() }')
      expect(nativeActivity).not.toContain('if (state != null && state.has("disabled")) view.isEnabled = !disabled')
      expect(nativeActivity).toContain('view.tooltipText = craftNativeOptionalString(props.opt("accessibilityHint"))')
      expect(nativeActivity).toContain('val nodeViews = mutableMapOf<String, View>()')
      expect(nativeActivity).toContain('val nodePaths = mutableMapOf<String, String>()')
      expect(nativeActivity).toContain('val target = drawnTarget(screen, id) ?: return false')
      expect(nativeActivity).toContain('private fun drawnTarget(screen: Screen, id: String): String?')
      expect(nativeActivity).toContain('current = screen.mutations.parentId(current)')
      expect(nativeActivity).toContain('val path = screen.nodePaths[target] ?: return false')
      // A targeted update keeps the fontFamily its ancestors gave the subtree.
      expect(nativeActivity).toContain('makeView(screen, document, path, screen.controls, inheritedFontFamily = screen.inheritedFontFamilies[target])')
      expect(nativeActivity).toContain('val style = craftNativeInheritFontFamily(node.optJSONObject("style") ?: JSONObject(), inheritedFontFamily)')
      expect(nativeActivity).toContain('makeView(screen, node, "$path.$itemIdentity", next, previous, fontFamily)')
      expect(nativeActivity).toContain('screen.view.setChildStyle(tree, document.optJSONObject("style") ?: JSONObject(), resources.displayMetrics.density)')
      expect(nativeActivity).toContain('if (type == "SafeAreaView") setSafeAreaEdges(props.optJSONArray("edges"))\n                else setWindowSafeInsets(0, 0, 0, 0)')
      expect(nativeActivity).toContain('private fun applyViewStyle(view: View, style: JSONObject)')
      expect(nativeActivity).toContain('private fun gridIntrinsicSize(height: Int): Pair<Int, Int>')
      expect(nativeActivity).toContain('entry.height + (lp?.topMargin ?: 0) + (lp?.bottomMargin ?: 0)')
      expect(nativeActivity).toContain('val availableWidth = max(0f, layout.cellWidth - marginLeft - marginRight)')
      expect(nativeActivity).toContain('var crossLeading = 0f')
      expect(nativeActivity).toContain('private fun configureText(view: TextView, value: String, style: JSONObject)')
      expect(nativeActivity).toContain('private fun configureTextStyle(view: TextView, style: JSONObject)')
      expect(nativeActivity).toContain('val fontWeight = craftNativeFontWeight(style.opt("fontWeight"))')
      expect(nativeActivity).toContain('val controlledValue = props.opt("value") as? String')
      expect(nativeActivity).toContain('(props.opt("defaultValue") as? String)?.let(::setText)')
      expect(nativeActivity).toContain('(0 until text.length()).mapNotNull { text.opt(it) as? String }.joinToString("")')
      expect(nativeActivity).toContain('(item.opt("label") as? String)?.takeIf { it.isNotEmpty() }')
      expect(nativeActivity).toContain('(props.opt("title") as? String) ?: childText(children)')
      expect(nativeActivity).toContain('mapNotNull { it as? String }')
      expect(nativeActivity).toContain('when (props.opt("mode") as? String)')
      expect(nativeActivity).toContain('hint = (props.opt("placeholder") as? String).orEmpty()')
      expect(nativeActivity).toContain('(props.opt("placeholderTextColor") as? String)')
      expect(nativeActivity).toContain('(props.opt("selectionColor") as? String)')
      expect(nativeActivity).toContain('when (props.opt("keyboardType") as? String)')
      expect(nativeActivity).toContain('when (props.opt("autoCapitalize") as? String)')
      expect(nativeActivity).toContain('when (props.opt("returnKeyType") as? String)')
      expect(nativeActivity).toContain('(props.opt("textContentType") as? String)?.takeIf { it.isNotBlank() }')
      expect(nativeActivity).toContain('craftNativeOptionalString(props.opt("ellipsizeMode"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(props.opt("keyboardShouldPersistTaps")) ?: "never"')
      expect(nativeActivity).toContain('craftNativeOptionalString(style.opt("flexDirection")) in setOf("row", "row-reverse")')
      expect(nativeActivity).toContain('when (craftNativeOptionalString(style.opt("textTransform")))')
      expect(nativeActivity).toContain('val textAlign = craftNativeOptionalString(style.opt("textAlign"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(style.opt("fontStyle")) == "italic"')
      expect(nativeActivity).toContain('craftNativeOptionalString(style.opt("textDecorationLine")).orEmpty()')
      expect(nativeActivity).toContain('alignItems = craftNativeOptionalString(style.opt("alignItems")) ?: "stretch"')
      expect(nativeActivity).toContain('grid = craftNativeOptionalString(style.opt("display")) == "grid"')
      expect(nativeActivity).toContain('position = craftNativeOptionalString(raw.opt("position")) ?: "relative"')
      expect(nativeActivity).toContain('alignSelf = craftNativeOptionalString(raw.opt("alignSelf"))?.takeUnless { it == "auto" }')
      expect(nativeActivity).toContain('val overflow = craftNativeOptionalString(style.opt("overflow"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(style.opt("borderStyle"))')
      expect(nativeActivity).toContain('craftNativeOptionalString(style.opt("backgroundColor")).orEmpty()')
      expect(nativeActivity).toContain('configureTextStyle(this, style)')
      expect(nativeActivity).toContain('text = (props.opt("label") as? String) ?: childText(children)')
      expect(nativeActivity).toContain('configureText(this, title, style)')
      expect(nativeActivity).toContain('if (craftNativeOptionalString(style.opt("flexDirection"))?.endsWith("-reverse") == true) desired.reverse()')
      expect(nativeActivity).toContain('val flexDirection = craftNativeOptionalString(style.opt("flexDirection")).orEmpty()')
      expect(nativeActivity).toContain('Unsupported image source')
      expect(nativeActivity).toContain('"NAVIGATE_BACK" -> if (visibleScreen === screen) back()')
      expect(nativeActivity).toContain('"NAVIGATE_POP_TO_ROOT" -> if (visibleScreen === screen) popToRoot()')
      expect(nativeActivity).toContain('if (screen !== appScreen) {\n                    payload.keys().forEach')
      expect(nativeActivity).toContain('if (!current.contains(message))')
      expect(nativeActivity).toContain('joinToString(", ")')
      expect(nativeActivity).toContain('screen.controls.putAll(next)')
      expect(nativeActivity).toContain('if (childView.parent !== layout)')
      expect(nativeActivity).toContain('desired.forEach(layout::bringChildToFront)')
      expect(nativeActivity).toContain('val modal = screen.modalVisibility.entries.lastOrNull')
      expect(nativeActivity).toContain('if (!lifecycleHandler.isNullOrBlank()) {')
      expect(nativeActivity).not.toContain('consumeDismissSuppression')
      expect(nativeActivity).toContain('(modal.key as? CraftNativeModalView)?.requestClose(reason = "back")')
      expect(nativeActivity).toContain('override fun onBackPressed()')
      expect(nativeActivity).toContain('view.requestLayout()')
      expect(nativeActivity).toContain('view.post { screens.lastOrNull()?.takeIf { it.active }?.let(::emitLayoutEvents) }')
      expect(nativeActivity).not.toContain('import android.webkit.WebView')
      expect(nativeActivity).not.toContain('WebView(')
      expect(nativeLayout).toContain('native_root')
      expect(nativeLayout).not.toContain('WebView')
      expect(readFileSync(join(native, 'app/build.gradle.kts'), 'utf8'))
        .toContain('androidx.javascriptengine:javascriptengine:1.1.0')
      expect(readFileSync(join(native, 'app/build.gradle.kts'), 'utf8'))
        .toContain('com.google.android.gms:play-services-maps:18.2.0')
      expect(readFileSync(join(native, 'app/build.gradle.kts'), 'utf8'))
        .toContain('androidx.recyclerview:recyclerview:1.3.2')
      expect(readFileSync(join(web, 'app/build.gradle.kts'), 'utf8'))
        .not.toContain('androidx.javascriptengine:javascriptengine')
      expect(readFileSync(join(web, 'app/build.gradle.kts'), 'utf8'))
        .not.toContain('com.google.android.gms:play-services-maps')
      await expect(build({ output: native, compile: false, runtimeDir: null }))
        .rejects.toThrow('Native Android mode needs app/src/main/assets/native-screen.js')
      await expect(build({ output: native, nativeBundlePath: bundle, htmlPath: bundle, compile: false, runtimeDir: null }))
        .rejects.toThrow('cannot use --html-path or --dev-server')
      await expect(build({ output: web, nativeBundlePath: bundle, compile: false, runtimeDir: null }))
        .rejects.toThrow('--native-bundle requires renderer: "native"')

      await build({ output: native, nativeBundlePath: bundle, compile: false, runtimeDir: null })
      expect(readFileSync(join(native, 'app/src/main/assets/native-screen.js'), 'utf8'))
        .toBe('globalThis.__stxNativeRoute = "home";')
    }
    finally { rmSync(root, { recursive: true, force: true }) }
  })

  it('plays every iOS haptic name on native screens, through view feedback first', async () => {
    const output = createTempDir('craft-android-native-haptics-')
    await init({ name: 'NativeHaptics', packageName: 'org.example.nativehaptics', output, runtimeDir: null, config: { renderer: 'native', enableHaptics: true } })
    const dir = join(output, 'app/src/main/java/org/example/nativehaptics')
    const native = readFileSync(join(dir, 'MainActivity.kt'), 'utf8')
    expect(native).toContain('"Haptics" to "impact", "Haptics" to "notification", "Haptics" to "selection", "Haptics" to "prepare" -> if (!hapticsEnabled) {')
    expect(native).toContain('val style = CraftNativeHaptics.style(method, args.opt(0) as? String)')
    expect(native).toContain('CraftNativeHaptics.play(this, window?.decorView, style)')
    // The fixed 30 ms buzz for every style is gone.
    expect(native).not.toContain('VibrationEffect.createOneShot(30')
    const haptics = readFileSync(join(dir, 'CraftNativeHaptics.kt'), 'utf8')
    expect(haptics).toContain('package org.example.nativehaptics')
    for (const style of ['"light"', '"medium"', '"heavy"', '"soft"', '"rigid"', '"success"', '"warning"', '"error"', '"selection"'])
      expect(haptics).toContain(style)
    expect(haptics).toContain('"success" -> if (sdk >= 30) HapticFeedbackConstants.CONFIRM else null')
    expect(haptics).toContain('"error" -> if (sdk >= 30) HapticFeedbackConstants.REJECT else null')
    expect(haptics).toContain('"selection" -> if (sdk >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK')
    expect(haptics).toContain('if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return VibrationEffect.createPredefined(predefinedEffect(style))')
    expect(haptics).toContain('if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {')
    expect(haptics).toContain('return view.performHapticFeedback(constant)')

    const web = createTempDir('craft-android-web-haptics-')
    await init({ name: 'WebHaptics', packageName: 'org.example.webhaptics', output: web, runtimeDir: null, config: { enableHaptics: true } })
    expect(existsSync(join(web, 'app/src/main/java/org/example/webhaptics/CraftNativeHaptics.kt'))).toBe(false)
  })

  it('evaluates a route\'s messages ahead of it, since an isolate cannot read them when asked', async () => {
    const output = createTempDir('craft-android-native-messages-')
    await init({ name: 'NativeMessages', packageName: 'org.example.nativemessages', output, runtimeDir: null, config: { renderer: 'native' } })
    const background = readFileSync(join(output, 'app/src/main/java/org/example/nativemessages/CraftNativeBackground.kt'), 'utf8')
    expect(background).toContain('read(context, "native-screens/__messages/routes.json")')
    expect(background).toContain('return "globalThis.__stxNativeMessages={$tables};"')
    // After the runtime, before the route's own code.
    expect(background).toContain('return runtime + "\\n;\\n" + (if (messages != null) messages + "\\n;\\n" else "") + own')
  })

  it('names the session token key to every native isolate', async () => {
    const output = createTempDir('craft-android-native-session-')
    await init({ name: 'NativeSession', packageName: 'org.example.nativesession', output, runtimeDir: null, config: { renderer: 'native', enableSecureStorage: true } })
    const dir = join(output, 'app/src/main/java/org/example/nativesession')
    expect(readFileSync(join(dir, 'MainActivity.kt'), 'utf8')).toContain('sessionTokenKey: ${JSONObject.quote(CraftNativePrelude.sessionTokenKey(config))}')
    expect(readFileSync(join(dir, 'CraftNativeBackground.kt'), 'utf8')).toContain('sessionTokenKey: ${JSONObject.quote(CraftNativePrelude.sessionTokenKey(config))}')
    const shell = readFileSync(join(dir, 'CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('fun sessionTokenKey(config: JSONObject): String = config.optString("sessionTokenKey").ifBlank { "auth.token" }')
    expect(shell).toContain("emit({ type: 'SESSION_CHANGED', payload: change });")
  })

  it('keeps native route teardown and missing-bundle fallback explicit', async () => {
    const output = createTempDir('craft-android-native-lifecycle-')
    await init({ name: 'NativeLifecycle', packageName: 'org.example.nativelifecycle', output, runtimeDir: null, config: { renderer: 'native' } })

    const native = readFileSync(join(output, 'app/src/main/java/org/example/nativelifecycle/MainActivity.kt'), 'utf8')
    expect(native).toContain('showError("Missing native-screen.js. Build with --native-bundle after compiling STX.")')
    expect(native).toContain('screen.capabilityTimeouts.values.forEach(capabilityHandler::removeCallbacks)')
    expect(native).toContain('screen.pendingCapabilities.forEach(capabilities::cancel)')
    expect(native).toContain('screen.pendingSyncResults.toList().forEach')
    expect(native).toContain('screen.pendingSyncResults.clear()')
    expect(native).toContain('screen.pendingSyncResults.remove(id)')
    expect(native).toContain('screen.close {')
    expect(native).toContain('imageJobs.values.forEach { it.cancel(true) }')
    expect(native).toContain('imageExecutor.shutdownNow()')
    expect(native).toContain('capabilities.close()')
    expect(native).not.toContain('import android.webkit.WebView')
    expect(native).not.toContain('WebView(')
  })

  it('keeps launch query parameters for the initial native route', async () => {
    const output = createTempDir('craft-android-native-launch-query-')
    await init({
      name: 'NativeLaunchQuery',
      packageName: 'org.example.nativelaunchquery',
      output,
      runtimeDir: null,
      config: {
        renderer: 'native',
        devServerURL: 'https://example.com/workout?id=42',
        nativeScreens: { '/workout': 'Workout' },
      },
    })

    const shell = readFileSync(join(output, 'app/src/main/java/org/example/nativelaunchquery/CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('val query = uri.encodedQuery?.takeIf { it.isNotBlank() }?.let { "?$it" } ?: ""')
    expect(shell).toContain('(path + query).takeIf { match(it) != null }')
  })

  it('refreshes retained navigation button colors after a theme change', async () => {
    const output = createTempDir('craft-android-native-chrome-theme-')
    await init({ name: 'NativeChromeTheme', packageName: 'org.example.nativechrometheme', output, runtimeDir: null, config: { renderer: 'native' } })

    const shell = readFileSync(join(output, 'app/src/main/java/org/example/nativechrometheme/CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('navButtonSpecs.forEach { (view, spec) -> applyNavButtonTint(view, spec, dark) }')
    expect(shell).toContain('private fun applyNavButtonTint(view: TextView, button: JSONObject, dark: Boolean)')
  })

  it('floats a playing video, speaks in the best installed voice and animates a screen\'s next change', async () => {
    const output = createTempDir('craft-android-native-media-')
    await init({ name: 'NativeMedia', packageName: 'org.example.nativemedia', output, runtimeDir: null, config: { renderer: 'native' } })
    const root = join(output, 'app/src/main/java/org/example/nativemedia')
    const native = readFileSync(join(root, 'MainActivity.kt'), 'utf8')
    const services = readFileSync(join(root, 'CraftNativeServices.kt'), 'utf8')
    // Android's Sharesheet preview and mail subject both identify a shared link.
    expect(services).toContain('intent.putExtra(Intent.EXTRA_TITLE, it)')
    expect(services).toContain('intent.putExtra(Intent.EXTRA_SUBJECT, it)')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    // Picture in Picture: the activity may float, the playing video asks,
    // and its frames move to a surface of the floating window's own.
    expect(manifest).toContain('android:supportsPictureInPicture="true"')
    expect(manifest).toContain('smallestScreenSize')
      expect(native).toContain('pictureInPicture = craftNativeBoolean(props.opt("pictureInPicture"))')
    expect(native).toContain('if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.setAutoEnterEnabled(video != null)')
    expect(native).toContain('override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration)')
    expect(native).toContain('player.setDisplay(holder ?: this.holder)')
    // The video mixes with the music and tells the screen it plays and pauses.
    expect(native).toContain('setAudioFocusRequest(AudioManager.AUDIOFOCUS_NONE)')
    expect(native).toContain('fire(if (value) "onPlay" else "onPause")')
    // Speech: rate and pitch per cue around 1, quiet before it, an installed voice.
    expect(services).toContain('engine.setSpeechRate(speechNumber(options, "rate", 0.5, 2.0))')
    expect(services).toContain('engine.setPitch(speechNumber(options, "pitch", 0.5, 2.0))')
    expect(services).toContain('engine.playSilentUtterance(quietMs, queue, "$id-quiet")')
    expect(services).toContain('!voice.isNetworkConnectionRequired')
    expect(services).toContain('add("animation")')
    // craft.animation.next: framework transitions, matched by transitionID.
    expect(native).toContain('"ANIMATE_NEXT" -> if (screen !== appScreen && visibleScreen === screen) animateNextChange(screen, payload)')
    expect(native).toContain('part.setMatchOrder(Transition.MATCH_NAME, Transition.MATCH_INSTANCE)')
    expect(native).toContain('control.transitionName = craftNativeOptionalString(props.opt("transitionID"))?.takeIf { it.isNotBlank() }')
  })

  it('loads kept private images before public caches without allowing file URLs', () => {
    const native = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')
    const loader = native.slice(native.indexOf('private fun updateImage('), native.indexOf('private fun imageFailure('))
    const policy = loader.indexOf('if (!loadsImage(Uri.parse(requestUri)))')
    const kept = loader.indexOf('CraftNativeMedia.local(this, uri)')
    const cache = loader.indexOf('imageCache.read(requestUri)')
    expect(policy).toBeGreaterThanOrEqual(0)
    expect(kept).toBeGreaterThan(policy)
    expect(cache).toBeGreaterThan(kept)
    expect(loader).toContain('if (imageSources[view] != requestKey) return@runOnUiThread')
    const fixture = readFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationTest.kt'), 'utf8')
    expect(fixture).toContain('put("op", "updateNode").put("id", "kept-image")')
    expect(fixture).toContain('source updates must retain the mounted image')
    expect(fixture).toContain('active.setBoolean(screen, false)')
    expect(fixture).toContain('resumeScreenMessages?.invoke()')
  })

  it('gives native screens screen-owned audio playback with cancellation and teardown', async () => {
    const output = createTempDir('craft-android-native-audio-')
    await init({ name: 'NativeAudio', packageName: 'org.example.nativeaudio', output, runtimeDir: null, config: { renderer: 'native' } })
    const root = join(output, 'app/src/main/java/org/example/nativeaudio')
    const sounds = readFileSync(join(root, 'CraftNativeSounds.kt'), 'utf8')
    const native = readFileSync(join(root, 'MainActivity.kt'), 'utf8')
    expect(sounds).toContain('setOnPreparedListener')
    expect(sounds).toContain('setOnCompletionListener')
    expect(sounds).toContain('setOnErrorListener')
    expect(sounds).toContain('sound.player.release()')
    expect(sounds).toContain('CraftNativeMedia.local(context, text)')
    expect(sounds).toContain('AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)')
    expect(sounds).toContain('AUDIO_FOCUS_DENIED')
    expect(sounds).toContain('AUDIOFOCUS_LOSS_TRANSIENT')
    expect(sounds).toContain('AudioManager.AUDIOFOCUS_GAIN')
    expect(sounds).toContain('if (focusSuspended) return false')
    expect(sounds).toContain('private fun outputVolume(sound: Sound): Float = sound.volume * if (ducked) 0.2f else 1f')
    expect(sounds).toContain('sound.volume = value\n                applyVolume(sound)')
    expect(sounds).toContain('abandonAudioFocusRequest')
    expect(native).toContain('put("audio")')
    expect(native).toContain('screen.soundRequestCancellers[token]')
    expect(native).toContain('sounds.close()')
    expect(native).toContain('"SOUND_EVENT"')
  })

  it('gives native screens an app-owned general document picker', async () => {
    const output = createTempDir('craft-android-native-files-')
    await init({ name: 'NativeFiles', packageName: 'org.example.nativefiles', output, runtimeDir: null, config: { renderer: 'native' } })
    const root = join(output, 'app/src/main/java/org/example/nativefiles')
    const capabilities = readFileSync(join(root, 'CraftNativeCapabilities.kt'), 'utf8')
    expect(capabilities).toContain('"pickFile" -> pickFile(requestToken, args, completion)')
    const activity = readFileSync(join(root, 'MainActivity.kt'), 'utf8')
    expect(activity).toContain('capabilities.restorePickerState(savedInstanceState)')
    expect(activity).toContain('capabilities.savePickerState(outState)')
    expect(capabilities).toContain('host.finishActivity(requestCode)')
    expect(capabilities).toContain('if (pending.requestCode != requestCode) return true')
    expect(capabilities).toContain('pendingFilePick = pending.copy(requestCode = code)')
    expect(capabilities).toContain('if (pending.source == "file") JSONArray() else JSONObject.NULL')
    expect(capabilities).not.toContain('CRAFT_NATIVE_FILE_PICK_REQUEST = 4101')
    expect(capabilities).toContain('Intent.ACTION_OPEN_DOCUMENT')
    expect(capabilities).toContain('Intent.EXTRA_ALLOW_MULTIPLE')
    expect(capabilities).toContain('Intent.EXTRA_MIME_TYPES')
    expect(capabilities).toContain('copyDocuments(pending.requestToken, uris, pending.fileLimit)')
    expect(capabilities).toContain('FILE_TOO_LARGE')
    expect(capabilities).toContain('CANCELLED: File selection was cancelled')
    expect(capabilities).toContain('ownedFile(it)?.parentFile?.deleteRecursively()')
    expect(capabilities).toContain('application/vnd.garmin.tcx+xml')
    expect(capabilities).toContain('copyVideo(pending.requestToken, it, pending.videoLimit)')
    expect(capabilities).toContain('CANCELLED: Video selection was cancelled')
    expect(capabilities).toContain('copyUri(pending.requestToken, it, pending.maxPixels, pending.quality)')
    expect(capabilities).toContain('networkExecutor.execute {')
    expect(capabilities).toContain('file.parentFile?.deleteRecursively()')
  })

  it('hands native wallet passes to Google Wallet through an opt-in save URL', async () => {
    const output = createTempDir('craft-android-native-wallet-')
    await init({ name: 'Wallet', packageName: 'org.example.wallet', output, runtimeDir: null, config: { renderer: 'native', enableWallet: true } })
    const services = readFileSync(join(output, 'app/src/main/java/org/example/wallet/CraftNativeServices.kt'), 'utf8')
    const config = JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8'))

    expect(config.enableWallet).toBe(true)
    expect(services).toContain('if (config.optBoolean("enableWallet")) add("wallet")')
    expect(services).toContain('"Wallet" -> wallet(method, args, done)')
    expect(services).toContain('Android Wallet.add needs an HTTPS save URL')
    expect(services).toContain('host.startActivity(intent)')
    expect(services).toContain('Google Wallet pass lookup is not available through the save-link API')
    expect(services).toContain('PayClient.RequestType.SAVE_PASSES_JWT')
    expect(services).toContain('Pay.getClient(host).savePassesJwt(jwt, host, walletRequestCode)')
    expect(services).toContain('PayClient.SavePassesResult.SAVE_ERROR')
    expect(readFileSync(join(output, 'app', 'build.gradle.kts'), 'utf8')).toContain('com.google.android.gms:play-services-pay:16.5.0')
  })

  it('generates a DayNight background resource for native screens', async () => {
    const output = createTempDir('craft-android-dark-background-')
    await init({
      name: 'NativeDarkBackground',
      output,
      runtimeDir: null,
      config: { renderer: 'native', backgroundColor: '#f8fafc', backgroundColorDark: '#020617' },
    })
    expect(readFileSync(join(output, 'app/src/main/res/values-night/colors.xml'), 'utf8'))
      .toContain('<color name="background">#020617</color>')
    expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8')).backgroundColorDark)
      .toBe('#020617')
  })

  it('pins Android appearance like the iOS host while keeping the system mode dynamic', async () => {
    const output = createTempDir('craft-android-appearance-')
    try {
      await init({
        name: 'NativeAppearance',
        output,
        runtimeDir: null,
        config: { renderer: 'native', appearance: 'system', darkMode: false },
      })
      const config = JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8'))
      const nativeActivity = readFileSync(join(output, 'app/src/main/java/com/craft/nativeappearance/MainActivity.kt'), 'utf8')
      expect(config.appearance).toBe('system')
      expect(nativeActivity).toContain('AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM')
      expect(nativeActivity).toContain('AppCompatDelegate.MODE_NIGHT_NO')
      expect(nativeActivity).toContain('AppCompatDelegate.MODE_NIGHT_YES')
    }
    finally { rmSync(output, { recursive: true, force: true }) }
  })

  it('rejects unknown native renderers before creating a project', async () => {
    const output = join(createTempDir('craft-android-renderer-'), 'invalid')
    await expect(init({ name: 'Invalid', output, config: { renderer: 'canvas' as 'web' } }))
      .rejects.toThrow('Unknown Android renderer: canvas')
    expect(existsSync(output)).toBe(false)
  })

  it('rejects native route tables whose tabs or start path are not native', async () => {
    const root = createTempDir('craft-android-native-routes-')
    await expect(init({
      name: 'InvalidNativeRoutes',
      output: join(root, 'tab'),
      runtimeDir: null,
      config: { renderer: 'native', nativeScreens: { '/home': 'Home' }, tabs: [{ id: '/settings', title: 'Settings' }] },
    })).rejects.toThrow('Tab "/settings" is not a nativeScreens path')
    await expect(init({
      name: 'InvalidNativeStart',
      output: join(root, 'start'),
      runtimeDir: null,
      config: { renderer: 'native', devServerURL: 'https://example.com/settings', nativeScreens: { '/home': 'Home' } },
    })).rejects.toThrow('start path "/settings"')
  })

  it('keeps plus signs in generated native path parameters', async () => {
    const output = createTempDir('craft-android-native-route-encoding-')
    await init({ name: 'NativeRouteEncoding', packageName: 'org.example.nativerouteencoding', output, runtimeDir: null, config: { renderer: 'native' } })
    const shell = readFileSync(join(output, 'app/src/main/java/org/example/nativerouteencoding/CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('params.put(expected.removePrefix(":"), Uri.decode(parts[index]))')
  })

  it('keeps plus signs in generated native query keys', async () => {
    const output = createTempDir('craft-android-native-query-encoding-')
    await init({ name: 'NativeQueryEncoding', packageName: 'org.example.nativequeryencoding', output, runtimeDir: null, config: { renderer: 'native' } })
    const shell = readFileSync(join(output, 'app/src/main/java/org/example/nativequeryencoding/CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('val key = Uri.decode(pair.substringBefore(\'=\'))')
    expect(shell).toContain('decode(pair.substringAfter(\'=\', "").replace(\'+\', \' \'))')
  })

  it('applies per-screen navigation backgrounds and restores the dynamic app color', async () => {
    const output = createTempDir('craft-android-native-screen-background-')
    await init({ name: 'NativeScreenBackground', packageName: 'org.example.nativescreenbackground', output, runtimeDir: null, config: { renderer: 'native' } })
    const activity = readFileSync(join(output, 'app/src/main/java/org/example/nativescreenbackground/MainActivity.kt'), 'utf8')
    expect(activity).toContain('private fun applyScreenBackground(screen: Screen)')
    expect(activity).toContain('screen.options.opt("backgroundColor")')
    expect(activity).toContain('ContextCompat.getColor(this, R.color.background)')
    expect(activity).toContain('if (payload.has("backgroundColor")) applyScreenBackground(screen)')
  })

  it('keeps Android navigation chrome aligned with the visible screen background', async () => {
    const output = createTempDir('craft-android-native-chrome-background-')
    await init({ name: 'NativeChromeBackground', packageName: 'org.example.nativechromebackground', output, runtimeDir: null, config: { renderer: 'native' } })
    const shell = readFileSync(join(output, 'app/src/main/java/org/example/nativechromebackground/CraftNativeShell.kt'), 'utf8')
    expect(shell).toContain('private var screenBackgroundColor: Int? = null')
    expect(shell).toContain('screenBackgroundColor = options.opt("backgroundColor")')
    expect(shell).toContain('val background = screenBackgroundColor ?: ContextCompat.getColor(context, R.color.background)')
    expect(shell).toContain('largeTitleView.setBackgroundColor(background)')
    expect(shell).toContain('refreshColors()\n    }\n\n    fun selectTab')
  })

  it('rejects Android API levels below the runtime floor before writing a project', async () => {
    const root = createTempDir('craft-android-sdk-floor-')
    try {
      for (const enableHealthConnect of [false, true]) {
        const output = join(root, String(enableHealthConnect))
        await expect(init({ name: 'OldDevice', output, runtimeDir: null, config: { minSdk: 25, enableHealthConnect } }))
          .rejects.toThrow('Android minSdk must be at least 26')
        expect(existsSync(output)).toBe(false)
      }
    }
    finally { rmSync(root, { recursive: true, force: true }) }
  })

  it('keeps the default and supported Android API levels aligned across generated metadata', async () => {
    const root = createTempDir('craft-android-sdk-supported-')
    try {
      for (const minSdk of [undefined, 26, 28]) {
        const output = join(root, String(minSdk))
        await init({ name: 'SupportedDevice', output, runtimeDir: null, config: minSdk === undefined ? {} : { minSdk } })
        const expected = minSdk ?? 26
        expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).minSdk).toBe(expected)
        expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8')).minSdk).toBe(expected)
        expect(readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')).toContain(`minSdk = ${expected}`)
      }
    }
    finally { rmSync(root, { recursive: true, force: true }) }
  })

  it('selects Health Services API 30 by default and retains higher explicit minimums', async () => {
    const root = createTempDir('craft-android-health-services-sdk-')
    try {
      for (const renderer of ['native', 'web'] as const) {
        for (const minSdk of [undefined, 30, 33]) {
          const output = join(root, renderer, String(minSdk))
          await init({ name: 'HealthServicesDevice', output, runtimeDir: null, config: { renderer, enableHealthServices: true, minSdk } })
          const expected = minSdk ?? 30
          expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).minSdk).toBe(expected)
          expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8')).minSdk).toBe(expected)
          expect(readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')).toContain(`minSdk = ${expected}`)
        }
      }
    }
    finally { rmSync(root, { recursive: true, force: true }) }
  })

  it('rejects explicitly incompatible Health Services minimums before writing a project', async () => {
    const root = createTempDir('craft-android-health-services-sdk-rejected-')
    try {
      for (const minSdk of [26, 29]) {
        const output = join(root, String(minSdk))
        await expect(init({ name: 'UnsupportedHealthServicesDevice', output, runtimeDir: null, config: { enableHealthServices: true, minSdk } }))
          .rejects.toThrow('Android Health Services requires minSdk at least 30')
        expect(existsSync(output)).toBe(false)
      }
    }
    finally { rmSync(root, { recursive: true, force: true }) }
  })

  it('routes every Kotlin template through the project generator', () => {
    const templates = readdirSync(join(import.meta.dir, '../templates'))
      .filter(name => name.endsWith('.kt.template'))
    const generator = readFileSync(join(import.meta.dir, 'index.ts'), 'utf8')
      + readFileSync(join(import.meta.dir, 'native-map.ts'), 'utf8')

    for (const template of templates) expect(generator).toContain(`'${template}'`)
  })

  it('resolves every marker in a generated project', async () => {
    const output = createTempDir('craft-android-template-markers-')
    await init({ name: 'Marker Check', packageName: 'dev.craft.markers', output })

    const unresolved = generatedFiles(output).filter((path) => {
      return /\{\{[A-Z0-9_]+\}\}/.test(readFileSync(path, 'utf8'))
    })
    expect(unresolved).toEqual([])
  })

  it('renders only permissions required by enabled capabilities', () => {
    const permissions = renderAndroidPermissions({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableGeolocation: true,
      enableCamera: false,
    })

    expect(permissions).toContain('android.permission.ACCESS_FINE_LOCATION')
    expect(permissions).not.toContain('android.permission.CAMERA')
  })

  it('registers configured deep-link schemes only when enabled', () => {
    expect(renderAndroidDeepLinks({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableDeepLinks: true,
      urlSchemes: ['wildloop', 'wildloop'],
    })).toContain('android:scheme="wildloop"')
    expect(renderAndroidDeepLinks({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableDeepLinks: false,
      urlSchemes: ['wildloop'],
    })).toBe('')
  })

  it('verifies only explicit HTTPS App Link hosts, independently from custom schemes', () => {
    const config = { appName: 'HQ', packageName: 'training.hq.app', enableDeepLinks: true, urlSchemes: ['hqtraining'], appLinks: [{ host: 'hq.training' }] }
    const manifest = renderAndroidDeepLinks(config)
    expect(manifest).toContain('android:autoVerify="true"')
    expect(manifest).toContain('android:scheme="https" android:host="hq.training"')
    expect(manifest).toContain('android:scheme="hqtraining"')
    expect(renderAndroidDeepLinks({ ...config, enableDeepLinks: false })).toBe('')
    expect(renderAndroidDeepLinks({ ...config, appLinks: undefined, trustedOrigins: ['https://hq.training'] })).not.toContain('autoVerify')
    expect(() => renderAndroidDeepLinks({ ...config, appLinks: [{ host: 'hq.training" injected="true' }] })).toThrow()
  })

  it('builds HTTPS-only links and installs ordered browser exclusions in both renderers', async () => {
    const root = createTempDir('craft-app-links-')
    for (const renderer of ['native', 'web'] as const) {
      const output = join(root, renderer)
      const appLinks = [{ host: 'HQ.TRAINING', paths: [{ pattern: '/privacy', exclude: true }, { pattern: '/*' }] }]
      await init({ name: 'HQ', packageName: 'training.hq.app', output, runtimeDir: null, config: { renderer, enableDeepLinks: true, appLinks } })
      const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
      expect(config.appLinks[0].host).toBe('hq.training')
      const source = join(output, 'app/src/main/java/training/hq/app')
      expect(readFileSync(join(source, 'MainActivity.kt'), 'utf8')).toContain('CraftAppLinks.opensInBrowser(')
      const links = readFileSync(join(source, 'CraftAppLinks.kt'), 'utf8')
      expect(links).toContain('customTabsPackage != activity.packageName')
      expect(links).toContain('tab.intent.setPackage(customTabsPackage)')
      const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
      expect(gradle.match(/implementation\("androidx\.browser:browser:1\.8\.0"\)/g)).toHaveLength(1)
      expect(readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')).toContain('android:autoVerify="true"')
    }
    for (const host of ['hq.training/path', 'hq.training:443', 'user@hq.training', 'https://hq.training']) {
      await expect(init({ name: 'HQ', output: join(root, 'invalid'), runtimeDir: null, config: { appLinks: [{ host }] } })).rejects.toThrow()
    }
    await expect(init({ name: 'HQ', output: join(root, 'invalid'), runtimeDir: null, config: { appLinks: [{ host: 'hq.training', paths: [{ pattern: 'not-absolute' }] }] } })).rejects.toThrow()
  })

  it('normalizes deep links and remote origins to the runtime trust contract', async () => {
    const output = createTempDir('craft-android-network-config-')
    await init({
      name: 'Remote App',
      output,
      config: {
        devServerURL: 'https://app.example.com/nested/path',
        enableDeepLinks: true,
        trustedOrigins: ['https://cdn.example.com/path', 'https://cdn.example.com'],
        urlSchemes: [' Craft+Preview ', 'craft+preview'],
      },
    })

    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.devServerURL).toBe('https://app.example.com/nested/path')
    expect(config.trustedOrigins).toEqual(['https://cdn.example.com', 'https://app.example.com'])
    expect(config.urlSchemes).toEqual(['craft+preview'])
    expect(readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8'))
      .toContain('android:scheme="craft+preview"')
  })

  it('rejects metadata that would produce an invalid Android project', async () => {
    const output = createTempDir('craft-android-invalid-')

    await expect(init({ name: 'Bad Package', packageName: 'dev.when.app', output }))
      .rejects.toThrow('Invalid Android package name')
    await expect(init({
      name: 'Bad Color',
      output,
      config: { backgroundColor: 'transparent' },
    })).rejects.toThrow('Invalid Android background color')
    await expect(init({
      name: 'Bad SDKs',
      output,
      config: { compileSdk: 34, targetSdk: 35 },
    })).rejects.toThrow('targetSdk must not exceed compileSdk')
    await expect(init({
      name: 'Missing Deep Link',
      output,
      config: { enableDeepLinks: true },
    })).rejects.toThrow('deep links require at least one URL scheme')
    await expect(init({
      name: 'Insecure Remote',
      output,
      config: { devServerURL: 'http://example.com' },
    })).rejects.toThrow('must use HTTPS or local HTTP')
    await expect(init({
      name: 'Missing Firebase Config',
      output,
      config: { enablePushNotifications: true },
    })).rejects.toThrow('push notifications require a googleServicesFile')
    const googleServicesDirectory = join(output, 'google-services-directory')
    mkdirSync(googleServicesDirectory)
    await expect(init({
      name: 'Firebase Directory',
      output: join(output, 'firebase-directory-app'),
      config: { enablePushNotifications: true, googleServicesFile: googleServicesDirectory },
    })).rejects.toThrow('Google services file must be a file')
    const malformedGoogleServices = join(output, 'malformed-google-services.json')
    writeFileSync(malformedGoogleServices, '{')
    await expect(init({
      name: 'Malformed Firebase Config',
      packageName: 'dev.craft.malformed',
      output: join(output, 'malformed-firebase-app'),
      config: { enablePushNotifications: true, googleServicesFile: malformedGoogleServices },
    })).rejects.toThrow('Google services file must contain valid JSON')
    const mismatchedGoogleServices = join(output, 'mismatched-google-services.json')
    writeFileSync(mismatchedGoogleServices, JSON.stringify({
      client: [{ client_info: { android_client_info: { package_name: 'dev.craft.other' } } }],
    }))
    await expect(init({
      name: 'Mismatched Firebase Config',
      packageName: 'dev.craft.expected',
      output: join(output, 'mismatched-firebase-app'),
      config: { enablePushNotifications: true, googleServicesFile: mismatchedGoogleServices },
    })).rejects.toThrow('has no client for Android package dev.craft.expected')
    const unsupportedIcon = join(output, 'icon.svg')
    writeFileSync(unsupportedIcon, '<svg/>')
    await expect(init({
      name: 'Unsupported Icon',
      output: join(output, 'unsupported-icon-app'),
      config: { appIconPath: unsupportedIcon },
    })).rejects.toThrow('Unsupported Android app icon format')
    const iconDirectory = join(output, 'icon.webp')
    mkdirSync(iconDirectory)
    await expect(init({
      name: 'Icon Directory',
      output: join(output, 'icon-directory-app'),
      config: { appIconPath: iconDirectory },
    })).rejects.toThrow('App icon must be a file')
    const outputFile = join(output, 'occupied-output')
    writeFileSync(outputFile, 'not a directory')
    await expect(init({ name: 'Occupied Output', output: outputFile }))
      .rejects.toThrow('Android project output must be a directory')
  })

  it('escapes user-facing metadata without changing generator-owned identity', async () => {
    const output = createTempDir('craft-android-metadata-')
    await init({
      name: 'Rock & "Roll" $Build',
      packageName: 'dev.craft.metadata',
      output,
      config: {
        appName: 'Ignored config name',
        packageName: 'dev.ignored.package',
        version: '1.0 "preview" $build',
      },
    })

    expect(readFileSync(join(output, 'settings.gradle.kts'), 'utf8'))
      .toContain('rootProject.name = "Rock & -Roll- \\$Build"')
    expect(readFileSync(join(output, 'app/build.gradle.kts'), 'utf8'))
      .toContain('versionName = "1.0 \\"preview\\" \\$build"')
    expect(readFileSync(join(output, 'app/src/main/res/values/strings.xml'), 'utf8'))
      .toContain('Rock &amp; &quot;Roll&quot; $Build')
    expect(readFileSync(join(output, 'app/src/main/assets/index.html'), 'utf8'))
      .toContain('<h1>⚡ Rock &amp; &quot;Roll&quot; $Build</h1>')

    const generated = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(generated.appName).toBe('Rock & "Roll" $Build')
    expect(generated.packageName).toBe('dev.craft.metadata')
  })

  it('preserves a supported custom launcher icon format', async () => {
    const root = createTempDir('craft-android-icon-')
    const icon = join(root, 'launcher.webp')
    const output = join(root, 'android')
    writeFileSync(icon, 'fixture webp bytes')
    await init({ name: 'Icon App', output, config: { appIconPath: icon } })

    expect(existsSync(join(output, 'app/src/main/res/drawable/craft_app_icon.webp'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/res/drawable/craft_app_icon.png'))).toBe(false)
    expect(JSON.parse(readFileSync(
      join(output, 'app/src/main/assets/craft.config.json'),
      'utf8',
    ))).not.toHaveProperty('appIconPath')
  })

  it('emits the native holder to a fixed package, whatever the app is called', async () => {
    // The prebuilt libcraft.so binds its natives by class name in JNI_OnLoad
    // and cannot know a package chosen here. So CraftNative lives at a path
    // that does not depend on the app, and CraftBridge — which does — reaches
    // it by import. If this file ever moves under packagePath, registration
    // stops finding the class and every action silently stays on the shim.
    const output = createTempDir('craft-android-native-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const holder = join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt')
    expect(existsSync(holder)).toBe(true)

    const source = readFileSync(holder, 'utf-8')
    expect(source).toContain('package com.craft.runtime')
    // Nothing here is substituted, and an unreplaced marker would mean it was
    // routed through the templating that rewrites CraftBridge.
    expect(source).not.toContain('{{')
    expect(source).not.toContain('org.wildloop.app')

    // And the generated bridge actually reaches it.
    const bridge = readFileSync(
      join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'),
      'utf-8',
    )
    expect(bridge).toContain('import com.craft.runtime.CraftNative')
    expect(bridge).toContain('CraftNative.getDeviceInfo(activity)?.let { return it }')
  })

  it('copies a complete web distribution while preserving native configuration', async () => {
    const root = createTempDir('craft-android-assets-')
    const web = join(root, 'web')
    const output = join(root, 'android')
    Bun.spawnSync(['mkdir', '-p', join(web, 'assets')])
    writeFileSync(join(web, 'index.html'), '<main>WildLoop</main>')
    writeFileSync(join(web, 'assets', 'app.js'), 'export {}')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    syncAndroidWebAssets(web, output)

    expect(readFileSync(join(output, 'app/src/main/assets/index.html'), 'utf8')).toContain('WildLoop')
    expect(existsSync(join(output, 'app/src/main/assets/assets/app.js'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/assets/craft.config.json'))).toBe(true)
  })

  it('rejects unsafe web asset sources before replacing generated assets', async () => {
    const root = createTempDir('craft-android-asset-guard-')
    const output = join(root, 'android')
    const incompleteWeb = join(root, 'incomplete-web')
    mkdirSync(incompleteWeb)
    writeFileSync(join(incompleteWeb, 'app.js'), 'export {}')
    await init({ name: 'Asset Guard', packageName: 'dev.craft.assets', output })

    const generatedIndex = join(output, 'app/src/main/assets/index.html')
    const initialHtml = readFileSync(generatedIndex, 'utf8')
    expect(() => syncAndroidWebAssets(incompleteWeb, output))
      .toThrow('Web asset directory entry point not found')
    expect(readFileSync(generatedIndex, 'utf8')).toBe(initialHtml)

    const generatedAssets = join(output, 'app/src/main/assets')
    expect(() => syncAndroidWebAssets(generatedAssets, output))
      .toThrow('Web asset source must not overlap generated asset directory')
    expect(() => syncAndroidWebAssets(output, output))
      .toThrow('Web asset source must not overlap generated asset directory')
    expect(readFileSync(generatedIndex, 'utf8')).toBe(initialHtml)
  })

  it('generates a least-privilege bridge contract and secure manifest', async () => {
    const output = createTempDir('craft-android-project-')
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableHaptics: true, enableGeolocation: true, enableDeepLinks: true, urlSchemes: ['wildloop'] },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(bridge).toContain("craft.contractVersion = '1.0.0'")
    expect(bridge).toContain('remove: function(key) { return Promise.resolve().then(function() { legacySecureStore.remove(key); }); }')
    expect(bridge).toContain('haptics: true')
    expect(bridge).toContain('camera: false')
    expect(manifest).toContain('android:allowBackup="false"')
    expect(manifest).toContain('android:usesCleartextTraffic="false"')
    expect(manifest).toContain('android:scheme="wildloop"')
    // craft.speech binds a TTS engine, which Android 11+ hides from an app
    // that has not declared it will look for one.
    expect(manifest).toContain('<action android:name="android.intent.action.TTS_SERVICE" />')
    expect(bridge).toContain('speech: true')
    expect(bridge).toContain('fun setInitialURL')
    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    expect(activity).toContain('WebViewAssetLoader')
    expect(activity).toContain('if (origin == BUNDLED_APP_ORIGIN) return true')
    expect(activity).not.toContain('uri.host == BUNDLED_APP_HOST')
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).toContain('androidx.webkit:webkit')
    expect(gradle).toContain('ignoreAssetsPattern')
    expect(gradle).not.toContain('<dir>_*')
    const proguard = readFileSync(join(output, 'app/proguard-rules.pro'), 'utf8')
    expect(proguard).toContain('android.webkit.JavascriptInterface')
    expect(proguard).toContain('-keep class com.craft.runtime.CraftNative { *; }')
    expect(proguard).toContain('com.craft.runtime.LocationRecordingService')
    expect(proguard).not.toContain('org.wildloop.app.LocationRecordingService')
  })

  it('marks bundled assets as the remote-app recovery path', async () => {
    const root = createTempDir('craft-android-fallback-')
    const web = join(root, 'web')
    const output = join(root, 'android')
    Bun.spawnSync(['mkdir', '-p', web])
    writeFileSync(join(web, 'index.html'), '<main>Available offline</main>')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })
    await build({ htmlPath: web, devServer: 'https://wildloop.org', output, compile: false })

    const config = JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8'))
    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    expect(config.hasBundledFallback).toBe(true)

    // #254: only a main-frame connectivity failure may hide the remote page
    // behind the bundled copy. TLS, authentication, and bad-response failures
    // must remain visible instead of looking like a successful offline launch.
    const failureHandler = activity.slice(
      activity.indexOf('override fun onReceivedError('),
      activity.indexOf('webView.webChromeClient = WebChromeClient()'),
    )
    expect(failureHandler).toContain('CraftLoadFailure.isUnreachable(error.errorCode)')
    expect(failureHandler).not.toContain('hasBundledFallback && !loadedBundledFallback')

    // Falling back is no longer one-way. Bound the assertion to the named
    // recovery method so the field declaration cannot make this pass alone.
    const recovery = activity.slice(
      activity.indexOf('private fun returnFromBundledFallback('),
      activity.indexOf('private fun loadContent()'),
    )
    expect(recovery).toContain('loadedBundledFallback = false')
    expect(recovery).toContain('webView.loadUrl(remoteUrl)')

    expect(activity).toContain('returnFromBundledFallback("the app returned to the foreground")')
    expect(activity).toContain('val wasConnected = isConnected')
    expect(activity).toContain('if (!wasConnected && isConnected) {')
  })

  it('delivers shortcut activations and refuses impossible event streams', async () => {
    const output = createTempDir('craft-android-shortcut-events-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    expect(activity).toContain('handleIncomingShortcut(intent)')
    expect(activity).toContain('getStringExtra(SHORTCUT_TYPE_EXTRA)')
    expect(activity).toContain('craftBridge.markBridgeLoading()')
    expect(bridge).toContain('sendEvent("craftShortcut", data)')
    expect(bridge).toContain('pendingEvents.add("craftShortcut" to data)')
    expect(bridge).not.toContain("addEventListener('craftOTAProgress'")
    expect(bridge).not.toContain("addEventListener('craftOTAStatus'")
    expect(bridge).not.toContain("addEventListener('craftARPlane'")
    expect(bridge).toContain('craft.ar.onPlaneDetected is unavailable because ARCore requires native Activity integration')
  })

  it('queues deep links until the bridge is injected, and marks only the launch link initial', async () => {
    // #215: the launch link used to go only to getInitialURL, and a warm link
    // replaced the launch link as getInitialURL's answer.
    const output = createTempDir('craft-android-deep-links-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(activity).not.toContain('dispatch = false')
    expect(activity).toContain('intent.data?.toString()?.let(craftBridge::receiveDeepLink)')
    expect(activity).toContain('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY')
    expect(activity).toContain('intent.data?.toString()?.let(craftBridge::receiveDeepLink)')
    // A recreated activity restores what the bridge saved, not getIntent(),
    // which onNewIntent may have replaced with a warm link.
    expect(activity).toContain('craftBridge.saveDeepLinks(outState)')
    expect(activity).toContain('craftBridge.restoreDeepLinks(savedInstanceState)')

    // Flushed in the injection's completion, after the page's replay exists.
    const injected = bridge.slice(bridge.indexOf('webView.evaluateJavascript(onlyOnce(script)) {'))
    const flush = injected.slice(0, injected.indexOf('fun markBridgeLoading()'))
    expect(flush.indexOf('bridgeReady = true')).toBeLessThan(flush.indexOf('links.forEach { (url, initial) -> dispatchDeepLink(url, initial) }'))

    expect(bridge).toContain('val initial = !hasBeenReady && !initialAssigned')
    expect(bridge).toContain('put("initial", initial)')
    expect(bridge).not.toContain('if (initialURL == null)')
    expect(bridge).toContain('pendingDeepLinks.clear()\n    }')
    expect(holder).toContain('private external fun nativeDispatchDeepLink(url: String, initial: Boolean): Boolean')
  })

  it('enforces the capability flags it reports, in the page and in Kotlin', async () => {
    // #209: the flags shaped the manifest and craft.capabilities, and then
    // every call was served anyway.
    const output = createTempDir('craft-android-capability-gate-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output, config: { enableShare: true } })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('installCapabilityGates')
    expect(bridge).toContain("error.code = 'CAPABILITY_DISABLED'")
    // The gate reads the object the page reads, so the two cannot disagree.
    expect(bridge).toContain('if (craft.capabilities[capability]) { return served.apply(this, arguments); }')
    // Generated from this app's config, not hardcoded.
    expect(bridge).toContain('private val shareEnabled = true')
    expect(bridge).toContain('private val hapticsEnabled = false')
    expect(bridge).toContain('if (!hapticsEnabled && disabled("haptics", "haptic")) return')
    expect(bridge).toContain('if (!keepAwakeEnabled && disabled("keepAwake", "setKeepAwake")) return false')
  })

  it('answers the page from haptic, vibrate and the speech calls', async () => {
    // #219: all four returned Unit, so the page got undefined where iOS
    // returns a promise, and a grant of RECORD_AUDIO went nowhere.
    const output = createTempDir('craft-android-feedback-answers-')
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableHaptics: true, enableSpeechRecognition: true },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const signature of [
      'fun haptic(style: String): Boolean',
      'fun vibrate(patternJson: String): Boolean',
      'fun startListening(): Boolean',
      'fun stopListening(): Boolean',
    ]) {
      expect(bridge).toContain(signature)
    }

    // The page reads that return value rather than dropping it.
    expect(bridge).toContain("return CraftAndroid.haptic(style || 'medium') === true;")
    expect(bridge).toContain('return CraftAndroid.startListening() === true;')

    // The microphone grant starts the recogniser, the way iOS starts from
    // inside its authorization callback, and a denial is not silence.
    expect(bridge).toContain('private fun beginSpeechRecognition()')
    expect(bridge).toContain('if (requestCode == REQUEST_SPEECH) {')
    expect(bridge).toContain('if (isPermissionGranted(Manifest.permission.RECORD_AUDIO)) beginSpeechRecognition()')
    expect(bridge).toContain('"Microphone permission denied"')

    // And stopping says the session ended, once, as iOS does.
    expect(bridge).toContain('sendEvent("craftSpeechEnd", emptyMap())')
  })

  it('marks ready only the page its injection ran in, and injects a document once', async () => {
    // #228, two halves. The evaluateJavascript completion is posted, so it
    // can land after the next navigation has started and mark a page that
    // was never injected as ready — flushing the deep-link and shortcut
    // queues into a document with no bridge. And onPageFinished arrives
    // without onPageStarted for a same-document navigation, so the script
    // could run twice in one document.
    const output = createTempDir('craft-android-injection-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('private var navigationGeneration = 0')
    expect(bridge).toContain('navigationGeneration += 1')
    expect(bridge).toContain('val generation = navigationGeneration')
    expect(bridge).toContain('if (generation != navigationGeneration) return@evaluateJavascript')
    // The generation is taken before the script is handed over, and compared
    // after; either order alone leaves the race open.
    expect(bridge.indexOf('val generation = navigationGeneration'))
      .toBeLessThan(bridge.indexOf('if (generation != navigationGeneration)'))

    expect(bridge).toContain('private fun onlyOnce(script: String): String')
    expect(bridge).toContain('evaluateJavascript(onlyOnce(script))')
    expect(bridge).toContain('if (!window.__craftBridgeInstalled)')
  })

  it('ignores the launch intent on a relaunch from Recents, and the saved one on a recreate', async () => {
    // #229, two halves. The shortcut path had no history check, so the
    // shortcut the app was first opened with was dispatched again every time
    // the task was reopened from Recents. And a recreated activity must read
    // what the bridge saved, not getIntent(), which onNewIntent replaces with
    // the latest warm link — that half landed with #232 and is pinned here so
    // it cannot quietly go back.
    const output = createTempDir('craft-android-recents-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output, config: { enableDeepLinks: true, urlSchemes: ['wildloop'] } })

    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    const onCreate = activity.slice(activity.indexOf('override fun onCreate'), activity.indexOf('private fun setupWebView'))

    // One flag, guarding both, rather than the link alone.
    expect(onCreate).toContain('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY')
    // The same history flag also guards App Link browser exclusions.
    expect(onCreate.match(/launchedFromHistory/g)?.length).toBe(3)
    // Bounded by the block's own closing brace: a slice that ran to the end
    // of onCreate would still find a shortcut call that had moved back out.
    const guardStart = onCreate.indexOf('if (!launchedFromHistory) {')
    const guard = onCreate.slice(guardStart, onCreate.indexOf('\n            }', guardStart))
    expect(guard).toContain('craftBridge::receiveDeepLink')
    expect(guard).toContain('handleIncomingShortcut(intent)')
    // And exactly once, so it cannot also be dispatched outside the guard.
    expect(onCreate.match(/handleIncomingShortcut\(intent\)/g)?.length).toBe(1)

    // A genuinely new intent still carries both through.
    const onNewIntent = activity.slice(activity.indexOf('override fun onNewIntent'), activity.indexOf('override fun onBackPressed'))
    expect(onNewIntent).toContain('craftBridge::receiveDeepLink')
    expect(onNewIntent).toContain('handleIncomingShortcut(intent)')

    // And a recreate reads the bundle, never the intent.
    expect(onCreate).toContain('craftBridge.restoreDeepLinks(savedInstanceState)')
    expect(activity).toContain('craftBridge.saveDeepLinks(outState)')
  })

  it('routes external Activity results back to every pending media promise', async () => {
    const output = createTempDir('craft-android-activity-results-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const request of ['REQUEST_CAMERA, REQUEST_GALLERY', 'REQUEST_FILE_PICKER', 'REQUEST_VIDEO', 'REQUEST_PICK_CONTACT']) {
      expect(bridge).toContain(request)
    }
    expect(bridge).toContain('handleImageResult(requestCode, resultCode, data)')
    expect(bridge).toContain('handleFilePickerResult(resultCode, data)')
    expect(bridge).toContain('handleVideoResult(resultCode, data)')
    expect(bridge).toContain('handleContactPickerResult(resultCode, data)')
    expect(bridge).toContain('window._craftVideoResolve && window._craftVideoResolve')
    expect(bridge).toContain('val result = "data:$mimeType;base64,$encoded"')
    expect(bridge).toContain('window._craftFileResolve && window._craftFileResolve($result)')
    expect(bridge).toContain('resolveMediaPromise(promise, "data:$mimeType;base64,$encoded")')
    expect(bridge).toContain('rejectMediaPromise(promise, "Camera returned no image")')
    expect(bridge).toContain('else -> healthConnect.onActivityResult(requestCode, resultCode, data)')
    expect(bridge).toContain('if (closed) return requestCode == REQUEST_CAMERA')
    for (const handler of ['handleImageResult', 'handleFilePickerResult', 'handleVideoResult', 'handleContactPickerResult']) {
      const start = bridge.indexOf(`fun ${handler}(`)
      const end = bridge.indexOf('\n    }', start)
      expect(bridge.slice(start, end)).toContain('if (closed) return')
    }
    expect(bridge).toContain('private fun evaluatePromiseJavascript(script: String)')
  })

  it('settles camera calls that need permission or cannot launch', async () => {
    const output = createTempDir('craft-android-camera-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun openCamera()')
    const end = bridge.indexOf('fun pickImage()', start)
    const camera = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(camera.indexOf('checkSelfPermission')).toBeLessThan(camera.indexOf('CraftNative.openCamera'))
    expect(camera).toContain('Camera permission is required; retry after granting it')
    expect(camera.indexOf('rejectMediaPromise(')).toBeLessThan(camera.indexOf('requestPermissionsBestEffort('))
    expect(camera).toContain('catch (error: Exception)')
    expect(camera).toContain('Camera could not be opened')
  })

  it('passes file filters and settles failed media launchers', async () => {
    const output = createTempDir('craft-android-media-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('require(types.all { MIME_TYPE.matches(it) })')
    expect(bridge).toContain('putExtra(Intent.EXTRA_MIME_TYPES, requestedTypes.toTypedArray())')
    expect(bridge).toContain('if (requestedTypes.isEmpty() && CraftNative.pickFile(activity)) return')
    expect(bridge).toContain('rejectFilePicker(error.message ?: "File picker could not be opened")')
    expect(bridge).toContain('Image picker could not be opened')
    expect(bridge).toContain('Video capture could not be opened')
  })

  it('exposes native Android permission checks, requests, and settings', async () => {
    const output = createTempDir('craft-android-permissions-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    const service = join(output, 'app/src/main/java/com/craft/runtime/LocationRecordingService.kt')

    expect(bridge).toContain('craft.permissions = {')
    expect(bridge).toContain('CraftAndroid.checkPermission(String(permission))')
    expect(bridge).toContain('CraftAndroid.requestPermission(String(permission), id)')
    expect(bridge.match(/ActivityCompat\.requestPermissions\(/g)?.length).toBe(2)
    expect(bridge).toContain('private fun requestPermissionsBestEffort(permissions: Array<String>, requestCode: Int)')
    expect(bridge).toContain('runCatching { ActivityCompat.requestPermissions(activity, permissions, requestCode) }')
    expect(readFileSync(join(sourceRoot, 'CraftPermissionPolicy.kt'), 'utf8')).toContain('group.any(isGranted)')
    expect(bridge).toContain('CraftPermissionPolicy.nextRequest(')
    expect(bridge).toContain('pendingPermissionRequests.remove(requestCode)')
    expect(bridge).toContain('catch (error: Exception)')
    expect(bridge).toContain('pending.groupIndex + 1')
    expect(bridge).toContain('nativePermissionStatus(pending.permission)')
    expect(bridge).toContain('CraftPermissionPolicy.foregroundLocationIsGranted(::isPermissionGranted)')
    expect(bridge.match(/if \(!hasForegroundLocationPermission\(\)\)/g)?.length).toBe(3)
    expect(bridge).toContain('if (hasForegroundLocationPermission())')
    expect(bridge).not.toContain('grantResults.all { it == PackageManager.PERMISSION_GRANTED }')
    expect(bridge).toContain('fun onRequestPermissionsResult(requestCode: Int): Boolean')
    expect(bridge).toContain('if (closed) return requestCode in PERMISSION_REQUEST_START..PERMISSION_REQUEST_END')
    const permissionDelivery = bridge.slice(
      bridge.indexOf('private fun deliverPermissionResult('),
      bridge.indexOf('@JavascriptInterface\n    fun getCurrentPosition(', bridge.indexOf('private fun deliverPermissionResult(')),
    )
    expect(permissionDelivery).toContain('if (closed) return')
    expect(permissionDelivery).toContain('if (closed) return@runOnUiThread')
    expect(bridge).toContain('Settings.ACTION_APPLICATION_DETAILS_SETTINGS')
    expect(existsSync(service)).toBe(true)
    const serviceSource = readFileSync(service, 'utf8')
    expect(serviceSource).toContain('ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)')
    expect(serviceSource).toContain('package com.craft.runtime')
    expect(serviceSource).toContain('Manifest.permission.ACCESS_COARSE_LOCATION')
    expect(activity).toContain('craftBridge.onRequestPermissionsResult(requestCode)')
  })

  it('generates a foreground service for durable background recording', async () => {
    const output = createTempDir('craft-android-location-')
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableBackgroundLocation: true },
    })

    const service = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/LocationRecordingService.kt'), 'utf8')
    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(service).toContain('START_STICKY')
    expect(service).toContain('CraftLocationRecordingStore.append')
    expect(service).toContain('else -> if (!startUpdates())')
    expect(service).toContain('.addOnFailureListener')
    expect(service).toContain('CraftLocationRecordingStore.finish(this, JSONObject().put("expectedId", id))')
    expect(service).toContain('stopSelfResult(startId)')
    expect(bridge).toContain('startRecording: function(options)')
    expect(bridge).toContain('fun stopLocationRecording()')
    expect(manifest).toContain('android:name="com.craft.runtime.LocationRecordingService"')
    expect(manifest).toContain('android:foregroundServiceType="location"')
  })

  it('keeps offline media on WorkManager, resumed, queued and stopped at sign-out', async () => {
    const output = createTempDir('craft-android-media-')
    await init({ name: 'Glyph', packageName: 'dev.craft.media', output, config: { renderer: 'native', nativeScreens: {} } })
    const shell = readFileSync(join(output, 'app/src/main/java/dev/craft/media/CraftNativeShell.kt'), 'utf8')
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).toContain('androidx.work:work-runtime-ktx')
    // Join running and fresh queued work; an explicit retry replaces failed backoff.
    expect(shell).toContain('internal class CraftNativeMediaWorker(')
    expect(shell).toContain('(it.state == androidx.work.WorkInfo.State.ENQUEUED && it.runAttemptCount == 0)')
    expect(shell).toContain('"$TAG:generation:$started" in it.tags &&')
    expect(shell).toContain('val matching = pending.filter { it.generation == started }')
    expect(shell).toContain('work.enqueueUniqueWork(name, if (pending) androidx.work.ExistingWorkPolicy.KEEP else androidx.work.ExistingWorkPolicy.REPLACE, request).result.get()')
    // A prune never stops the transfer a keep still waits on; a 206 nobody asked for is refused.
    expect(shell).toContain('owner !in active && (owner !in wanted || stale)')
    expect(shell).toContain('if (status == 416 || (status == 206 && !resumed))')
    expect(shell).toContain('return if (have > 0) Fetched.Restart else Fetched.Refused(status)')
    expect(shell).toContain('if (wifiOnly) androidx.work.NetworkType.UNMETERED else androidx.work.NetworkType.CONNECTED')
    // Resumed from the part file an earlier attempt left.
    expect(shell).toContain('connection.setRequestProperty("Range", "bytes=$have-")')
    // Answered at once when it cannot run now, in the shape iOS answers.
    expect(shell).toContain('.put("reason", reason).put("queued", true)')
    // A clear (sign-out) is persisted before the files go, and stops every job.
    expect(shell).toContain('prefs(context).edit().putInt("generation", generation(context) + 1).commit()')
    expect(shell).toContain('cancelAllWorkByTag(TAG)')
  })

  it('gives every notification a white glyph instead of the launcher icon', async () => {
    const root = createTempDir('craft-android-notification-icon-')
    const googleServicesFile = join(root, 'google-services.json')
    writeFileSync(googleServicesFile, JSON.stringify({
      client: [{ client_info: { android_client_info: { package_name: 'dev.craft.glyph' } } }],
      project_info: { project_number: '1' },
    }))
    const defaults = join(root, 'default')
    await init({ name: 'Glyph', packageName: 'dev.craft.glyph', output: defaults, config: { renderer: 'native', nativeScreens: {}, enablePushNotifications: true, googleServicesFile } })
    const drawable = join(defaults, 'app/src/main/res/drawable')
    expect(readFileSync(join(drawable, 'craft_notification_icon.xml'), 'utf8')).toContain('android:fillColor="#FFFFFFFF"')
    expect(readFileSync(join(defaults, 'app/src/main/res/values/colors.xml'), 'utf8')).toContain('<color name="craft_notification_color">#00000000</color>')
    let manifest = readFileSync(join(defaults, 'app/src/main/AndroidManifest.xml'), 'utf8')
    // A push that lands while the app is in the background is drawn by Firebase from these.
    expect(manifest).toContain('<meta-data android:name="com.google.firebase.messaging.default_notification_icon" android:resource="@drawable/craft_notification_icon" />')
    expect(manifest).not.toContain('default_notification_color')

    const builders = [
      'app/src/main/java/dev/craft/glyph/CraftNativeMessagingService.kt',
      'app/src/main/java/dev/craft/glyph/CraftNativeNotificationReceiver.kt',
      'app/src/main/java/com/craft/runtime/LocationRecordingService.kt',
    ].map(path => readFileSync(join(defaults, path), 'utf8'))
    for (const source of builders) {
      expect(source).toContain('.setSmallIcon(R.drawable.craft_notification_icon)')
      expect(source).toContain('R.color.craft_notification_color')
      expect(source).not.toMatch(/setSmallIcon\((applicationInfo\.icon|android\.R\.drawable)/)
    }
    expect(builders[2]).toContain('import dev.craft.glyph.R')
    expect(existsSync(join(defaults, 'app/src/main/java/dev/craft/glyph/CraftBridge.kt'))).toBe(false)

    const custom = join(root, 'custom')
    const vector = join(root, 'hq-notification.xml')
    writeFileSync(vector, '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp" android:viewportWidth="24" android:viewportHeight="24"><path android:fillColor="#FFFFFFFF" android:pathData="M4,4h16v16h-16z" /></vector>')
    await init({ name: 'Glyph', packageName: 'dev.craft.glyph', output: custom, config: { renderer: 'native', nativeScreens: {}, enablePushNotifications: true, googleServicesFile, notificationIconPath: vector, notificationColor: '#2F63FF' } })
    expect(readFileSync(join(custom, 'app/src/main/res/drawable/craft_notification_icon.xml'), 'utf8')).toContain('M4,4h16v16h-16z')
    expect(readFileSync(join(custom, 'app/src/main/res/values/colors.xml'), 'utf8')).toContain('<color name="craft_notification_color">#2F63FF</color>')
    manifest = readFileSync(join(custom, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(manifest).toContain('<meta-data android:name="com.google.firebase.messaging.default_notification_color" android:resource="@color/craft_notification_color" />')
    expect(JSON.parse(readFileSync(join(custom, 'app/src/main/assets/craft.config.json'), 'utf8'))).not.toHaveProperty('notificationIconPath')

    // A PNG replaces the vector rather than sitting beside it as a duplicate resource.
    const png = join(root, 'glyph.png')
    writeFileSync(png, 'fixture png bytes')
    await init({ name: 'Glyph', packageName: 'dev.craft.glyph', output: custom, config: { notificationIconPath: png } })
    expect(existsSync(join(custom, 'app/src/main/res/drawable/craft_notification_icon.png'))).toBe(true)
    expect(existsSync(join(custom, 'app/src/main/res/drawable/craft_notification_icon.xml'))).toBe(false)

    const svg = join(root, 'glyph.svg')
    writeFileSync(svg, '<svg/>')
    await expect(init({ name: 'Glyph', output: join(root, 'svg'), config: { notificationIconPath: svg } })).rejects.toThrow('Unsupported Android notification icon format: .svg')
    const notVector = join(root, 'layout.xml')
    writeFileSync(notVector, '<LinearLayout />')
    await expect(init({ name: 'Glyph', output: join(root, 'layout'), config: { notificationIconPath: notVector } })).rejects.toThrow('must be an Android vector drawable')
    await expect(init({ name: 'Glyph', output: join(root, 'colour'), config: { notificationColor: 'blue' } })).rejects.toThrow('notificationColor must be #RRGGBB')
  })

  it('uses Firebase Cloud Messaging instead of placeholder push tokens', async () => {
    const root = createTempDir('craft-android-push-')
    const output = join(root, 'android')
    const googleServicesFile = join(root, 'google-services.json')
    writeFileSync(googleServicesFile, JSON.stringify({
      client: [{
        client_info: { android_client_info: { package_name: 'org.wildloop.app' } },
      }],
      project_info: { project_number: '1' },
    }))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enablePushNotifications: true, googleServicesFile },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const appGradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    const projectGradle = readFileSync(join(output, 'build.gradle.kts'), 'utf8')
    expect(bridge).toContain('FirebaseMessaging.getInstance().token')
    expect(bridge).toContain('evaluatePromiseJavascript("$callback && $callback($payload)")')
    expect(bridge).not.toContain('push-token-placeholder')
    expect(bridge).not.toContain('?: \\"Review flow failed\\"')
    expect(appGradle).toContain('com.google.firebase:firebase-messaging')
    expect(appGradle).toContain('id("com.google.gms.google-services")')
    expect(projectGradle).toContain('id("com.google.gms.google-services")')
    expect(existsSync(join(output, 'app/google-services.json'))).toBe(true)
    expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).googleServicesFile)
      .toBe(googleServicesFile)
    expect(JSON.parse(readFileSync(
      join(output, 'app/src/main/assets/craft.config.json'),
      'utf8',
    ))).not.toHaveProperty('googleServicesFile')
  })

  it('declares the libraries used by the generated bridge', async () => {
    const output = createTempDir('craft-android-dependencies-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).toContain('androidx.fragment:fragment-ktx')
    expect(gradle).toContain('com.google.mlkit:barcode-scanning')
    expect(gradle).toContain('com.google.mlkit:image-labeling')
    expect(gradle).toContain('com.google.mlkit:object-detection')
    expect(gradle).toContain('com.google.mlkit:text-recognition')
  })

  it('guards contacts, calendar, notification, and billing promise channels', async () => {
    const output = createTempDir('craft-android-promise-data-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver] of [
      ['contacts read', '_craftContactsResolve'],
      ['contact write', '_craftAddContactResolve'],
      ['calendar read', '_craftCalendarResolve'],
      ['calendar create', '_craftCreateEventResolve'],
      ['calendar delete', '_craftDeleteEventResolve'],
      ['notification schedule', '_craftNotifResolve'],
      ['products', '_craftProductsResolve'],
      ['purchase', '_craftPurchaseResolve'],
      ['purchase restore', '_craftRestoreResolve'],
    ]) {
      expect(bridge).toContain(`window.__craftPromise('${channel}', '${resolver}',`)
      expect(bridge).not.toContain(`window.${resolver} = resolve`)
    }
  })

  it('guards file, media, database, radio, and health promise channels', async () => {
    const output = createTempDir('craft-android-promise-device-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver] of [
      ['QR scan', '_craftQRResolve'],
      ['file picker', '_craftFileResolve'],
      ['file download', '_craftDownloadResolve'],
      ['file save', '_craftSaveResolve'],
      ['Google sign in', '_craftGoogleResolve'],
      ['audio start', '_craftAudioResolve'],
      ['audio stop', '_craftAudioStopResolve'],
      ['video recording', '_craftVideoResolve'],
      ['database execute', '_craftDbExecResolve'],
      ['database query', '_craftDbQueryResolve'],
      ['Bluetooth scan', '_craftBleResolve'],
      ['NFC scan', '_craftNfcResolve'],
      ['health authorization', '_craftFitnessAuthResolve'],
      ['health read', '_craftFitnessDataResolve'],
      ['health write', '_craftFitnessSaveResolve'],
    ]) {
      expect(bridge).toContain(`window.__craftPromise('${channel}', '${resolver}',`)
      expect(bridge).not.toContain(`window.${resolver} = resolve`)
    }
  })

  it('guards lifecycle, utility, and update promise channels without ad hoc callback slots', async () => {
    const output = createTempDir('craft-android-promise-lifecycle-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver, uses] of [
      ['screenshot', '_craftScreenshotResolve', 1],
      ['background task', '_craftBgTaskResolve', 4],
      ['PDF', '_craftPDFResolve', 2],
      ['contact picker', '_craftPickContactResolve', 1],
      ['shortcuts', '_craftShortcutsResolve', 2],
      ['shared keychain', '_craftSharedKeychainResolve', 3],
      ['auth persistence', '_craftAuthPersistResolve', 4],
      ['AR', '_craftARResolve', 5],
      ['ML', '_craftMLResolve', 3],
      ['widgets', '_craftWidgetResolve', 3],
      ['watch', '_craftWatchResolve', 2],
      ['initial URL', '_craftDeepLinkResolve', 1],
      ['OTA check', '_craftOTACheckResolve', 1],
      ['OTA download', '_craftOTADownloadResolve', 1],
      ['OTA apply', '_craftOTAApplyResolve', 1],
      ['OTA rollback', '_craftOTARollbackResolve', 1],
      ['share', '_craftShareResolve', 1],
    ] as const) {
      const call = `window.__craftPromise('${channel}', '${resolver}',`
      expect(bridge.match(new RegExp(call.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'))?.length).toBe(uses)
    }
    const nativeCallbackNames = new Set(
      [...bridge.matchAll(/window\.(_craft[A-Za-z]+(?:Resolve|Reject))\b/g)]
        .map(match => match[1]),
    )
    for (const callbackName of nativeCallbackNames) {
      expect(bridge).toContain(`'${callbackName}'`)
    }
    const registrations = [...bridge.matchAll(
      /window\.__craftPromise\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'/g,
    )].map(match => [match[1], match[2], match[3]] as const)
    expect(registrations).toHaveLength(66)

    const uniqueRegistrations = new Map(
      registrations.map(registration => [registration.join('\0'), registration]),
    )
    expect(uniqueRegistrations.size).toBe(47)

    const channels = new Set<string>()
    const callbackOwners = new Map<string, string>()
    for (const [channel, resolver, rejecter] of uniqueRegistrations.values()) {
      expect(channels.has(channel)).toBe(false)
      channels.add(channel)
      expect(rejecter).toBe(resolver.replace(/Resolve$/, 'Reject'))
      for (const callback of [resolver, rejecter]) {
        expect(callbackOwners.has(callback)).toBe(false)
        callbackOwners.set(callback, channel)
      }
    }
    expect(channels.size).toBe(47)
    expect(callbackOwners.size).toBe(94)
    expect(bridge.match(/webView\.evaluateJavascript\(\s*"window\._craft[A-Za-z]+(?:Resolve|Reject)/g)).toBeNull()
    expect(bridge.match(/window\._craft[A-Za-z]+(?:Resolve|Reject) = (?:resolve|reject)/g)).toBeNull()
    expect(bridge).toContain('_craftShortcutsResolve({set: true, count: ${shortcuts.size}})')
    expect(bridge.match(/_craftShortcutsResolve\(\{cleared: true\}\)/g)?.length).toBe(2)
    expect(bridge).toContain('_craftSharedKeychainResolve({set: true, key: ${jsQuote(key)}})')
    expect(bridge).toContain('_craftSharedKeychainResolve({removed: true, key: ${jsQuote(key)}})')
    expect(bridge).toContain('window.__craftRejectPermissionRequests = function(message)')
    expect(bridge).toContain("window.__craftRejectPermissionRequests('Android bridge closed')")
    expect(bridge).toContain('var permissionRuntimeClosed = false')
    expect(bridge).toContain('permissionRuntimeClosed = true')
    expect(bridge).toContain("return Promise.reject(new Error('Android bridge is closed'))")
  })

  it('turns synchronous native-call failures into Promise rejections', async () => {
    const output = createTempDir('craft-android-promise-call-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).not.toMatch(/Promise\.resolve\((?:CraftAndroid|window\.craft|legacy)/)
    expect(bridge).not.toContain('Promise.resolve(JSON.parse(CraftAndroid')
    for (const guardedCall of [
      'Promise.resolve().then(function() { return CraftAndroid.checkPermission(String(permission)); })',
      'Promise.resolve().then(function() { return legacySecureStore.get(key); })',
      'Promise.resolve().then(function() { return window.craft.notifications.cancel(id); })',
    ]) {
      expect(bridge).toContain(guardedCall)
    }
    expect(bridge).toContain('return {reachable: CraftAndroid.isWatchReachable()};')
    expect(bridge).toContain('function recordingCall(method, options)')
    expect(bridge).toContain("return recordingCall('startRecording', options)")
    expect(bridge).toContain('var result = JSON.parse(CraftAndroid.recordingAction(method, JSON.stringify(options || {})))')
  })

  it('rejects Bluetooth scans that never reach the platform scanner', async () => {
    const output = createTempDir('craft-android-bluetooth-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(bridge).not.toContain('bluetoothScanner?.startScan')
    expect(holder).not.toContain('bleScanner?.startScan')
    for (const message of [
      'Bluetooth is unavailable on this device',
      'Bluetooth is switched off',
      'Bluetooth permission denied',
      'Bluetooth LE scanning is unavailable',
      'Bluetooth scan could not start',
    ]) {
      expect(bridge).toContain(message)
    }
    expect(holder).toContain('fun startBluetoothWatch(activity: Activity): Int')
    expect(holder).toContain('scanner.startScan(callback)')
    expect(holder).toContain('BLUETOOTH_STARTED')
  })

  it('keeps repeated network-monitoring starts idempotent', async () => {
    const output = createTempDir('craft-android-network-watch-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(bridge).toContain('if (networkCallback != null) return')
    expect(bridge).toContain('connectivityManager.registerNetworkCallback(request, callback)')
    expect(bridge).toContain('networkCallback = callback')
    expect(holder).toContain('if (networkWatch != null) return')
    expect(holder).toContain('manager.registerNetworkCallback(request, watch)')
    expect(holder).toContain('networkWatch = watch')
  })

  it('keeps every location watch addressable by its returned id', async () => {
    const output = createTempDir('craft-android-location-watch-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).toContain('private val locationCallbacks = mutableMapOf<Int, LocationCallback>()')
    expect(bridge).toContain('locationCallbacks[currentWatchId] = callback')
    expect(bridge).toContain('locationCallbacks.remove(watchId)?.let')
    expect(bridge).toContain('requestLocationUpdates(locationRequest, callback, Looper.getMainLooper())')
    expect(bridge).not.toContain('private var locationCallback: LocationCallback?')
    expect(bridge).not.toContain('locationCallback = object : LocationCallback()')
  })

  it('settles location calls when Play Services is unavailable or silent', async () => {
    const output = createTempDir('craft-android-location-failure-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const appSource = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(appSource, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const native = readFileSync(join(appSource, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const currentPosition = bridge.slice(
      bridge.indexOf('fun getCurrentPosition('),
      bridge.indexOf('fun watchPosition('),
    )

    expect(bridge).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(native).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(bridge).toContain('rejectLocationRequest("Google Play Services is unavailable")')
    expect(bridge).toContain("message: 'Location request timed out; Google Play Services or a location provider may be unavailable'")
    expect(bridge).toContain("'_craftLocationReject',")
    expect(bridge).toContain('15000,')
    expect(native).toContain('rejectLocationRequest("Google Play Services is unavailable")')
    expect(bridge).toContain('private val oneShotLocationCallbacks')
    expect(bridge).toContain('private val oneShotLocationTimeouts')
    expect(bridge).toContain('clearOneShotLocationCallback(client, callback)')
    expect(currentPosition).toContain('private fun requestFreshLocation(')
    expect(currentPosition).toContain('client.lastLocation.addOnSuccessListener')
    expect(currentPosition).not.toContain('fusedLocationClient?.lastLocation')
    expect(currentPosition).not.toContain('fusedLocationClient?.requestLocationUpdates(locationRequest, callback')
    expect(bridge).toContain('reject(error.message ?: "Location request failed")')
    expect(native).toContain('private val currentLocationCallbacks')
    expect(native).toContain('private val currentLocationTimeouts')
    expect(native).toContain('clearCurrentLocationCallback(client, callback)')
    expect(native).toContain('reject(error.message)')
    for (const source of [bridge, native]) {
      expect(source).toContain('private val currentPositionSequence = java.util.concurrent.atomic.AtomicLong(0)')
      expect(source).toContain('val requestId = currentPositionSequence.incrementAndGet()')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (requestId != currentPositionSequence.get()) return')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('currentPositionSequence.incrementAndGet()')
      expect(source).toContain('postDelayed(timeout, LOCATION_REQUEST_TIMEOUT_MS)')
      expect(source).toContain('removeCallbacks(timeout)')
      expect(source).toContain('LOCATION_REQUEST_TIMEOUT_MS = 15_000L')
      expect(source).toContain('Location request timed out; provider returned no position')
    }
  })

  it('rejects background-task methods instead of fabricating success', async () => {
    const output = createTempDir('craft-android-background-tasks-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Background Tasks ====================')
    const end = bridge.indexOf('// ==================== PDF Viewer ====================', start)
    const backgroundTasks = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(backgroundTasks.match(/rejectBackgroundTask\(/g)?.length).toBe(5)
    expect(backgroundTasks).toContain('Background task $taskId is unavailable on Android')
    expect(backgroundTasks).toContain('Background tasks are unavailable on Android')
    expect(backgroundTasks).not.toContain('registered: true')
    expect(backgroundTasks).not.toContain('scheduled: true')
    expect(backgroundTasks).not.toContain('cancelled: true')
    expect(backgroundTasks).not.toContain('This is a placeholder that shows the API structure')
  })

  it('rejects malformed data URLs before resolving a saved-file path', async () => {
    const output = createTempDir('craft-android-save-file-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).toContain('if (parts.size != 2)')
    expect(bridge).toContain('rejectSaveFile("Malformed data URL")')
    expect(bridge).toContain('private fun rejectSaveFile(message: String?)')
    expect(bridge).not.toContain('if (parts.size == 2)')
  })

  it('omits unreachable dynamic voice-action registration', async () => {
    const output = createTempDir('craft-android-voice-actions-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).not.toContain('fun registerVoiceAction(')
    expect(bridge).not.toContain('fun removeVoiceAction(')
    expect(bridge).not.toContain('craft_voice_actions')
    expect(bridge).not.toContain('_craftVoiceResolve')
    expect(bridge).toContain('fun handleVoiceAction(intent: Intent?)')
    expect(bridge).toContain("new CustomEvent('craftVoiceAction'")
  })

  it('reports app badges unavailable instead of silently succeeding', async () => {
    const output = createTempDir('craft-android-app-badge-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// App Badge')
    const end = bridge.indexOf('// Network Status', start)
    const appBadge = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(bridge).toContain('appBadge: false')
    expect(appBadge.match(/throw new Error\('App badges are unavailable on Android'\)/g)?.length).toBe(2)
    expect(appBadge).not.toContain('CraftAndroid.setBadge')
    expect(appBadge).not.toContain('CraftAndroid.clearBadge')
    expect(bridge).not.toContain('fun setBadge(')
    expect(bridge).not.toContain('fun clearBadge(')
    expect(bridge).not.toContain('NotificationManagerCompat')
  })

  it('loads contacts with three projected provider queries', async () => {
    const output = createTempDir('craft-android-contacts-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Contacts ====================')
    const end = bridge.indexOf('// ==================== Calendar ====================', start)
    const contacts = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(contacts.match(/getContactValues\(/g)?.length).toBe(3)
    expect(contacts).toContain('val contacts = try {')
    expect(contacts).toContain('private fun loadContacts(): JSONArray')
    expect(contacts).toContain('Contacts could not be read')
    expect(contacts).toContain('arrayOf(\n                ContactsContract.Contacts._ID,')
    expect(contacts).toContain('arrayOf(contactIdColumn, valueColumn)')
    expect(contacts).not.toContain('fun getContactPhones(')
    expect(contacts).not.toContain('fun getContactEmails(')
    expect(contacts).not.toContain('CONTACT_ID + " = ?"')
  })

  it('settles contact-picker permission and launch failures', async () => {
    const output = createTempDir('craft-android-contact-picker-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun pickContact(')
    const end = bridge.indexOf('fun handleContactPickerResult(', start)
    const resultEnd = bridge.indexOf('// ==================== App Shortcuts', end)
    const picker = bridge.slice(start, end)
    const pickerResult = bridge.slice(end, resultEnd)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(resultEnd).toBeGreaterThan(end)
    expect(picker.indexOf('checkSelfPermission')).toBeLessThan(picker.indexOf('CraftNative.pickContact'))
    expect(picker).toContain('Contacts permission is required; retry after granting it')
    expect(picker).toContain('Contact picker could not be opened')
    const native = readFileSync(
      join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'),
      'utf8',
    )
    const runOnMain = native.slice(
      native.indexOf('fun runOnMain('),
      native.indexOf('fun lockOrientation(', native.indexOf('fun runOnMain(')),
    )
    expect(runOnMain).toContain('taskGeneration != lifecycleGeneration.get()')
    expect(runOnMain).toContain('activity.isFinishing || activity.isDestroyed')
    expect(runOnMain).toContain('nativeCancelTask(token)')
    expect(pickerResult).toContain('if (!cursor.moveToFirst()) return@use null')
    expect(pickerResult).toContain('if (contact == null) {')
    expect(pickerResult).toContain('Selected contact could not be read')
    expect(bridge).toContain('private fun rejectContactPicker(message: String)')
  })

  it('persists local auth sessions in encrypted preferences', async () => {
    const output = createTempDir('craft-android-auth-persistence-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Local Auth Persistence ====================')
    const end = bridge.indexOf('// ==================== AR (ARCore) ====================', start)
    const authPersistence = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(authPersistence).toContain('private val authSessionExpiryKey = "craft_auth_session_expiry"')
    expect(authPersistence).toContain('securePrefs.edit().putLong(authSessionExpiryKey, expiresAt).apply()')
    expect(authPersistence).toContain('securePrefs.getLong(authSessionExpiryKey, 0L)')
    expect(authPersistence.match(/securePrefs\.edit\(\)\.remove\(authSessionExpiryKey\)\.apply\(\)/g)?.length).toBe(2)
    expect(authPersistence).not.toContain('private var authSessionExpiry')
  })

  it('releases long-lived bridge and native-holder resources on destroy', async () => {
    const output = createTempDir('craft-android-close-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'org/wildloop/app/MainActivity.kt'), 'utf8')
    const bridgeClose = bridge.slice(bridge.indexOf('fun close()'), bridge.indexOf('// ==================== Screen Capture'))
    const nativeClose = holder.slice(holder.indexOf('fun close(activity: Activity)'), holder.indexOf('/**\n     * Run `script`'))
    const nativeDelivery = holder.slice(
      holder.indexOf('fun deliver(script: String)'),
      holder.indexOf('private external fun nativeGetDeviceInfo'),
    )
    const bridgeInitialization = bridge.slice(
      bridge.indexOf('fun injectBridge()'),
      bridge.indexOf('fun markBridgeLoading()'),
    )

    expect(activity).toContain('craftBridge.close()')
    expect(bridgeInitialization).toContain('if (closed) return@runOnUiThread')
    expect(bridgeInitialization).toContain('if (closed) return@evaluateJavascript')
    expect(bridge.match(/webView\.evaluateJavascript\(/g)?.length).toBe(4)
    expect(bridge).toContain('private fun evaluateJavascriptUnlessClosed(script: String)')
    expect(bridge).toContain('evaluatePromiseJavascript(script: String) {\n        evaluateJavascriptUnlessClosed(script)')
    // Still no throw back into Zig, and since #231 it answers whether a
    // deliverer took the script rather than swallowing the drop.
    expect(nativeDelivery).toContain('fun deliver(script: String): Boolean')
    expect(nativeDelivery).toContain('val target = deliverer ?: return false')
    expect(nativeDelivery).toContain('runCatching { target(script); true }.getOrDefault(false)')
    for (const cleanup of [
      'window.__craftRejectPendingPromises',
      'CraftNative.close(activity)',
      'speechRecognizer?.destroy()',
      'biometricPrompt?.cancelAuthentication()',
      'fusedLocationClient?.removeLocationUpdates(callback)',
      'manager.unregisterNetworkCallback(callback)',
      'sensorManager?.unregisterListener(listener)',
      'bluetoothScanner?.stopScan(callback)',
      'productBillingClient?.endConnection()',
      'restoreBillingClient?.endConnection()',
      'database?.close()',
      'setFlashlight(false)',
    ]) expect(bridgeClose).toContain(cleanup)
    for (const cleanup of [
      'deliverer = null',
      'speechRecognizer?.destroy()',
      'biometricPrompt?.cancelAuthentication()',
      'productBillingClient?.endConnection()',
      'restoreBillingClient?.endConnection()',
      'manager.unregisterNetworkCallback(watch)',
      'bleScanner?.stopScan(callback)',
      'sensorManager?.unregisterListener(listener)',
    ]) expect(nativeClose).toContain(cleanup)
  })

  it('settles review and biometric callbacks once across activity teardown', async () => {
    const output = createTempDir('craft-android-interactive-callbacks-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeReview = bridge.slice(
      bridge.indexOf('fun requestReview()'),
      bridge.indexOf('// ==================== Flashlight', bridge.indexOf('fun requestReview()')),
    )
    const holderReview = holder.slice(
      holder.indexOf('fun startReviewFlow('),
      holder.indexOf('fun requestReview(', holder.indexOf('fun startReviewFlow(')),
    )
    const bridgeBiometric = bridge.slice(
      bridge.indexOf('fun authenticate(reason: String)'),
      bridge.indexOf('// ==================== Push Notifications', bridge.indexOf('fun authenticate(reason: String)')),
    )
    const holderBiometric = holder.slice(
      holder.indexOf('fun showBiometricPrompt('),
      holder.indexOf('fun authenticate(', holder.indexOf('fun showBiometricPrompt(')),
    )

    for (const source of [bridgeReview, holderReview, bridgeBiometric, holderBiometric]) {
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('catch (error: Exception)')
    }
    expect(bridgeReview).toContain('evaluatePromiseJavascript(')
    expect(bridgeBiometric).toContain('biometricPrompt = prompt')
    expect(bridgeBiometric).toContain('rejectBiometricRequest(error.message ?: "Biometric authentication failed")')
    expect(holderReview).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
    expect(holderBiometric).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
    expect(holderBiometric).toContain('biometricPrompt = prompt')
    expect(bridge).toContain('if (closed) return@runOnUiThread')
  })

  it('settles ML task and serialization failures once and closes every client', async () => {
    const output = createTempDir('craft-android-ml-callbacks-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeMl = bridge.slice(
      bridge.indexOf('// ==================== ML Kit'),
      bridge.indexOf('// ==================== Widget Support'),
    )
    const holderMl = holder.slice(
      holder.indexOf('// ==================== ML Kit'),
      holder.indexOf('// ==================== External PDF viewer'),
    )

    expect(bridgeMl).toContain('private fun createMlSettlement(): Pair<(JSONArray) -> Unit, (String) -> Unit>')
    expect(holderMl).toContain('private fun createMlSettlement(): Pair<(String) -> Unit, (String) -> Unit>')
    for (const source of [bridgeMl, holderMl]) {
      expect(source.match(/val \(resolve, reject\) = createMlSettlement\(\)/g)?.length).toBe(3)
      expect(source.match(/\.addOnCompleteListener \{/g)?.length).toBe(3)
      expect(source.match(/\.close\(\)/g)?.length).toBe(3)
      expect(source.match(/catch \(error: Exception\)/g)?.length).toBe(3)
      expect(source).toContain('settled.compareAndSet(false, true)')
    }
    expect(bridgeMl).toContain('!closed && settled.compareAndSet(false, true)')
    expect(holderMl).toContain('requestGeneration == lifecycleGeneration.get()')
  })

  it('invalidates queued screenshot and PDF replies during teardown', async () => {
    const output = createTempDir('craft-android-queued-replies-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeScreenshot = bridge.slice(
      bridge.indexOf('fun takeScreenshot()'),
      bridge.indexOf('// ==================== Background Tasks'),
    )
    const holderScreenshot = holder.slice(
      holder.indexOf('fun captureScreenshot('),
      holder.indexOf('fun takeScreenshot('),
    )
    const bridgePdf = bridge.slice(
      bridge.indexOf('fun openPDF('),
      bridge.indexOf('// ==================== Contact Picker'),
    )
    const holderPdf = holder.slice(
      holder.indexOf('fun openPdfExternal('),
      holder.indexOf('fun openPDF('),
    )

    for (const source of [holderScreenshot, holderPdf]) {
      expect(source).toContain('val requestGeneration = lifecycleGeneration.get()')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
      expect(source).toContain('if (!settled.compareAndSet(false, true)) return')
      expect(source).toContain('return@runOnUiThread')
    }
    for (const source of [bridgeScreenshot, bridgePdf]) {
      expect(source).toContain('if (closed) return@runOnUiThread')
      expect(source).toContain('evaluatePromiseJavascript(')
    }
    for (const source of [bridgeScreenshot, holderScreenshot]) {
      expect(source).toContain('finally {')
      expect(source).toContain('view.isDrawingCacheEnabled = false')
    }
  })

  it('connects Play Billing for restores and settles failure paths', async () => {
    const output = createTempDir('craft-android-billing-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')

    for (const source of [bridge, holder]) {
      expect(source).toContain('if (connectedClient != null && connectedClient.isReady) {')
      expect(source).toContain('private var productBillingClient: BillingClient? = null')
      expect(source).toContain('private var restoreBillingClient: BillingClient? = null')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('queryRestoredPurchases(connectedClient, ::resolveRestoreRequest, ::rejectRestoreRequest)')
      expect(source).toContain('reject: (String) -> Unit')
      expect(source).toContain('Billing setup failed: ${billingResult.debugMessage}')
      expect(source).toContain('Product query failed: ${result.debugMessage}')
      expect(source).toContain('Restore failed: ${result.debugMessage}')
      expect(source).not.toContain('billingClient?.queryPurchasesAsync(')
      expect(source).not.toContain('load products before restoring purchases')
    }
    expect(bridge).toContain('CraftNative.restorePurchases(activity)')
    expect(bridge).toContain('private fun rejectProducts(message: String)')
    expect(bridge).toContain('private fun rejectRestore(message: String)')
    expect(bridge).toContain('put("title", details.name)')
    expect(holder).toContain('put("title", details.name)')
    expect(bridge).toContain('private var closed = false')
    expect(bridge).toContain('closed = true')
    expect(holder).toContain('private external fun nativeRestorePurchases(activity: Activity): Boolean')
    expect(holder).toContain('private val lifecycleGeneration = java.util.concurrent.atomic.AtomicLong(0)')
    expect(holder).toContain('lifecycleGeneration.incrementAndGet()')
    expect(holder).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
  })

  it('rejects calendar-provider failures instead of hanging the promise', async () => {
    const output = createTempDir('craft-android-calendar-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun getCalendarEvents(')
    const end = bridge.indexOf('fun createCalendarEvent(', start)
    const getEvents = bridge.slice(start, end)
    const tryStart = getEvents.indexOf('try {')
    const queryStart = getEvents.indexOf('activity.contentResolver.query(')

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(tryStart).toBeGreaterThan(-1)
    expect(queryStart).toBeGreaterThan(tryStart)
    expect(getEvents.match(/catch \(e: Exception\)/g)?.length).toBe(1)
    expect(getEvents).toContain('jsQuote(e.message ?: "Calendar events could not be read")')
  })

  it('rejects widget reload failures instead of hanging the promise', async () => {
    const output = createTempDir('craft-android-widget-errors-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun reloadWidgets()')
    const end = bridge.indexOf('// ==================== Google Assistant', start)
    const reload = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(reload).toContain('try {')
    expect(reload).toContain('activity.sendBroadcast(intent)')
    expect(reload).toContain('window._craftWidgetReject')
    expect(reload).toContain('Widget reload failed')
  })

  it('reports SQLite changed rows instead of a constant', async () => {
    const output = createTempDir('craft-android-database-count-')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun dbExecute(')
    const end = bridge.indexOf('fun dbQuery(', start)
    const execute = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(execute).toContain('database!!.compileStatement(sql).use { statement ->')
    expect(execute).toContain('statement.bindString(index + 1, value)')
    expect(execute).toContain('statement.executeUpdateDelete()')
    expect(execute).toContain('{rowsAffected: $rowsAffected}')
    expect(execute).not.toContain('{rowsAffected: 1}')
    expect(execute).not.toContain('database?.execSQL(sql, args)')
  })

  it('generates Health Connect permissions, APIs, and workout write-back only when enabled', async () => {
    const output = createTempDir('craft-android-health-')
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { compileSdk: 34, enableHealthConnect: true, minSdk: ANDROID_MIN_SDK },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const health = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftHealthConnect.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(bridge).toContain('health: true')
    expect(bridge).toContain('saveHealthWorkout')
    expect(bridge).toContain("'steps', 'heartRate', 'activeEnergy', 'distance', 'workouts'")
    expect(health).toContain('HealthConnectClient')
    expect(health).toContain('ExerciseSessionRecord')
    expect(health).toContain('At least one Health Connect permission type is required')
    expect(health).toContain('Unsupported Health Connect permission type:')
    expect(health).toContain('activity.applicationInfo.loadLabel(activity.packageManager).toString()')
    expect(health).toContain('private val closed = java.util.concurrent.atomic.AtomicBoolean(false)')
    expect(health).toContain('private val authorizationPending = java.util.concurrent.atomic.AtomicBoolean(false)')
    expect(health).toContain('if (closed.get()) return@runOnUiThread')
    expect(health).toContain('if (closed.get()) return true')
    expect(health).toContain('if (!authorizationPending.compareAndSet(true, false)) return true')
    expect(health).toContain('val requested = pendingPermissions')
    expect(health).toContain('granted.containsAll(requested)')
    expect(health).toContain('Health permission result could not be read')
    expect(health).toContain('closed.set(true)')
    expect(health).toContain('pendingPermissions = emptySet()')
    expect(health).toContain('error.message ?: "Health permissions could not be requested"')
    expect(health).not.toContain('title = "WildLoop"')
    expect(manifest).toContain('android.permission.health.WRITE_EXERCISE')
    expect(manifest).toContain('com.google.android.apps.healthdata')
    expect(manifest).toContain('android.intent.category.HEALTH_PERMISSIONS')
    expect(gradle).toContain('androidx.health.connect:connect-client')
    expect(gradle).toContain('compileSdk = 36')
    expect(gradle).toContain('minSdk = 26')
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.compileSdk).toBe(36)
    expect(config.minSdk).toBe(26)
  })

  it('wires the native Health Connect live-workout lifecycle and event sink', async () => {
    const output = createTempDir('craft-android-native-health-workout-')
    try {
      await init({
        name: 'NativeHealth',
        packageName: 'org.native.health',
        output,
        config: { renderer: 'native', enableHealthConnect: true },
      })
      const java = join(output, 'app/src/main/java/org/native/health')
      const health = readFileSync(join(java, 'CraftNativeHealth.kt'), 'utf8')
      const services = readFileSync(join(java, 'CraftNativeServices.kt'), 'utf8')
      expect(health).toContain('"startWorkout" -> answer(completion) { startWorkout(options(0)) }')
      expect(health).toContain('"pauseWorkout" -> answer(completion) { pauseWorkout() }')
      expect(health).toContain('"resumeWorkout" -> answer(completion) { resumeWorkout() }')
      expect(health).toContain('"endWorkout" -> answer(completion) { endWorkout() }')
      expect(health).toContain('A live workout is already running')
      expect(health).toContain('saveWorkout(body) as JSONObject')
      expect(health).toContain('put("durationSeconds", duration)')
      expect(health).toContain('workoutSink?.invoke(JSONObject().put("id", workout.id)')
      expect(services).toContain('put("event", "craftHealthWorkout")')
      expect(services).toContain('CraftNativeHealth(context, activity, config.optBoolean("enableHealthConnectBackground"), config.optBoolean("enableHealthConnectHistory"))')
    }
    finally {
      rmSync(output, { recursive: true, force: true })
    }
  })

  it('generates the opt-in Health Services dependency, permissions, and service owner', async () => {
    const output = createTempDir('craft-android-health-services-')
    try {
      await init({
        name: 'NativeHealthServices',
        packageName: 'org.native.healthservices',
        output,
        config: { renderer: 'native', enableHealthServices: true },
      })
      const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
      const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
      const java = join(output, 'app/src/main/java/org/native/healthservices')
      const adapter = readFileSync(join(java, 'CraftHealthServices.kt'), 'utf8')
      const service = readFileSync(join(java, 'CraftHealthServicesService.kt'), 'utf8')
      const nativeServices = readFileSync(join(java, 'CraftNativeServices.kt'), 'utf8')
      expect(manifest).toContain('android.permission.BODY_SENSORS')
      expect(manifest).toContain('android.permission.BODY_SENSORS_BACKGROUND')
      expect(manifest).toContain('android.permission.health.READ_HEART_RATE')
      expect(manifest).toContain('android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')
      expect(manifest).toContain('android.permission.FOREGROUND_SERVICE_HEALTH')
      expect(manifest).toContain('CraftHealthServicesService')
      expect(gradle).toContain('androidx.health:health-services-client:1.1.0')
      expect(adapter).toContain('startForegroundService')
      expect(nativeServices).toContain('CraftHealthServices(context, activity, health?.let { healthApi ->')
      expect(nativeServices).toContain('healthApi.perform(method, args, completion)')
      expect(nativeServices).toContain('add("healthServices")')
      expect(service).toContain('HealthServices.getClient(this).exerciseClient')
      expect(service).toContain('setUpdateCallback(executor, callback)')
      expect(service).toContain('startExerciseAsync(config)')
      expect(service).toContain('endExerciseAsync()')
      expect(service).toContain('CraftHealthServices.completeEnd')
      expect(service).toContain('if (state.isEnded) {')
      expect(service).toContain('CraftHealthServices.clearActive()')
      expect(adapter).toContain('fallback.invoke("saveWorkout"')
      expect(service).toContain('activeEnergyCalories')
      expect(service).toContain('distanceMeters')
      expect(service).toContain('"activityId", id')
      expect(service).toContain('"workoutId", id')
      expect(service).toContain('DataType.HEART_RATE_BPM')
      expect(service).toContain('DataType.CALORIES_TOTAL')
      expect(service).toContain('DataType.DISTANCE_TOTAL')
      expect(service).toContain('craftHealthWorkout')
      expect(gradle).not.toContain('HEALTH_SERVICES_DEPENDENCIES')
    }
    finally {
      rmSync(output, { recursive: true, force: true })
    }
  })

  it('invalidates Health Connect replies in enabled and disabled builds', async () => {
    const disabledOutput = createTempDir('craft-android-health-disabled-close-')
    const enabledOutput = createTempDir('craft-android-health-enabled-close-')
    await init({ name: 'DisabledHealth', packageName: 'org.health.disabled', output: disabledOutput })
    await init({
      name: 'EnabledHealth',
      packageName: 'org.health.enabled',
      output: enabledOutput,
      config: { enableHealthConnect: true },
    })

    for (const [output, packagePath] of [
      [disabledOutput, 'org/health/disabled'],
      [enabledOutput, 'org/health/enabled'],
    ]) {
      const health = readFileSync(
        join(output, `app/src/main/java/${packagePath}/CraftHealthConnect.kt`),
        'utf8',
      )
      expect(health).toContain('private val closed = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(health).toContain('closed.set(true)')
      expect(health).toContain('if (closed.get()) return@runOnUiThread')
    }
  })
})

/**
 * A runtime directory shaped like `zig build build-android-all`'s output.
 *
 * The contents are not a real ELF — nothing here loads it — but the layout is
 * exactly `zig-out/android/<abi>/libcraft.so`, because the layout is the part
 * the installer depends on.
 */
function fakeRuntime(abis: string[]): string {
  const dir = createTempDir('craft-android-runtime-')
  for (const abi of abis) {
    mkdirSync(join(dir, abi), { recursive: true })
    writeFileSync(join(dir, abi, 'libcraft.so'), `not-really-${abi}`)
  }
  return dir
}

describe('Zig runtime installation', () => {
  it('lands the library where AGP already looks for it', () => {
    // app/src/main/jniLibs is the default jniLibs.srcDirs, which is why no
    // Gradle template has to know this happened.
    const output = createTempDir('craft-android-jnilibs-')
    installRuntime(output, fakeRuntime(['arm64-v8a', 'x86_64']))

    expect(readFileSync(join(output, 'app/src/main/jniLibs/arm64-v8a/libcraft.so'), 'utf8')).toBe('not-really-arm64-v8a')
    expect(readFileSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'), 'utf8')).toBe('not-really-x86_64')
  })

  it('installs what it has when an architecture is missing', () => {
    // A one-ABI dev loop is legitimate; it just cannot run on the other kind
    // of device, which the installer warns about rather than refusing.
    const output = createTempDir('craft-android-one-abi-')
    expect(installRuntime(output, fakeRuntime(['x86_64']))).toBe(true)

    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a'))).toBe(false)
  })

  it('refuses a directory with no library at all, and names the build step', () => {
    const output = createTempDir('craft-android-no-abi-')
    const empty = createTempDir('craft-android-empty-')

    expect(() => installRuntime(output, empty)).toThrow(/zig build build-android-all/)
    // Nothing written on the way to throwing.
    expect(existsSync(join(output, 'app/src/main/jniLibs'))).toBe(false)
  })

  it('does not leave an architecture behind that a later build dropped', () => {
    // A stale .so still ships in the APK and still loads, so the app would run
    // an architecture nobody built for this version.
    const output = createTempDir('craft-android-stale-')
    installRuntime(output, fakeRuntime(['arm64-v8a', 'x86_64']))
    installRuntime(output, fakeRuntime(['x86_64']))

    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a'))).toBe(false)
    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
  })

  it('generates a shim-only app when no runtime is configured', async () => {
    // The default, and the state every generated app was in before this
    // existed: System.loadLibrary throws, isAvailable is false, Kotlin serves.
    const output = createTempDir('craft-android-shim-only-')
    await init({ name: 'ShimOnly', packageName: 'dev.craft.shimonly', output, runtimeDir: null })

    expect(existsSync(join(output, 'app/src/main/jniLibs'))).toBe(false)
  })

  it('installs the runtime from init when one is given', async () => {
    const output = createTempDir('craft-android-with-runtime-')
    await init({
      name: 'WithRuntime',
      packageName: 'dev.craft.withruntime',
      output,
      runtimeDir: fakeRuntime(['arm64-v8a', 'x86_64']),
    })

    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a/libcraft.so'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
  })

  it('reads CRAFT_ANDROID_RUNTIME only when the caller says nothing', () => {
    const dir = fakeRuntime(['x86_64'])
    const previous = process.env.CRAFT_ANDROID_RUNTIME
    process.env.CRAFT_ANDROID_RUNTIME = dir

    try {
      expect(resolveRuntimeDir()).toBe(dir)
      // null is a declaration, not a gap: no runtime whatever the environment
      // says, which is what the E2E suite's shim leg depends on.
      expect(resolveRuntimeDir(null)).toBe(null)
    }
    finally {
      if (previous === undefined) delete process.env.CRAFT_ANDROID_RUNTIME
      else process.env.CRAFT_ANDROID_RUNTIME = previous
    }
  })

  it('names which knob pointed at a directory that is not there', () => {
    const previous = process.env.CRAFT_ANDROID_RUNTIME
    process.env.CRAFT_ANDROID_RUNTIME = '/craft/definitely/not/here'

    try {
      expect(() => resolveRuntimeDir()).toThrow(/CRAFT_ANDROID_RUNTIME points at/)
      expect(() => resolveRuntimeDir('/craft/also/not/here')).toThrow(/runtimeDir is/)
    }
    finally {
      if (previous === undefined) delete process.env.CRAFT_ANDROID_RUNTIME
      else process.env.CRAFT_ANDROID_RUNTIME = previous
    }
  })
})

describe('the Zig library and the generated app agree on how old a device may be', () => {
  it('builds the JNI library for no newer an API than minSdk', () => {
    // One prebuilt libcraft.so serves every generated app, so it has to be
    // linked against the *oldest* API craft's default configuration claims to
    // support. Build it against a newer one and the linker happily binds
    // symbols that are simply absent on an older phone — and the failure is
    // dlopen refusing the library at startup, on exactly the devices the app
    // said it ran on.
    //
    // Nothing else connects a Zig constant to a TypeScript one, so this reads
    // build.zig and compares.
    const buildZig = readFileSync(join(import.meta.dir, '../../zig/build.zig'), 'utf8')
    const declared = buildZig.match(/const android_api_level: u32 = (\d+);/)

    expect(declared).not.toBeNull()

    expect(Number(declared![1])).toBeLessThanOrEqual(ANDROID_MIN_SDK)
  })
})

describe('crash reporting (CraftCrashReporter.kt)', () => {
  it('writes the reporter for both renderers and starts it from a content provider', async () => {
    const root = createTempDir('craft-android-crash-')
    try {
      for (const renderer of ['web', 'native'] as const) {
        const output = join(root, renderer)
        await init({ name: 'Crash', output, runtimeDir: null, config: { renderer, crashReporting: { key: 'bughq_k' } } })
        const reporter = readFileSync(join(output, 'app/src/main/java/com/craft/crash/CraftCrashReporter.kt'), 'utf8')
        expect(reporter).toContain('package com.craft.crash')
        expect(reporter).not.toContain('{{')
        expect(reporter).toContain('Thread.setDefaultUncaughtExceptionHandler')
        expect(reporter).toContain('getHistoricalProcessExitReasons')
        const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
        expect(manifest).toContain('<provider android:name=".CraftCrashReporterInit" android:authorities="${applicationId}.craft-crash" android:exported="false"')
        const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
        expect(gradle).toContain('buildConfig = true')
        expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8')).crashReporting).toEqual({ key: 'bughq_k' })
      }
    }
    finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps the test crash behind BuildConfig.DEBUG, which R8 drops from release', () => {
    const source = readFileSync(join(import.meta.dir, '../templates/CraftCrashReporter.kt.template'), 'utf8')
    const start = source.indexOf('fun debugCrashTestRequested(')
    expect(source.slice(start, start + 200)).toContain('if (!BuildConfig.DEBUG')
    const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')
    expect(activity).toContain('if (BuildConfig.DEBUG && savedInstanceState == null) {')
  })
})


it('emits native Bluetooth GATT support and versioned permissions only when enabled', async () => {
  const output = createTempDir('craft-android-bluetooth-')
  try {
    await init({ name: 'Bluetooth', output, packageName: 'dev.craft.bluetooth', config: { renderer: 'native', enableBluetooth: true } })
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(manifest).toContain('android.permission.BLUETOOTH_SCAN')
    expect(manifest).toContain('android:usesPermissionFlags="neverForLocation"')
    expect(manifest).toContain('android.permission.BLUETOOTH_CONNECT')
    const kotlin = readFileSync(join(output, 'app/src/main/java/dev/craft/bluetooth/CraftBluetooth.kt'), 'utf8')
    expect(kotlin).toContain('requestMtu(247)')
    expect(kotlin).toContain('responsePrefix')
    expect(renderAndroidPermissions({ appName: 'Off', packageName: 'dev.craft.off' })).not.toContain('BLUETOOTH')
  }
  finally { rmSync(output, { recursive: true, force: true }) }
})

it('declares location once when Bluetooth overlaps unrestricted location capabilities', () => {
  for (const bluetooth of ['enableBluetooth', 'enableHeartRate'] as const) {
    for (const location of ['enableGeolocation', 'enableBackgroundLocation', 'enableHealthServices'] as const) {
      const permissions = renderAndroidPermissions({
        appName: 'Combined capabilities',
        packageName: 'dev.craft.combined',
        [bluetooth]: true,
        [location]: true,
      })
      const fineLocation = permissions.split('\n').filter(line => line.includes('"android.permission.ACCESS_FINE_LOCATION"'))
      expect(fineLocation).toEqual(['    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />'])
    }
  }
})

it('reads a heart-rate strap on the page and on native screens alike, declared only when enabled', async () => {
  for (const renderer of ['native', 'web'] as const) {
    const output = createTempDir(`craft-android-heart-rate-${renderer}-`)
    const off = createTempDir(`craft-android-heart-rate-off-${renderer}-`)
    try {
      await init({ name: 'Strap', output, packageName: 'dev.craft.strap', runtimeDir: null, config: { renderer, enableHeartRate: true } })
      const java = join(output, 'app/src/main/java/dev/craft/strap')
      const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
      // Nearby devices on Android 12+, never for location; location below it.
      expect(manifest).toContain('<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />')
      expect(manifest).toContain('<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />')
      expect(manifest).toContain('<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />')
      expect(manifest).toContain('<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />')
      // The recording keeps the process in the foreground as a connectedDevice service.
      expect(manifest).toContain('<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />')
      expect(manifest).toContain('<service android:name=".CraftHeartRateService" android:exported="false" android:foregroundServiceType="connectedDevice" />')
      const service = readFileSync(join(java, 'CraftHeartRate.kt'), 'utf8')
      const core = readFileSync(join(java, 'CraftHeartRateCore.kt'), 'utf8')
      expect(service.startsWith('package dev.craft.strap\n')).toBe(true)
      expect(core.startsWith('package dev.craft.strap\n')).toBe(true)
      expect(service).toContain('UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")')
      expect(service).toContain('UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")')
      expect(service).toContain('peer.setCharacteristicNotification(measurement, true)')
      expect(service).toContain('BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE')
      // A dropped link: the old client closed, an automatic connection asked for.
      expect(service).toMatch(/closeGatt\(\)\n\s+if \(wantsConnection\) \{\n\s+connection = "reconnecting"\n\s+scheduleReconnect\(\)/)
      expect(service).toContain('openGatt(automatic = true)')
      // The stand-in strap is an emulator's only.
      expect(service).toContain('isEmulator() && File(context.filesDir, "CraftFakeHeartRateMonitor").exists()')
      if (renderer !== 'native') {
        const bridge = readFileSync(join(java, 'CraftBridge.kt'), 'utf8')
        expect(bridge).toContain('heartRate: true,')
        expect(bridge).toContain('private val heartRateEnabled = true')
      } else expect(existsSync(join(java, 'CraftBridge.kt'))).toBe(false)
      if (renderer === 'native') {
        const services = readFileSync(join(java, 'CraftNativeServices.kt'), 'utf8')
        expect(services).toContain('if (heartRateEnabled) addAll(listOf("heartRate", "heartRateRecordingOwnership", "heartRateRecordingIntentIdentity"))')
        expect(services).toContain('"Location", "Media", "CrashReporter", "HeartRate",')
        expect(services).toContain('if (!heartRateEnabled) return done(failure("CAPABILITY_DISABLED", "Heart rate is disabled"))')
        expect(services).toContain('CraftNativeHub.broadcast("CRAFT_EVENT", JSONObject().put("event", "craftHeartRate").put("detail", detail))')
        expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8')).enableHeartRate).toBe(true)
      }

      // Without the flag the sources still compile in (the bridge names
      // them), but nothing is declared, advertised or asked for.
      await init({ name: 'Plain', output: off, packageName: 'dev.craft.plain', runtimeDir: null, config: { renderer } })
      const plain = readFileSync(join(off, 'app/src/main/AndroidManifest.xml'), 'utf8')
      expect(plain).not.toContain('BLUETOOTH')
      expect(plain).not.toContain('CraftHeartRateService')
      expect(plain).not.toContain('FOREGROUND_SERVICE_CONNECTED_DEVICE')
      expect(existsSync(join(off, 'app/src/main/java/dev/craft/plain/CraftHeartRate.kt'))).toBe(true)
      if (renderer !== 'native') expect(readFileSync(join(off, 'app/src/main/java/dev/craft/plain/CraftBridge.kt'), 'utf8')).toContain('heartRate: false,')
    }
    finally {
      rmSync(output, { recursive: true, force: true })
      rmSync(off, { recursive: true, force: true })
    }
  }
})

it('declares the Bluetooth permissions once for a strap and a GATT channel together', () => {
  const both = renderAndroidPermissions({ appName: 'Both', packageName: 'dev.craft.both', enableBluetooth: true, enableHeartRate: true })
  expect(both.match(/BLUETOOTH_CONNECT/g)?.length).toBe(1)
  expect(both).toContain('android.permission.FOREGROUND_SERVICE"')
  expect(renderAndroidPermissions({ appName: 'Gatt', packageName: 'dev.craft.gatt', enableBluetooth: true })).not.toContain('FOREGROUND_SERVICE_CONNECTED_DEVICE')
})

it('packs large native sources losslessly and idempotently without touching small assets', () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-source-compression-'))
  try {
    const source = 'globalThis.ready = true;\n'.repeat(5000)
    const file = join(root, 'screen.js')
    writeFileSync(file, source)
    writeFileSync(join(root, 'config.json'), '{}')
    compressNativeSources(root)
    const packed = readFileSync(file)
    expect(packed.length).toBeLessThan(source.length / 5)
    expect(gunzipSync(packed).toString()).toBe(source)
    expect(readFileSync(join(root, 'config.json'), 'utf8')).toBe('{}')
    compressNativeSources(root)
    expect(readFileSync(file)).toEqual(packed)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

it('native projects omit the WebView ML models while preserving JNI callback signatures', async () => {
  const root = createTempDir('craft-native-no-ml-')
  try {
    await init({ name: 'Lean', packageName: 'dev.craft.lean', output: root, runtimeDir: null, config: { renderer: 'native' } })
    const runtime = readFileSync(join(root, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')
    const gradle = readFileSync(join(root, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).not.toContain('com.google.mlkit:')
    expect(runtime).not.toContain('import com.google.mlkit.')
    for (const method of ['runTextRecognition', 'runObjectDetection', 'runImageClassification']) expect(runtime).toContain(`fun ${method}(imageBase64: String)`)
    expect(existsSync(join(root, 'app/src/main/java/dev/craft/lean/CraftBridge.kt'))).toBe(false)
    // Switching a generated project back to web restores the public web API.
    await init({ name: 'Lean', packageName: 'dev.craft.lean', output: root, runtimeDir: null, config: { renderer: 'web' } })
    expect(readFileSync(join(root, 'app/build.gradle.kts'), 'utf8')).toContain('com.google.mlkit:text-recognition')
    expect(readFileSync(join(root, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')).toContain('import com.google.mlkit.')
    expect(existsSync(join(root, 'app/src/main/java/dev/craft/lean/CraftBridge.kt'))).toBe(true)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

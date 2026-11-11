/**
 * Exercise the Windows or Linux desktop bridge of a built `craft` binary:
 * the application menu and its accelerators, context menus, file and message
 * dialogs, file drop, single-instance activation, and relaunch.
 *
 * The page calls the same `window.craft.*` an app would. Everything a person
 * would do with their hands (press a key, pick a menu item, answer a dialog,
 * drag a file) is done to the real native windows from outside the process:
 * with xdotool on Linux, and with a small Win32 probe on Windows.
 *
 * Linux needs a display, a window manager and a session bus, and this script
 * starts second processes that must share them. Run it inside the wrapper:
 *
 *   sh scripts/run-linux-with-wm.sh bun scripts/verify-desktop-bridge.ts <craft>
 */
import type { ChildProcess } from 'node:child_process'
import { execFileSync, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { platform, tmpdir } from 'node:os'
import { join } from 'node:path'

const binary = process.argv[2]
if (!binary) throw new Error('usage: bun scripts/verify-desktop-bridge.ts <craft-binary>')
const isWindows = platform() === 'win32'
const platformName = isWindows ? 'Windows' : 'Linux'
if (!isWindows && platform() !== 'linux') throw new Error('this smoke covers the Windows and Linux bridges only')
if (!isWindows && !process.env.DISPLAY)
  throw new Error('no DISPLAY: run through scripts/run-linux-with-wm.sh so every process shares one display and session bus')

const windowTitle = 'Craft Bridge Smoke'
const instanceId = `craft-bridge-smoke-${randomUUID()}`
const deepLink = `craftbridgesmoke://second/${randomUUID()}`
const workDir = realpathSync(mkdtempSync(join(tmpdir(), 'craft-bridge-smoke-')))
const pickDir = join(workDir, 'pick')
mkdirSync(pickDir)
const pickFile = join(pickDir, 'chosen.txt')
writeFileSync(pickFile, 'chosen\n')
const dropFile = join(workDir, 'dropped file.txt')
writeFileSync(dropFile, 'dropped\n')
const saveName = 'saved-by-smoke.txt'

// ---------------------------------------------------------------------------
// The page under test
// ---------------------------------------------------------------------------

const mainPage = `<!doctype html><title>${windowTitle}</title>
<body style="margin:0;font:14px sans-serif"><p id="status">running</p>
<script>
(async () => {
  const isWindows = ${isWindows}
  const pickFile = ${JSON.stringify(pickFile)}
  const pickDir = ${JSON.stringify(pickDir)}
  const saveName = ${JSON.stringify(saveName)}
  const dropFile = ${JSON.stringify(dropFile)}
  const deepLink = ${JSON.stringify(deepLink)}
  const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms))
  const report = (step) => fetch('/report?step=' + encodeURIComponent(step), { method: 'POST' })
  const native = async (op, params = {}) => {
    const response = await fetch('/native?' + new URLSearchParams({ op, ...params }), { method: 'POST' })
    const body = await response.json()
    if (!response.ok || body.error) throw new Error(op + ' failed natively: ' + (body.error || response.status))
    return body
  }
  const until = async (predicate, label, timeoutMs = 10000) => {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (await predicate()) return
      await sleep(50)
    }
    throw new Error(label)
  }
  const within = (promise, label, timeoutMs = 20000) => {
    let timer
    return Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(label)), timeoutMs) }),
    ]).finally(() => clearTimeout(timer))
  }
  const samePath = (a, b) => isWindows
    ? String(a).toLowerCase().replaceAll('/', '\\\\') === String(b).toLowerCase().replaceAll('/', '\\\\')
    : a === b

  try {
    const craft = window.craft
    for (const [name, value] of [
      ['craft.menu.set', craft?.menu?.set], ['craft.menu.onAction', craft?.menu?.onAction],
      ['craft.dialog.showOpenDialog', craft?.dialog?.showOpenDialog], ['craft.dialog.showSaveDialog', craft?.dialog?.showSaveDialog],
      ['craft.dialog.showAlert', craft?.dialog?.showAlert], ['craft.dialog.showConfirm', craft?.dialog?.showConfirm],
      ['craft.nativeUI.showContextMenu', craft?.nativeUI?.showContextMenu],
      ['craft.nativeUI.onContextMenuAction', craft?.nativeUI?.onContextMenuAction],
      ['craft.onFileDrop', craft?.onFileDrop], ['craft.deepLink.onUrl', craft?.deepLink?.onUrl],
      ['craft.app.relaunch', craft?.app?.relaunch], ['craft.app.onSecondInstance', craft?.app?.onSecondInstance],
    ]) {
      if (typeof value !== 'function') throw new Error('document-start bridge is missing ' + name)
    }
    await report('surface')

    // ---- Application menu and accelerators --------------------------------
    const actions = []
    craft.menu.onAction(detail => actions.push(detail.id))
    let settingsOpened = 0
    craft.settings.onOpen(() => { settingsOpened++ })
    const expectAction = async (id, label) => {
      const before = actions.length
      await until(() => actions.length > before, label + ': no craft:menu:action arrived')
      const got = actions[actions.length - 1]
      if (got !== id) throw new Error(label + ': expected ' + id + ', got ' + got)
    }
    const expectNoAction = async (label) => {
      const before = actions.length
      await sleep(700)
      if (actions.length !== before) throw new Error(label + ': unexpected action ' + actions[actions.length - 1])
    }

    await native('activate')
    const heightWithoutMenu = window.innerHeight
    await craft.menu.set({ menus: [
      { label: 'File', items: [
        { id: 'new', label: 'New & Improved', shortcut: 'cmd+n' },
        { separator: true },
        { id: 'toggle', label: 'Toggle' },
        { label: 'Copy', role: 'copy', shortcut: 'cmd+c' },
        { label: 'Hide', role: 'hide' },
        { label: 'Preferences', role: 'settings', shortcut: 'cmd+,' },
      ] },
      { label: 'View', items: [{ id: 'zoom-in', label: 'Zoom In', shortcut: 'cmd+shift+z' }] },
    ] })
    await until(() => window.innerHeight < heightWithoutMenu - 10, 'the menu bar took no room above the page')
    const heightWithMenu = window.innerHeight

    if (isWindows) {
      const state = await native('menu-state')
      const labels = state.menus.map(menu => menu.label)
      if (labels.join('|') !== 'File|View') throw new Error('menu bar labels were ' + JSON.stringify(labels))
      const file = state.menus[0].items.map(item => item.text)
      // "&" is doubled so Win32 draws it; the mac-only Hide item is left out.
      if (file.join('|') !== 'New && Improved\\tCtrl+N||Toggle|Copy\\tCtrl+C|Preferences\\tCtrl+,')
        throw new Error('File menu items were ' + JSON.stringify(file))
      // Choosing an item with the pointer is a WM_COMMAND carrying its id.
      await native('menu-command', { menu: '0', item: '2' })
      await expectAction('toggle', 'chosen menu item')
    }

    // Focus on the window itself, then on the page: on Windows those are two
    // different routes for a key press (the message loop, and WebView2).
    await native('accelerator', { keys: 'ctrl+n' })
    await expectAction('new', 'accelerator with focus on the window')
    await native('click-page')
    await native('accelerator', { keys: 'ctrl+shift+z' })
    await expectAction('zoom-in', 'accelerator with focus in the page')
    await native('accelerator', { keys: 'ctrl+comma' })
    await until(() => settingsOpened === 1, 'the settings role did not raise craft:settings:open')

    await craft.menu.disableItem('new')
    await sleep(300)
    await native('accelerator', { keys: 'ctrl+n' })
    await expectNoAction('disabled item')
    await craft.menu.enableItem('new')
    await craft.menu.checkItem('toggle')
    await craft.menu.setItemLabel('toggle', 'Renamed')
    await craft.menu.addItem('File', { id: 'added', label: 'Added', shortcut: 'cmd+shift+a', index: 0 })
    await sleep(300)
    if (isWindows) {
      const items = (await native('menu-state')).menus[0].items
      if (items[0].text !== 'Added\\tCtrl+Shift+A') throw new Error('added item was not first: ' + JSON.stringify(items))
      const renamed = items.find(item => item.text === 'Renamed')
      if (!renamed || !renamed.checked) throw new Error('renamed item lost its check mark: ' + JSON.stringify(items))
      if (items.find(item => item.text.startsWith('New'))?.grayed) throw new Error('re-enabled item stayed grayed')
    }
    await native('accelerator', { keys: 'ctrl+n' })
    await expectAction('new', 're-enabled item')
    await native('accelerator', { keys: 'ctrl+shift+a' })
    await expectAction('added', 'added item')
    await craft.menu.removeItem('added')
    await sleep(300)
    await native('accelerator', { keys: 'ctrl+shift+a' })
    await expectNoAction('removed item')
    if (Math.abs(window.innerHeight - heightWithMenu) > 4) throw new Error('editing the menu changed the bar height')
    await report('menu')

    // ---- Context menus -----------------------------------------------------
    const contextEvents = []
    craft.nativeUI.onContextMenuAction(detail => contextEvents.push(detail))
    const contextItems = [
      { id: 'open', title: 'Open', shortcut: 'cmd+o' },
      { id: 'separator', title: '', type: 'separator' },
      { id: 'more', title: 'More', type: 'submenu', submenu: [{ id: 'deep', title: 'Deep' }] },
      { id: 'delete', title: 'Delete', enabled: false },
    ]
    const openContextMenu = () => craft.nativeUI.showContextMenu({ targetId: 'row "1"', targetType: 'file', x: 60, y: 60, items: contextItems })
    const settleContextMenu = async (pending, keys, label) => {
      let outcome
      pending.then(value => { outcome = { value } }, error => { outcome = { error } })
      // The popup needs a moment to take the keyboard. Repeat until it answers.
      for (let attempt = 0; attempt < 8 && !outcome; attempt++) {
        await sleep(500)
        if (!outcome) await native('popup-keys', { keys })
        await sleep(400)
      }
      if (!outcome) throw new Error(label + ': the context menu never closed')
      if (outcome.error) throw new Error(label + ': ' + (outcome.error.message || outcome.error.code))
      return outcome.value
    }
    const dismissed = await settleContextMenu(openContextMenu(), 'Escape', 'dismissed context menu')
    if (dismissed.id !== null || dismissed.targetId !== 'row "1"' || dismissed.targetType !== 'file')
      throw new Error('dismissed context menu answered ' + JSON.stringify(dismissed))
    const chosen = await settleContextMenu(openContextMenu(), 'Down,Return', 'chosen context menu')
    if (chosen.id !== 'open' || chosen.targetId !== 'row "1"')
      throw new Error('chosen context menu answered ' + JSON.stringify(chosen))
    await until(() => contextEvents.length === 2, 'craft:contextmenu:action did not fire for both menus')
    if (contextEvents[0].id !== null || contextEvents[1].id !== 'open')
      throw new Error('context menu events were ' + JSON.stringify(contextEvents))
    let refused = false
    try { await craft.nativeUI.showContextMenu({ items: [{ title: 'No id' }], x: 1, y: 1 }) }
    catch (_) { refused = true }
    if (!refused) throw new Error('a context menu item without an id was accepted')
    await report('context-menu')

    // ---- Message dialogs ---------------------------------------------------
    // Windows can press any button by position. On Linux the keyboard reaches
    // the default button (Return) and dismissal (Escape).
    const alert = within(craft.dialog.showAlert('Three choices.', { title: 'Smoke alert', style: 'warning', buttons: ['First', 'Second', 'Third'] }), 'alert never settled')
    const alertPick = isWindows ? 1 : 0
    const alertNative = await native('message-dialog', { choose: String(alertPick) })
    const alertResult = await alert
    if (alertResult.buttonIndex !== alertPick) throw new Error('alert answered ' + JSON.stringify(alertResult))
    if (isWindows && !['First', 'Second', 'Third'].every(label => alertNative.buttons.includes(label)))
      throw new Error('alert drew buttons ' + JSON.stringify(alertNative.buttons))

    const declined = within(craft.dialog.showConfirm('Proceed?', { title: 'Smoke confirm' }), 'confirm never settled')
    await native('message-dialog', { choose: 'dismiss' })
    if ((await declined).ok !== false) throw new Error('a dismissed confirm did not answer ok:false')
    const accepted = within(craft.dialog.showConfirm('Proceed?', { title: 'Smoke confirm' }), 'confirm never settled')
    await native('message-dialog', { choose: '0' })
    if ((await accepted).ok !== true) throw new Error('an accepted confirm did not answer ok:true')
    const plain = within(craft.dialog.showMessageBox({ message: 'Only a message.' }), 'message box never settled')
    await native('message-dialog', { choose: '0' })
    if ((await plain).buttonIndex !== 0) throw new Error('a default alert did not answer buttonIndex 0')
    await report('message-dialogs')

    // ---- File dialogs ------------------------------------------------------
    const cancelledOpen = within(craft.dialog.showOpenDialog({ title: 'Smoke open cancel' }), 'open dialog never settled')
    await native('file-dialog', { title: 'Smoke open cancel', action: 'cancel' })
    const cancelled = await cancelledOpen
    if (cancelled.canceled !== true || cancelled.filePaths.length !== 0)
      throw new Error('a cancelled open dialog answered ' + JSON.stringify(cancelled))

    const pickedOpen = within(craft.dialog.showOpenDialog({ title: 'Smoke open pick', defaultPath: pickDir }), 'open dialog never settled')
    await native('file-dialog', { title: 'Smoke open pick', action: 'accept', path: pickFile })
    const picked = await pickedOpen
    if (picked.canceled !== false || picked.filePaths.length !== 1 || !samePath(picked.filePaths[0], pickFile))
      throw new Error('a chosen file answered ' + JSON.stringify(picked))

    const many = within(craft.dialog.showOpenDialog({ title: 'Smoke open many', properties: ['multiSelections'], defaultPath: pickDir }), 'multi-select dialog never settled')
    await native('file-dialog', { title: 'Smoke open many', action: 'accept', path: pickFile })
    const manyResult = await many
    if (manyResult.canceled !== false || manyResult.filePaths.length !== 1 || !samePath(manyResult.filePaths[0], pickFile))
      throw new Error('a multi-select dialog answered ' + JSON.stringify(manyResult))

    const folder = within(craft.dialog.showOpenDialog({ title: 'Smoke folder', properties: ['openDirectory'], defaultPath: pickDir }), 'folder dialog never settled')
    await native('file-dialog', { title: 'Smoke folder', action: 'cancel' })
    const folderResult = await folder
    if (folderResult.canceled !== true || folderResult.filePaths.length !== 0)
      throw new Error('a cancelled folder dialog answered ' + JSON.stringify(folderResult))

    const cancelledSave = within(craft.dialog.showSaveDialog({ title: 'Smoke save cancel' }), 'save dialog never settled')
    await native('file-dialog', { title: 'Smoke save cancel', action: 'cancel' })
    const unsaved = await cancelledSave
    if (unsaved.canceled !== true || 'filePath' in unsaved) throw new Error('a cancelled save dialog answered ' + JSON.stringify(unsaved))

    // Accepted as offered: the folder and the name both come from the options.
    const save = within(craft.dialog.showSaveDialog({ title: 'Smoke save', defaultPath: pickDir, defaultName: saveName }), 'save dialog never settled')
    await native('file-dialog', { title: 'Smoke save', action: 'accept' })
    const saved = await save
    if (saved.canceled !== false || !samePath(saved.filePath, pickDir + (isWindows ? '\\\\' : '/') + saveName))
      throw new Error('an accepted save dialog answered ' + JSON.stringify(saved))
    await report('file-dialogs')

    // ---- File drop ---------------------------------------------------------
    const drops = []
    craft.onFileDrop(detail => drops.push(detail.paths))
    window.__craftDeliverFileDrop(['/tmp/contract'])
    if (drops.length !== 1 || drops[0][0] !== '/tmp/contract') throw new Error('craft.onFileDrop did not receive a native delivery')
    if (!isWindows) {
      // A real drag from another application, through the X server.
      await native('drag-file')
      await until(() => drops.length === 2, 'a file dragged onto the window never reached craft.onFileDrop', 15000)
      if (drops[1].length !== 1 || drops[1][0] !== dropFile) throw new Error('the dropped file arrived as ' + JSON.stringify(drops[1]))
    }
    await report('file-drop')

    // ---- Single instance ---------------------------------------------------
    const launches = []
    const links = []
    craft.app.onSecondInstance(detail => launches.push(detail))
    craft.deepLink.onUrl(detail => links.push(detail.url))
    const second = await native('second-launch')
    if (second.code !== 0) throw new Error('the second launch exited with ' + second.code + ': ' + second.output)
    await until(() => launches.length === 1, 'the running instance was never told about the second launch')
    const launch = launches[0]
    if (JSON.stringify(launch.args) !== JSON.stringify(['alpha', 'two words', '--looks-like-a-flag']) || launch.url !== deepLink)
      throw new Error('the second launch arrived as ' + JSON.stringify(launch))
    if (links.length !== 1 || links[0] !== deepLink) throw new Error('the second launch link reached craft.deepLink as ' + JSON.stringify(links))
    if ((await native('window-count')).count !== 1) throw new Error('the second launch opened its own window')
    await report('single-instance')

    // ---- Menu teardown, then relaunch --------------------------------------
    await craft.menu.set({ menus: [] })
    await until(() => window.innerHeight > heightWithMenu + 10, 'clearing the menu left the bar in place')
    await report('menu-cleared')

    document.getElementById('status').textContent = 'relaunching'
    await report('relaunch-requested')
    await craft.app.relaunch()
  }
  catch (error) {
    document.getElementById('status').textContent = String(error?.message ?? error)
    await fetch('/report?error=' + encodeURIComponent(String(error?.message ?? JSON.stringify(error))), { method: 'POST' })
  }
})()
</script>`

// ---------------------------------------------------------------------------
// Linux: xdotool and wmctrl
// ---------------------------------------------------------------------------

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))

function x11(args: string[]): string {
  return execFileSync(args[0]!, args.slice(1), { encoding: 'utf8', timeout: 15_000 })
}

/** Managed top-level windows, as the window manager lists them. */
function linuxWindows(): Array<{ id: string, title: string }> {
  return x11(['wmctrl', '-l']).split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^(0x[0-9a-f]+)\s+\S+\s+\S+\s?(.*)$/i)
    return match ? [{ id: match[1]!, title: match[2]! }] : []
  })
}

let linuxMainWindow = ''
async function linuxWaitFor(find: () => string | undefined, what: string): Promise<string> {
  for (let attempt = 0; attempt < 150; attempt++) {
    const id = find()
    if (id) return id
    await sleep(100)
  }
  throw new Error(`${what}: ${JSON.stringify(linuxWindows())}`)
}

async function linuxMain(): Promise<string> {
  if (!linuxMainWindow)
    linuxMainWindow = await linuxWaitFor(() => linuxWindows().find(window => window.title === windowTitle)?.id, 'the Craft window never appeared')
  return linuxMainWindow
}

async function linuxActivate(id: string): Promise<void> {
  x11(['xdotool', 'windowactivate', '--sync', id])
  await sleep(150)
}

function linuxGeometry(id: string): { x: number, y: number, width: number, height: number } {
  const shell = x11(['xdotool', 'getwindowgeometry', '--shell', id])
  const value = (name: string) => Number(shell.match(new RegExp(`^${name}=(-?\\d+)$`, 'm'))?.[1])
  return { x: value('X'), y: value('Y'), width: value('WIDTH'), height: value('HEIGHT') }
}

let dragSource: ChildProcess | undefined
const dragSourceTitle = 'Craft drag source'
const dragSourceScript = `
import sys
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk
uri = sys.argv[1]
window = Gtk.Window(title=sys.argv[2])
window.set_default_size(180, 140)
window.move(820, 60)
box = Gtk.EventBox()
box.add(Gtk.Label(label='drag me'))
window.add(box)
box.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
box.drag_source_add_uri_targets()
box.connect('drag-data-get', lambda widget, context, data, info, time: data.set_uris([uri]))
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
`

async function linuxDragFile(): Promise<void> {
  const scriptPath = join(workDir, 'drag-source.py')
  writeFileSync(scriptPath, dragSourceScript)
  dragSource = spawn('python3', [scriptPath, `file://${encodeURI(dropFile)}`, dragSourceTitle], { stdio: ['ignore', 'inherit', 'inherit'] })
  const sourceId = await linuxWaitFor(() => linuxWindows().find(window => window.title === dragSourceTitle)?.id, 'the drag source window never appeared')
  const main = await linuxMain()
  const from = linuxGeometry(sourceId)
  const to = linuxGeometry(main)
  const start = { x: from.x + Math.round(from.width / 2), y: from.y + Math.round(from.height / 2) }
  const end = { x: to.x + Math.round(to.width / 2), y: to.y + Math.round(to.height / 2) }
  x11(['xdotool', 'mousemove', String(start.x), String(start.y)])
  await sleep(200)
  x11(['xdotool', 'mousedown', '1'])
  // Past GTK's drag threshold first, then across in steps: a drop target
  // only learns of a drag from the motion it sees while the button is held.
  for (let step = 1; step <= 6; step++) {
    x11(['xdotool', 'mousemove_relative', '--', '-6', '4'])
    await sleep(60)
  }
  for (let step = 1; step <= 12; step++) {
    const x = Math.round(start.x + (end.x - start.x) * step / 12)
    const y = Math.round(start.y + (end.y - start.y) * step / 12)
    x11(['xdotool', 'mousemove', String(x), String(y)])
    await sleep(80)
  }
  x11(['xdotool', 'mousemove_relative', '--', '3', '3'])
  await sleep(400)
  x11(['xdotool', 'mouseup', '1'])
}

/** `ctrl+shift+z` as xdotool spells it. */
function linuxKeys(keys: string): string[] {
  return keys.split(',').map(key => key.trim()).filter(Boolean)
}

async function linuxNative(op: string, params: URLSearchParams): Promise<unknown> {
  const main = await linuxMain()
  switch (op) {
    case 'activate':
      await linuxActivate(main)
      return {}
    case 'click-page': {
      await linuxActivate(main)
      const geometry = linuxGeometry(main)
      x11(['xdotool', 'mousemove', String(geometry.x + Math.round(geometry.width / 2)), String(geometry.y + Math.round(geometry.height * 0.75)), 'click', '1'])
      await sleep(200)
      return {}
    }
    case 'accelerator':
      await linuxActivate(main)
      x11(['xdotool', 'key', '--clearmodifiers', '--delay', '60', ...linuxKeys(params.get('keys') ?? '')])
      return {}
    case 'popup-keys':
      // No window to name: a popup menu holds the keyboard while it is open.
      x11(['xdotool', 'key', '--delay', '120', ...linuxKeys(params.get('keys') ?? '')])
      return {}
    case 'menu-state':
      return { menus: null }
    case 'message-dialog': {
      // GTK gives the dialog its parent's title, so it is the other window
      // carrying that name.
      const dialog = await linuxWaitFor(() => linuxWindows().find(window => window.title === windowTitle && window.id !== main)?.id, 'the message dialog never appeared')
      await linuxActivate(dialog)
      const choose = params.get('choose')
      if (choose !== 'dismiss' && choose !== '0') throw new Error('only the default button and dismissal are reachable by keyboard here')
      x11(['xdotool', 'key', '--delay', '60', choose === 'dismiss' ? 'Escape' : 'Return'])
      await linuxWaitFor(() => linuxWindows().some(window => window.id === dialog) ? undefined : 'gone', 'the message dialog never closed')
      return { buttons: null }
    }
    case 'file-dialog': {
      const title = params.get('title')!
      const dialog = await linuxWaitFor(() => linuxWindows().find(window => window.title === title)?.id, `the "${title}" dialog never appeared`)
      await linuxActivate(dialog)
      await sleep(400)
      if (params.get('action') === 'cancel') {
        x11(['xdotool', 'key', 'Escape'])
      }
      else {
        const path = params.get('path')
        if (path) {
          // Typing a path opens GTK's location entry and fills it.
          x11(['xdotool', 'type', '--delay', '25', path])
          await sleep(500)
        }
        x11(['xdotool', 'key', '--delay', '60', 'Return'])
      }
      await linuxWaitFor(() => linuxWindows().some(window => window.id === dialog) ? undefined : 'gone', `the "${title}" dialog never closed`)
      return {}
    }
    case 'window-count':
      return { count: linuxWindows().filter(window => window.title === windowTitle).length }
    case 'drag-file':
      await linuxDragFile()
      return {}
    default:
      throw new Error(`unknown native operation ${op}`)
  }
}

// ---------------------------------------------------------------------------
// Windows: one PowerShell that compiles a Win32 probe and answers requests
// ---------------------------------------------------------------------------

const windowsProbeScript = `
$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public sealed class CraftTopWindow {
  public long handle { get; set; }
  public string title { get; set; }
  public string className { get; set; }
  public bool visible { get; set; }
}
public sealed class CraftMenuItem {
  public string text { get; set; }
  public uint id { get; set; }
  public bool @checked { get; set; }
  public bool grayed { get; set; }
}
public sealed class CraftMenu {
  public string label { get; set; }
  public CraftMenuItem[] items { get; set; }
}
public static class CraftBridgeProbe {
  public delegate bool EnumProc(IntPtr window, IntPtr state);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr state);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int capacity);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr window);
  [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
  [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr menu, int position);
  [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu, int position);
  [DllImport("user32.dll")] static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuStringW(IntPtr menu, uint item, StringBuilder text, int capacity, uint flags);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SendMessageTimeoutPlain(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref POINT point);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }

  const uint WM_SETTEXT = 0x000C, WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_COMMAND = 0x0111;
  const uint MF_BYPOSITION = 0x400, MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_SEPARATOR = 0x800;

  static string Text(IntPtr window) { var text = new StringBuilder(512); GetWindowText(window, text, text.Capacity); return text.ToString(); }
  static string Class(IntPtr window) { var text = new StringBuilder(256); GetClassName(window, text, text.Capacity); return text.ToString(); }

  public static CraftTopWindow[] Windows(uint processId) {
    var rows = new List<CraftTopWindow>();
    EnumWindows(delegate(IntPtr window, IntPtr state) {
      uint owner; GetWindowThreadProcessId(window, out owner);
      if (owner == processId) rows.Add(new CraftTopWindow { handle = window.ToInt64(), title = Text(window), className = Class(window), visible = IsWindowVisible(window) });
      return true;
    }, IntPtr.Zero);
    return rows.ToArray();
  }

  public static CraftMenu[] MenuState(long window) {
    var menus = new List<CraftMenu>();
    var bar = GetMenu(new IntPtr(window));
    if (bar == IntPtr.Zero) return menus.ToArray();
    for (int position = 0; position < GetMenuItemCount(bar); position++) {
      var label = new StringBuilder(256);
      GetMenuStringW(bar, (uint)position, label, label.Capacity, MF_BYPOSITION);
      var popup = GetSubMenu(bar, position);
      var items = new List<CraftMenuItem>();
      for (int index = 0; popup != IntPtr.Zero && index < GetMenuItemCount(popup); index++) {
        var text = new StringBuilder(256);
        GetMenuStringW(popup, (uint)index, text, text.Capacity, MF_BYPOSITION);
        uint state = GetMenuState(popup, (uint)index, MF_BYPOSITION);
        items.Add(new CraftMenuItem {
          text = (state & MF_SEPARATOR) != 0 ? "" : text.ToString(), id = GetMenuItemID(popup, index),
          @checked = (state & MF_CHECKED) != 0, grayed = (state & MF_GRAYED) != 0
        });
      }
      menus.Add(new CraftMenu { label = label.ToString(), items = items.ToArray() });
    }
    return menus.ToArray();
  }

  public static bool MenuCommand(long window, int menu, int item) {
    var bar = GetMenu(new IntPtr(window));
    if (bar == IntPtr.Zero) return false;
    var popup = GetSubMenu(bar, menu);
    if (popup == IntPtr.Zero) return false;
    uint id = GetMenuItemID(popup, item);
    if (id == 0xFFFFFFFF) return false;
    return PostMessageW(new IntPtr(window), WM_COMMAND, new IntPtr(id), IntPtr.Zero);
  }

  public static void PostKey(long window, int key) {
    PostMessageW(new IntPtr(window), WM_KEYDOWN, new IntPtr(key), IntPtr.Zero);
    PostMessageW(new IntPtr(window), WM_KEYUP, new IntPtr(key), new IntPtr(unchecked((int)0xC0000001)));
  }

  public static bool Foreground(long window) {
    var target = new IntPtr(window);
    if (GetForegroundWindow() == target) return true;
    SetForegroundWindow(target);
    if (GetForegroundWindow() == target) return true;
    // Windows refuses a foreground change from a process that has had no
    // input. A tap of Alt counts as input. Only done when the target is not
    // already in front: tapped there, Alt would open its menu bar instead.
    keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
    SetForegroundWindow(target);
    return GetForegroundWindow() == target;
  }

  public static void Chord(bool control, bool shift, bool alt, int key) {
    if (control) keybd_event(0x11, 0, 0, UIntPtr.Zero);
    if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
    if (alt) keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event((byte)key, 0, 0, UIntPtr.Zero);
    keybd_event((byte)key, 0, 2, UIntPtr.Zero);
    if (alt) keybd_event(0x12, 0, 2, UIntPtr.Zero);
    if (shift) keybd_event(0x10, 0, 2, UIntPtr.Zero);
    if (control) keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }

  public static void ClickClient(long window) {
    RECT rect; GetClientRect(new IntPtr(window), out rect);
    var point = new POINT { x = rect.right / 2, y = rect.bottom * 3 / 4 };
    ClientToScreen(new IntPtr(window), ref point);
    SetCursorPos(point.x, point.y);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }

  static List<IntPtr> Descendants(long window, string className) {
    var found = new List<IntPtr>();
    EnumChildWindows(new IntPtr(window), delegate(IntPtr child, IntPtr state) {
      if (Class(child) == className) found.Add(child);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string[] Buttons(long dialog) {
    var texts = new List<string>();
    foreach (var button in Descendants(dialog, "Button")) if (IsWindowVisible(button)) texts.Add(Text(button));
    return texts.ToArray();
  }

  public static void TaskDialogClick(long dialog, int id) {
    IntPtr result;
    // TDM_CLICK_BUTTON
    SendMessageTimeoutPlain(new IntPtr(dialog), 0x0466, new IntPtr(id), IntPtr.Zero, 0x0002, 5000, out result);
  }

  public static void DialogCommand(long dialog, int id) {
    PostMessageW(new IntPtr(dialog), WM_COMMAND, new IntPtr(id), IntPtr.Zero);
  }

  public static int SetEdit(long dialog, string text) {
    // The file name field of an open dialog is the edit inside its
    // ComboBoxEx32. Prefer it to any other edit the dialog happens to hold.
    var edits = new List<IntPtr>();
    foreach (var combo in Descendants(dialog, "ComboBoxEx32")) edits.AddRange(Descendants(combo.ToInt64(), "Edit"));
    edits.AddRange(Descendants(dialog, "Edit"));
    foreach (var edit in edits) {
      if (!IsWindowVisible(edit)) continue;
      IntPtr result;
      SendMessageTimeoutW(edit, WM_SETTEXT, IntPtr.Zero, text, 0x0002, 5000, out result);
      return 1;
    }
    return 0;
  }
}
'@
Add-Type -TypeDefinition $signature
[Console]::Out.WriteLine('ready')
[Console]::Out.Flush()
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    $request = $line | ConvertFrom-Json
    $result = switch ($request.op) {
      'windows' { ,@([CraftBridgeProbe]::Windows([uint32]$request.pid)) }
      'menu-state' { ,@([CraftBridgeProbe]::MenuState([long]$request.window)) }
      'menu-command' { [CraftBridgeProbe]::MenuCommand([long]$request.window, [int]$request.menu, [int]$request.item) }
      'post-key' { [CraftBridgeProbe]::PostKey([long]$request.window, [int]$request.key); $true }
      'foreground' { [CraftBridgeProbe]::Foreground([long]$request.window) }
      'chord' { [CraftBridgeProbe]::Chord([bool]$request.control, [bool]$request.shift, [bool]$request.alt, [int]$request.key); $true }
      'click-client' { [CraftBridgeProbe]::ClickClient([long]$request.window); $true }
      'buttons' { ,@([CraftBridgeProbe]::Buttons([long]$request.window)) }
      'task-click' { [CraftBridgeProbe]::TaskDialogClick([long]$request.window, [int]$request.id); $true }
      'dialog-command' { [CraftBridgeProbe]::DialogCommand([long]$request.window, [int]$request.id); $true }
      'set-edit' { [CraftBridgeProbe]::SetEdit([long]$request.window, [string]$request.text) }
      default { throw "unknown probe operation $($request.op)" }
    }
    [Console]::Out.WriteLine((@{ ok = $true; result = $result } | ConvertTo-Json -Compress -Depth 6))
  }
  catch {
    [Console]::Out.WriteLine((@{ ok = $false; error = [string]$_ } | ConvertTo-Json -Compress))
  }
  [Console]::Out.Flush()
}
`

let probe: ChildProcess | undefined
let probeErrors = ''
const probeLines: string[] = []
const probeWaiters: Array<{ resolve: (line: string) => void, reject: (error: Error) => void }> = []
function nextProbeLine(timeoutMs: number, what: string): Promise<string> {
  const queued = probeLines.shift()
  if (queued !== undefined) return Promise.resolve(queued)
  return new Promise((resolve, reject) => {
    const waiter = {
      resolve: (line: string) => { clearTimeout(timer); resolve(line) },
      reject: (error: Error) => { clearTimeout(timer); reject(error) },
    }
    const timer = setTimeout(() => {
      probeWaiters.splice(probeWaiters.indexOf(waiter), 1)
      reject(new Error(`${what} timed out after ${timeoutMs} ms: ${probeErrors.slice(-2000)}`))
    }, timeoutMs)
    probeWaiters.push(waiter)
  })
}

async function startProbe(): Promise<void> {
  probe = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', windowsProbeScript], { stdio: ['pipe', 'pipe', 'pipe'] })
  let partial = ''
  probe.stdout!.on('data', (chunk) => {
    partial += chunk.toString()
    let newline = partial.indexOf('\n')
    while (newline >= 0) {
      const line = partial.slice(0, newline).trim()
      partial = partial.slice(newline + 1)
      if (line) {
        const waiter = probeWaiters.shift()
        if (waiter) waiter.resolve(line)
        else probeLines.push(line)
      }
      newline = partial.indexOf('\n')
    }
  })
  probe.stderr!.on('data', (chunk) => { probeErrors = (probeErrors + chunk.toString()).slice(-8000) })
  probe.once('exit', (code) => {
    const error = new Error(`Win32 probe exited (${code}): ${probeErrors.slice(-2000)}`)
    for (const waiter of probeWaiters.splice(0)) waiter.reject(error)
  })
  // Compiling the probe takes seconds on a cold runner.
  const ready = await nextProbeLine(120_000, 'compiling the Win32 probe')
  if (ready !== 'ready') throw new Error(`Win32 probe did not start: ${ready}`)
}

let probeQueue: Promise<unknown> = Promise.resolve()
function win32<T = unknown>(request: Record<string, unknown>): Promise<T> {
  const call = probeQueue.then(async () => {
    if (!probe || probe.exitCode !== null) throw new Error('Win32 probe is not running')
    probe.stdin!.write(`${JSON.stringify(request)}\n`)
    const answer = JSON.parse(await nextProbeLine(20_000, `Win32 probe ${String(request.op)}`)) as { ok: boolean, result?: T, error?: string }
    if (!answer.ok) throw new Error(answer.error ?? 'Win32 probe failed')
    return answer.result as T
  })
  probeQueue = call.catch(() => {})
  return call
}

interface TopWindow { handle: number, title: string, className: string, visible: boolean }
async function windowsTop(): Promise<TopWindow[]> {
  if (!child.pid) throw new Error('Craft is not running')
  const rows = await win32<TopWindow[] | TopWindow | null>({ op: 'windows', pid: child.pid })
  return rows == null ? [] : Array.isArray(rows) ? rows : [rows]
}

async function windowsWaitFor(match: (window: TopWindow) => boolean, what: string): Promise<TopWindow> {
  for (let attempt = 0; attempt < 150; attempt++) {
    const found = (await windowsTop()).find(window => window.visible && match(window))
    if (found) return found
    await sleep(100)
  }
  throw new Error(`${what}: ${JSON.stringify(await windowsTop())}`)
}

const windowsMain = () => windowsWaitFor(window => window.className === 'ZyteWindow' && window.title === windowTitle, 'the Craft window never appeared')
const windowsDialog = (title?: string) => windowsWaitFor(
  window => window.className === '#32770' && (title === undefined || window.title === title),
  title ? `the "${title}" dialog never appeared` : 'the dialog never appeared',
)

async function windowsDialogGone(handle: number, what: string): Promise<void> {
  for (let attempt = 0; attempt < 150; attempt++) {
    if (!(await windowsTop()).some(window => window.handle === handle && window.visible)) return
    await sleep(100)
  }
  throw new Error(what)
}

const virtualKeys: Record<string, number> = { escape: 0x1B, return: 0x0D, down: 0x28, up: 0x26, comma: 0xBC }
function windowsChord(keys: string): { control: boolean, shift: boolean, alt: boolean, key: number } {
  const parts = keys.toLowerCase().split('+')
  const name = parts.pop()!
  const key = virtualKeys[name] ?? (name.length === 1 ? name.toUpperCase().charCodeAt(0) : Number.NaN)
  if (!Number.isFinite(key)) throw new Error(`no virtual key for ${name}`)
  return { control: parts.includes('ctrl'), shift: parts.includes('shift'), alt: parts.includes('alt'), key }
}

async function windowsNative(op: string, params: URLSearchParams): Promise<unknown> {
  const main = await windowsMain()
  switch (op) {
    case 'activate':
      return { foreground: await win32({ op: 'foreground', window: main.handle }) }
    case 'click-page':
      await win32({ op: 'foreground', window: main.handle })
      await win32({ op: 'click-client', window: main.handle })
      await sleep(300)
      return {}
    case 'accelerator':
      await win32({ op: 'foreground', window: main.handle })
      await win32({ op: 'chord', ...windowsChord(params.get('keys') ?? '') })
      return {}
    case 'popup-keys':
      // A popup menu runs its own loop on the window's thread and reads key
      // messages posted to it.
      for (const key of (params.get('keys') ?? '').split(',')) {
        await win32({ op: 'post-key', window: main.handle, key: windowsChord(key).key })
        await sleep(120)
      }
      return {}
    case 'menu-state': {
      const menus = await win32<unknown>({ op: 'menu-state', window: main.handle })
      const list = (menus == null ? [] : Array.isArray(menus) ? menus : [menus]) as Array<{ label: string, items: unknown }>
      return { menus: list.map(menu => ({ label: menu.label, items: menu.items == null ? [] : Array.isArray(menu.items) ? menu.items : [menu.items] })) }
    }
    case 'menu-command': {
      const posted = await win32<boolean>({ op: 'menu-command', window: main.handle, menu: Number(params.get('menu')), item: Number(params.get('item')) })
      if (!posted) throw new Error('the menu bar has no such item')
      return {}
    }
    case 'message-dialog': {
      const dialog = await windowsDialog()
      await sleep(200)
      const raw = await win32<string[] | string | null>({ op: 'buttons', window: dialog.handle })
      const buttons = raw == null ? [] : Array.isArray(raw) ? raw : [raw]
      const choose = params.get('choose')
      // A task dialog that allows cancellation accepts a click on IDCANCEL.
      // Its own buttons are numbered from 100 (windows_desktop.zig).
      await win32({ op: 'task-click', window: dialog.handle, id: choose === 'dismiss' ? 2 : 100 + Number(choose) })
      await windowsDialogGone(dialog.handle, 'the message dialog never closed: it is not a task dialog, or its button ids changed')
      return { buttons }
    }
    case 'file-dialog': {
      const title = params.get('title')!
      const dialog = await windowsDialog(title)
      await sleep(500)
      if (params.get('action') === 'cancel') {
        await win32({ op: 'dialog-command', window: dialog.handle, id: 2 })
      }
      else {
        const path = params.get('path')
        if (path && await win32<number>({ op: 'set-edit', window: dialog.handle, text: path }) !== 1)
          throw new Error(`the "${title}" dialog has no file name field`)
        await sleep(200)
        await win32({ op: 'dialog-command', window: dialog.handle, id: 1 })
      }
      await windowsDialogGone(dialog.handle, `the "${title}" dialog never closed`)
      return {}
    }
    case 'window-count':
      return { count: (await windowsTop()).filter(window => window.visible && window.className === 'ZyteWindow').length }
    default:
      throw new Error(`unknown native operation ${op}`)
  }
}

// ---------------------------------------------------------------------------
// Second launch, relaunch marker, server
// ---------------------------------------------------------------------------

function secondLaunch(url: string): Promise<{ code: number | null, output: string }> {
  return new Promise((resolve) => {
    const second = spawn(binary!, [
      '--url', url, '--title', windowTitle,
      '--single-instance', instanceId,
      '--instance-arg', 'alpha', '--instance-arg', 'two words', '--instance-arg', '--looks-like-a-flag',
      '--deep-link', deepLink,
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    second.stdout.on('data', (chunk) => { output = (output + chunk.toString()).slice(-4000) })
    second.stderr.on('data', (chunk) => { output = (output + chunk.toString()).slice(-4000) })
    const timer = setTimeout(() => {
      second.kill()
      resolve({ code: null, output: `still running after 20 s, so it did not hand off: ${output}` })
    }, 20_000)
    second.once('error', (error) => { clearTimeout(timer); resolve({ code: null, output: String(error) }) })
    second.once('exit', (code) => { clearTimeout(timer); resolve({ code, output }) })
  })
}

const steps = new Set<string>()
const requiredSteps = ['surface', 'menu', 'context-menu', 'message-dialogs', 'file-dialogs', 'file-drop', 'single-instance', 'menu-cleared', 'relaunch-requested']
let relaunchRequested = false
let relaunchedFromPid: string | null = null
let craftExit: { code: number | null, signal: NodeJS.Signals | null } | null = null
let resolveDone!: () => void
let rejectDone!: (error: Error) => void
const done = new Promise<void>((resolve, reject) => {
  resolveDone = resolve
  rejectDone = reject
})

function checkFinished(): void {
  if (!relaunchRequested || relaunchedFromPid === null || craftExit === null) return
  const missing = requiredSteps.filter(step => !steps.has(step))
  if (missing.length > 0) return rejectDone(new Error(`incomplete smoke steps, missing: ${missing.join(', ')}`))
  if (relaunchedFromPid !== String(child.pid))
    return rejectDone(new Error(`the relaunch named process ${relaunchedFromPid}, but Craft was ${child.pid}`))
  if (craftExit.code !== 0)
    return rejectDone(new Error(`Craft exited with ${craftExit.code ?? craftExit.signal} after relaunching`))
  resolveDone()
}

const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1')
  if (url.pathname === '/main') {
    response.setHeader('content-type', 'text/html; charset=utf-8')
    response.end(mainPage)
  }
  else if (url.pathname === '/report') {
    const error = url.searchParams.get('error')
    const step = url.searchParams.get('step')
    if (error) rejectDone(new Error(error))
    if (step) {
      steps.add(step)
      console.log(`  ${platformName} bridge smoke: ${step}`)
      if (step === 'relaunch-requested') relaunchRequested = true
    }
    response.end('ok')
  }
  else if (url.pathname === '/relaunched') {
    relaunchedFromPid = url.searchParams.get('pid')
    response.end('ok')
    checkFinished()
  }
  else if (url.pathname === '/native') {
    const op = url.searchParams.get('op') ?? ''
    const run = op === 'second-launch'
      ? secondLaunch(`http://127.0.0.1:${port}/main`)
      : isWindows ? windowsNative(op, url.searchParams) : linuxNative(op, url.searchParams)
    run.then((result) => {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify(result ?? {}))
    }, (error) => {
      response.writeHead(500, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ error: String(error?.message ?? error) }))
    })
  }
  else {
    response.writeHead(404).end()
  }
})

await new Promise<void>((resolve, reject) => {
  server.once('error', reject)
  server.listen(0, '127.0.0.1', resolve)
})
const port = (server.address() as AddressInfo).port
if (isWindows) await startProbe()

// What `craft.app.relaunch()` starts in place of Craft itself: a launcher that
// reports it was run, and for which process.
const markerScript = join(workDir, 'relaunch-marker.ts')
writeFileSync(markerScript, 'await fetch(`http://127.0.0.1:${process.argv[2]}/relaunched?pid=${process.argv[3]}`, { method: \'POST\' })\n')

const startedAt = Date.now()
const child = spawn(binary, [
  '--url', `http://127.0.0.1:${port}/main`,
  '--title', windowTitle,
  '--width', '640', '--height', '520', '--x', '60', '--y', '60',
  '--single-instance', instanceId,
], {
  env: {
    ...process.env,
    CRAFT_RELAUNCH_EXECUTABLE: process.execPath,
    CRAFT_RELAUNCH_ARGS: JSON.stringify([markerScript, String(port), '{pid}']),
  },
  stdio: ['ignore', 'pipe', 'pipe'],
})
let output = ''
child.stdout.on('data', (chunk) => { output = (output + chunk.toString()).slice(-16_000) })
child.stderr.on('data', (chunk) => { output = (output + chunk.toString()).slice(-16_000) })
child.once('error', error => rejectDone(error))
child.once('exit', (code, signal) => {
  craftExit = { code, signal }
  if (!relaunchRequested)
    return rejectDone(new Error(`Craft exited before the smoke completed (${code ?? signal}, ${Date.now() - startedAt} ms)`))
  checkFinished()
  // The launcher is started before Craft quits; give its report a moment.
  setTimeout(() => {
    if (relaunchedFromPid === null) rejectDone(new Error('Craft quit, but the relaunch command it was given never ran'))
  }, 15_000)
})
const timer = setTimeout(() => rejectDone(new Error(`${platformName} bridge smoke timed out`)), 240_000)

try {
  await done
  console.log(`${platformName} bridge smoke passed: ${[...steps].join(', ')}, relaunched`)
}
catch (error) {
  throw new Error(`${String(error)}\nElapsed: ${Date.now() - startedAt} ms\nSteps reached: ${[...steps].join(', ')}\nCraft output:\n${output}`)
}
finally {
  clearTimeout(timer)
  if (child.exitCode === null) child.kill()
  dragSource?.kill()
  probe?.stdin?.end()
  probe?.kill()
  await new Promise<void>(resolve => server.close(() => resolve()))
  rmSync(workDir, { recursive: true, force: true })
}
// Timers for a failure that never came would otherwise hold the process open.
process.exit(0)

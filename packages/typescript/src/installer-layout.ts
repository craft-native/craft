/*
 * Format implementation adapted from MIT-licensed references:
 * Copyright (c) 2020 Kenty Gwend
 * Copyright (c) 2026 John Campion Jr
 * Copyright (c) 2014 Alastair Houghton
 * Copyright (c) 2022 Russell Keith-Magee
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
/**
 * Minimal Finder store writer for installer volumes, with one B-tree leaf.
 * Format references: https://github.com/gwend/dsstore (MIT, Kenty Gwend)
 * and https://github.com/al45tair/mac_alias (MIT, Alastair Houghton).
 * This writes the layout without launching Finder or requiring Automation access.
 */
import { execFileSync } from 'node:child_process'
import { statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const number = (value: number, bytes = 4) => {
  const out = Buffer.alloc(bytes)
  out.writeUIntBE(value, 0, bytes)
  return out
}
const unicode = (value: string) => Buffer.from(value, 'utf16le').swap16()
const pascal = (value: string, size: number) => {
  const out = Buffer.alloc(size)
  const bytes = Buffer.from(value).subarray(0, size - 1)
  out[0] = bytes.length
  bytes.copy(out, 1)
  return out
}
const tag = (id: number, data: Buffer) => Buffer.concat([number(id, 2), number(data.length, 2), data, Buffer.alloc(data.length % 2)])

function backgroundAlias(mount: string, volume: string): Buffer {
  const folder = '.background'
  const filename = 'installer.png'
  const directory = statSync(join(mount, folder))
  const file = statSync(join(mount, folder, filename))
  const date = (ms: number) => Math.floor(ms / 1000) + 2082844800
  const volumeDate = date(statSync(mount).birthtimeMs)
  const fileDate = date(file.birthtimeMs)
  const preciseDate = (value: number) => {
    const out = Buffer.alloc(8)
    out.writeBigUInt64BE(BigInt(value) * 65536n)
    return out
  }
  const body = Buffer.concat([
    number(0, 2), pascal(volume, 28), number(volumeDate), Buffer.from('H+'), number(0, 2),
    number(directory.ino), pascal(filename, 64), number(file.ino), number(fileDate), Buffer.alloc(8),
    number(65535, 2), number(65535, 2), Buffer.alloc(16),
    tag(0, Buffer.from(folder)), tag(16, preciseDate(volumeDate)), tag(17, preciseDate(fileDate)), tag(1, number(directory.ino)),
    tag(2, Buffer.from(`${volume}:${folder}:\0${filename}`)),
    tag(14, Buffer.concat([number(filename.length, 2), unicode(filename)])),
    tag(15, Buffer.concat([number(volume.length, 2), unicode(volume)])),
    tag(18, Buffer.from(`/${folder}/${filename}`)), tag(19, Buffer.from(`/Volumes/${volume}`)),
    number(65535, 2), number(0, 2),
  ])
  return Buffer.concat([Buffer.alloc(4), number(body.length + 8, 2), number(2, 2), body])
}

function plist(values: Record<string, string | number | boolean | Buffer>): Buffer {
  const escape = (value: string) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
  const entries = Object.entries(values).map(([key, value]) => {
    const data = Buffer.isBuffer(value) ? `<data>${value.toString('base64')}</data>`
      : typeof value === 'boolean' ? `<${value}/>` : typeof value === 'number' ? (['viewOptionsVersion', 'backgroundType'].includes(key) ? `<integer>${value}</integer>` : `<real>${value}</real>`) : `<string>${escape(value)}</string>`
    return `<key>${key}</key>${data}`
  }).join('')
  return execFileSync('plutil', ['-convert', 'binary1', '-o', '-', '-'], { input: `<?xml version="1.0"?><plist version="1.0"><dict>${entries}</dict></plist>` })
}

export function writeInstallerLayout(mount: string, volume: string, appName: string): void {
  const records: Array<{ name: string, code: string, type: string, data: Buffer }> = []
  const blob = (name: string, code: string, data: Buffer) => records.push({ name, code, type: 'blob', data: Buffer.concat([number(data.length), data]) })
  blob('.', 'bwsp', plist({ ShowStatusBar: false, ShowToolbar: false, ShowTabView: false, ShowSidebar: false, ContainerShowSidebar: false, ShowPathbar: false, SidebarWidth: 0, PreviewPaneVisibility: false, WindowBounds: '{{100, 100}, {660, 460}}' }))
  blob('.', 'icvp', plist({ viewOptionsVersion: 1, backgroundType: 2, backgroundColorRed: 1, backgroundColorGreen: 1, backgroundColorBlue: 1, backgroundImageAlias: backgroundAlias(mount, volume), iconSize: 96, arrangeBy: 'none', gridSpacing: 100, gridOffsetX: 0, gridOffsetY: 0, scrollPositionX: 0, scrollPositionY: 0, textSize: 13, labelOnBottom: true, showIconPreview: true, showItemInfo: false }))
  records.push({ name: '.', code: 'vSrn', type: 'long', data: number(1) })
  records.push({ name: '.', code: 'icvl', type: 'type', data: Buffer.from('icnv') })
  records.push({ name: '.', code: 'vstl', type: 'type', data: Buffer.from('icnv') })
  for (const [name, x, y] of [[appName, 160, 190], ['Applications', 500, 190], ['.background', 500, 600]] as const)
    blob(name, 'Iloc', Buffer.concat([number(x), number(y), Buffer.from('ffffffffffff0000', 'hex')]))
  records.sort((a, b) => {
    const left = a.name.normalize('NFD').toLowerCase()
    const right = b.name.normalize('NFD').toLowerCase()
    return left < right ? -1 : left > right ? 1 : a.code < b.code ? -1 : 1
  })
  const leaf = Buffer.concat([number(0), number(records.length), ...records.map(record => {
    const name = record.name.normalize('NFD')
    return Buffer.concat([number(name.length), unicode(name), Buffer.from(record.code + record.type), record.data])
  })])
  if (leaf.length > 4096) throw new Error('Installer layout exceeds the Finder store leaf capacity')
  // Allocated buddy blocks: tree descriptor at 32, allocator at 2048, leaf at 4096.
  const offsets = Buffer.alloc(1024)
  offsets.writeUInt32BE(2048 | 11, 0)
  offsets.writeUInt32BE(32 | 5, 4)
  offsets.writeUInt32BE(4096 | 12, 8)
  const free = Array.from({ length: 32 }, (_, power) => power >= 6 && power <= 10 || power >= 13 && power <= 30
    ? Buffer.concat([number(1), number(2 ** power)]) : number(0))
  const root = Buffer.concat([number(3), number(0), offsets, number(1), Buffer.from([4]), Buffer.from('DSDB'), number(1), ...free])
  const out = Buffer.alloc(8196)
  Buffer.concat([number(1), Buffer.from('Bud1'), number(2048), number(root.length), number(2048), Buffer.alloc(16)]).copy(out)
  Buffer.concat([number(2), number(0), number(records.length), number(1), number(4096)]).copy(out, 36)
  root.copy(out, 2052)
  leaf.copy(out, 4100)
  writeFileSync(join(mount, '.DS_Store'), out)
}

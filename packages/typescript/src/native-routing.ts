/** Constraints on decoded named path parameters; query items cannot override them. */
export interface NativeParameterConstraint {
  /** A case-sensitive regular expression for the complete normalized value. */
  pattern?: string
  exclude?: readonly string[]
  /** Normalize decoded values and exclusions before case-sensitive grammar validation. */
  normalize?: 'lowercase'
}

export type NativeRouteConstraints = Record<string, Record<string, NativeParameterConstraint>>

/** Validate and normalize the decoded parameter map before query binding. */
export function applyNativeParameterConstraints(params: Record<string, string>, rules?: Record<string, NativeParameterConstraint>): boolean {
  if (rules === undefined) return true
  if (!rules || typeof rules !== 'object' || Array.isArray(rules)) return false
  for (const [name, rule] of Object.entries(rules)) {
    let value = params[name]
    if (typeof value !== 'string' || !rule || typeof rule !== 'object' || Array.isArray(rule)) return false
    if (Object.keys(rule).some(key => !['pattern', 'exclude', 'normalize'].includes(key))) return false
    if (rule.normalize !== undefined && rule.normalize !== 'lowercase') return false
    if (rule.normalize === 'lowercase') value = value.toLowerCase()
    if (rule.exclude !== undefined) {
      if (!Array.isArray(rule.exclude) || rule.exclude.some(item => typeof item !== 'string')) return false
      if (rule.exclude.some(item => (rule.normalize === 'lowercase' ? item.toLowerCase() : item) === value)) return false
    }
    if (rule.pattern !== undefined) {
      if (typeof rule.pattern !== 'string') return false
      try {
        const matched = new RegExp(`^(?:${rule.pattern})$`).exec(value)
        if (!matched || matched[0] !== value) return false
      }
      catch { return false }
    }
    params[name] = value
  }
  return true
}

export function nativeRouteConstraintProblems(screens?: Record<string, string>, constraints?: NativeRouteConstraints): string[] {
  const problems: string[] = []
  if (constraints === undefined) return problems
  if (!constraints || typeof constraints !== 'object' || Array.isArray(constraints)) return ['nativeScreenConstraints must name route parameter constraints.']
  for (const [route, rules] of Object.entries(constraints)) {
    const prefix = `nativeScreenConstraints[${JSON.stringify(route)}]`
    if (!Object.prototype.hasOwnProperty.call(screens ?? {}, route)) problems.push(`${prefix} names no native screen route.`)
    if (!rules || typeof rules !== 'object' || Array.isArray(rules)) { problems.push(`${prefix} must name parameter constraints.`); continue }
    const names = route.split('/').filter(part => part.startsWith(':')).map(part => part.slice(1))
    for (const [name, rule] of Object.entries(rules)) {
      const field = `${prefix}[${JSON.stringify(name)}]`
      if (!names.includes(name)) problems.push(`${field} names no path parameter.`)
      if (!rule || typeof rule !== 'object' || Array.isArray(rule)) { problems.push(`${field} must be a parameter constraint.`); continue }
      if (Object.keys(rule).some(key => !['pattern', 'exclude', 'normalize'].includes(key))) problems.push(`${field} has an unknown constraint field.`)
      if (rule.exclude !== undefined && (!Array.isArray(rule.exclude) || rule.exclude.some(value => typeof value !== 'string'))) problems.push(`${field}.exclude must contain strings.`)
      if (rule.normalize !== undefined && rule.normalize !== 'lowercase') problems.push(`${field}.normalize must be lowercase.`)
      if (rule.pattern !== undefined) {
        try {
          if (typeof rule.pattern !== 'string') throw new Error('not a string')
          new RegExp(`^(?:${rule.pattern})$`)
        }
        catch { problems.push(`${field}.pattern must be a valid regular expression.`) }
      }
    }
  }
  return problems
}

/** `/a//b/?q#h` → `/a/b`, the way the shell and the page compare paths. Null for a relative path. */
export function normalizeNativePath(raw: string): string | null {
  if (typeof raw !== 'string') return null
  let path = raw
  const cut = path.search(/[?#]/)
  if (cut >= 0) path = path.slice(0, cut)
  if (!path.startsWith('/')) return null
  path = path.replace(/\/{2,}/g, '/')
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  return path
}

export interface NativePathMatch {
  path: string
  screen: string
  params: Record<string, string>
}

export function routeSegments(path: string): string[] {
  return path === '/' ? [] : path.slice(1).split('/')
}

/**
 * The native screen for a path, by the rules the shell (`CraftHybridRoutes`)
 * and the page script apply: static segments win over `:params`, which win
 * over a trailing `*`; query items become params under the path's own.
 */
export function matchNativePath(nativeScreens: Record<string, string> | undefined, raw: string, constraints?: NativeRouteConstraints): NativePathMatch | null {
  if (constraints !== undefined && (!constraints || typeof constraints !== 'object' || Array.isArray(constraints))) return null
  const path = normalizeNativePath(raw)
  if (path === null) return null
  const routes = Object.entries(nativeScreens ?? {})
    .map(([pattern, screen]) => ({ key: pattern, pattern: normalizeNativePath(pattern), screen }))
    .filter((route): route is { key: string, pattern: string, screen: string } => route.pattern !== null && !!route.screen)
    .map(route => ({ ...route, segments: routeSegments(route.pattern) }))
  const wild = (segments: string[]) => (segments.at(-1) === '*' ? 1 : 0)
  const fixed = (segments: string[]) => segments.filter(s => s !== '*' && !s.startsWith(':')).length
  routes.sort((a, b) => (wild(a.segments) - wild(b.segments))
    || (fixed(b.segments) - fixed(a.segments))
    || (b.segments.length - a.segments.length)
    || (a.pattern < b.pattern ? -1 : a.pattern > b.pattern ? 1 : 0))
  const decode = (value: string) => {
    try {
      return decodeURIComponent(value)
    }
    catch {
      return value
    }
  }
  const parts = routeSegments(path)
  for (const route of routes) {
    const params: Record<string, string> = {}
    let matched = true
    for (let i = 0; i < route.segments.length; i++) {
      const segment = route.segments[i]!
      if (segment === '*') {
        params['*'] = parts.slice(i).join('/')
        break
      }
      if (i >= parts.length) { matched = false; break }
      if (segment.startsWith(':')) {
        if (!parts[i]) { matched = false; break }
        params[segment.slice(1)] = decode(parts[i]!)
      }
      else if (segment !== parts[i]) { matched = false; break }
    }
    if (!matched) continue
    if (route.segments.at(-1) !== '*' && route.segments.length !== parts.length) continue
    if (!applyNativeParameterConstraints(params, constraints?.[route.key])) continue
    const query = raw.indexOf('?')
    if (query >= 0) {
      for (const item of raw.slice(query + 1).split('#')[0]!.split('&')) {
        if (!item) continue
        const [rawKey = '', ...rest] = item.split('=')
        const key = decode(rawKey)
        if (!key || key in params) continue
        params[key] = decode(rest.join('=').replace(/\+/g, ' '))
      }
    }
    return { path, screen: route.screen, params }
  }
  return null
}


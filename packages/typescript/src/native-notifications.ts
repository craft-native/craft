/** Registered before notification delivery; payloads reference category ids. */
export interface NativeNotificationCategory {
  id: string
  actions: {
    id: string
    title: string
    destructive?: boolean
    /** Open the app. Otherwise nativeApp handles the action in the background. */
    foreground?: boolean
    authenticationRequired?: boolean
    textInput?: { buttonTitle: string, placeholder?: string }
  }[]
}

export function nativeNotificationProblems(categories: unknown, nativeApp?: string): string[] {
  if (categories === undefined) return []
  if (!Array.isArray(categories)) return ['notificationCategories must be an array.']
  const problems: string[] = []
  const categoryIds = new Set<string>()
  const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value)
  const text = (value: unknown): value is string => typeof value === 'string' && value.trim().length > 0
  for (const [index, category] of categories.entries()) {
    const field = `notificationCategories[${index}]`
    if (!object(category) || !text(category.id)) { problems.push(`${field} needs a nonempty id.`); continue }
    if (categoryIds.has(category.id)) problems.push(`${field}.id must be unique.`)
    categoryIds.add(category.id)
    if (!Array.isArray(category.actions) || category.actions.length < 1 || category.actions.length > 3) {
      problems.push(`${field}.actions must contain 1–3 actions for both platforms.`)
      continue
    }
    const actionIds = new Set<string>()
    for (const [position, action] of category.actions.entries()) {
      const path = `${field}.actions[${position}]`
      if (!object(action) || !text(action.id) || !text(action.title)) { problems.push(`${path} needs a nonempty id and title.`); continue }
      if (action.id.startsWith('com.apple.') || actionIds.has(action.id)) problems.push(`${path}.id must be unique and must not use Apple's reserved prefix.`)
      actionIds.add(action.id)
      for (const flag of ['destructive', 'foreground', 'authenticationRequired']) {
        if (action[flag] !== undefined && typeof action[flag] !== 'boolean') problems.push(`${path}.${flag} must be a boolean.`)
      }
      if (action.foreground !== true && !nativeApp?.trim()) problems.push(`${path} requires nativeApp for background delivery, or foreground: true.`)
      if (action.textInput !== undefined && (!object(action.textInput) || !text(action.textInput.buttonTitle)
        || (action.textInput.placeholder !== undefined && typeof action.textInput.placeholder !== 'string'))) {
        problems.push(`${path}.textInput needs a buttonTitle and an optional string placeholder.`)
      }
    }
  }
  return problems
}

/**
 * @fileoverview iOS Advanced Features API
 * @description Advanced iOS-specific features including CarPlay, App Clips, Live Activities,
 * SharePlay, StoreKit 2, App Intents, TipKit, and Focus Filters.
 * @module @craft-native/api/ios-advanced
 */

import { createLiveActivityHandle } from './live-activity-handle.js'
import { isCraft, getPlatform } from './process.js'

// ============================================================================
// CarPlay Support
// ============================================================================

/**
 * CarPlay template types.
 */
export type CarPlayTemplateType =
  | 'list'
  | 'grid'
  | 'information'
  | 'point-of-interest'
  | 'tab-bar'
  | 'alert'
  | 'action-sheet'
  | 'now-playing'
  | 'voice-control'
  | 'search'
  | 'map'

/**
 * CarPlay list item.
 */
export interface CarPlayListItem {
  /** Unique identifier */
  id: string
  /** Display text */
  text: string
  /** Detail text */
  detailText?: string
  /** Image name or URL */
  image?: string
  /** Whether item shows disclosure indicator */
  showsDisclosureIndicator?: boolean
  /** Whether item is playing */
  isPlaying?: boolean
  /** Playback progress (0-1) */
  playbackProgress?: number
}

/**
 * CarPlay grid item.
 */
export interface CarPlayGridItem {
  /** Unique identifier */
  id: string
  /** Display title */
  title: string
  /** Image name or URL */
  image: string
}

/**
 * CarPlay template configuration.
 */
export interface CarPlayTemplate {
  /** Template type */
  type: CarPlayTemplateType
  /** Template title */
  title?: string
  /** List items (for list template) */
  listItems?: CarPlayListItem[]
  /** Grid items (for grid template) */
  gridItems?: CarPlayGridItem[]
  /** Sections for grouped lists */
  sections?: Array<{
    header?: string
    items: CarPlayListItem[]
  }>
  /** Tab bar items */
  tabs?: Array<{
    title: string
    image: string
    template: CarPlayTemplate
  }>
}

/**
 * CarPlay API for automotive integration.
 *
 * @example
 * // Set up CarPlay scene
 * carplay.onConnect((_window) => {
 *   carplay.pushTemplate({
 *     type: 'list',
 *     title: 'My Music',
 *     listItems: [
 *       { id: '1', text: 'Favorites', showsDisclosureIndicator: true },
 *       { id: '2', text: 'Recently Played', showsDisclosureIndicator: true }
 *     ]
 *   })
 * })
 *
 * carplay.onSelectListItem((item, _template) => {
 *   console.log('Selected:', item.text)
 * })
 */
export const carplay = {
  /**
   * Check if CarPlay is available.
   */
  async isAvailable(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.carplay?.isAvailable?.() ?? false
  },

  /**
   * Check if CarPlay is currently connected.
   */
  async isConnected(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.carplay?.isConnected?.() ?? false
  },

  /**
   * Register CarPlay connection handler.
   */
  onConnect(handler: (window: any) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.carplay?.onConnect?.(handler)
  },

  /**
   * Register CarPlay disconnection handler.
   */
  onDisconnect(handler: () => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.carplay?.onDisconnect?.(handler)
  },

  /**
   * Push a template to the CarPlay screen.
   */
  async pushTemplate(template: CarPlayTemplate, animated = true): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.pushTemplate?.(template, animated)
  },

  /**
   * Pop the current template.
   */
  async popTemplate(animated = true): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.popTemplate?.(animated)
  },

  /**
   * Pop to root template.
   */
  async popToRootTemplate(animated = true): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.popToRootTemplate?.(animated)
  },

  /**
   * Present a template modally.
   */
  async presentTemplate(template: CarPlayTemplate, animated = true): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.presentTemplate?.(template, animated)
  },

  /**
   * Dismiss presented template.
   */
  async dismissTemplate(animated = true): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.dismissTemplate?.(animated)
  },

  /**
   * Register list item selection handler.
   */
  onSelectListItem(handler: (item: CarPlayListItem, template: CarPlayTemplate) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.carplay?.onSelectListItem?.(handler)
  },

  /**
   * Register grid item selection handler.
   */
  onSelectGridItem(handler: (item: CarPlayGridItem, template: CarPlayTemplate) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.carplay?.onSelectGridItem?.(handler)
  },

  /**
   * Update now playing information.
   */
  async updateNowPlaying(info: {
    title: string
    artist?: string
    album?: string
    artwork?: string
    duration?: number
    elapsedTime?: number
    playbackRate?: number
    isPlaying?: boolean
  }): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.carplay?.updateNowPlaying?.(info)
  }
}

// ============================================================================
// App Clips
// ============================================================================

/**
 * App Clip invocation context.
 */
export interface AppClipInvocation {
  /** Invocation URL */
  url: string
  /** URL parameters */
  parameters: Record<string, string>
  /** Physical location (if available) */
  location?: {
    latitude: number
    longitude: number
  }
  /** Invocation source */
  source: 'qr-code' | 'nfc' | 'safari' | 'messages' | 'maps' | 'smart-banner'
}

/**
 * App Clips API for lightweight app experiences.
 *
 * @example
 * // Handle App Clip launch
 * appClips.onInvoke((invocation) => {
 *   console.log('Launched from:', invocation.source)
 *   console.log('URL:', invocation.url)
 * })
 *
 * // Prompt to install full app
 * await appClips.promptToInstallFullApp()
 */
export const appClips = {
  /**
   * Check if running as App Clip.
   */
  isAppClip(): boolean {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.appClips?.isAppClip?.() ?? false
  },

  /**
   * Register App Clip invocation handler.
   */
  onInvoke(handler: (invocation: AppClipInvocation) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.appClips?.onInvoke?.(handler)
  },

  /**
   * Get the invocation context.
   */
  async getInvocation(): Promise<AppClipInvocation | null> {
    if (!isCraft() || getPlatform() !== 'ios') return null
    return (window as any).craft?.appClips?.getInvocation?.()
  },

  /**
   * Prompt user to install the full app.
   */
  async promptToInstallFullApp(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.appClips?.promptToInstallFullApp?.()
  },

  /**
   * Request ephemeral notification permission.
   */
  async requestEphemeralNotificationPermission(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.appClips?.requestEphemeralNotificationPermission?.() ?? false
  },

  /**
   * Request location confirmation.
   * Used to verify user is at a specific location for App Clip experiences.
   */
  async confirmLocation(regionIdentifier: string): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.appClips?.confirmLocation?.(regionIdentifier) ?? false
  }
}

// ============================================================================
// Live Activities (Dynamic Island)
// ============================================================================

/**
 * Live Activity content state.
 */
export interface LiveActivityContentState {
  [key: string]: string | number | boolean
}

/**
 * Live Activity attributes (static content).
 */
export interface LiveActivityAttributes {
  [key: string]: string | number | boolean
}

/**
 * Live Activity configuration.
 */
export interface LiveActivityConfig {
  /** Activity type identifier */
  activityType: string
  /** Static attributes */
  attributes: LiveActivityAttributes
  /** Initial content state */
  contentState: LiveActivityContentState
  /** Stale date (when content becomes outdated) */
  staleDate?: Date
  /** Relevance score (0-100) */
  relevanceScore?: number
}

export interface LiveActivityHandle {
  readonly id: string
  update(state: LiveActivityContentState): Promise<void>
  end(finalState?: LiveActivityContentState): Promise<void>
}

/**
 * Live Activities API for Dynamic Island and Lock Screen.
 *
 * @example
 * // Start a delivery tracking activity
 * const activity = await liveActivities.start({
 *   activityType: 'DeliveryActivity',
 *   attributes: { orderNumber: '12345', restaurant: 'Pizza Place' },
 *   contentState: { status: 'preparing', eta: '15 min' }
 * })
 *
 * // Update the activity
 * await activity.update({
 *   status: 'on-the-way',
 *   eta: '5 min',
 *   driverName: 'John'
 * })
 *
 * // End the activity
 * await activity.end({ status: 'delivered' })
 */
export const liveActivities = {
  /**
   * Check if Live Activities are supported.
   */
  async areSupported(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.liveActivities?.areSupported?.() ?? false
  },

  /**
   * Check if Live Activities are enabled by user.
   */
  async areEnabled(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.liveActivities?.areEnabled?.() ?? false
  },

  /**
   * Start a new Live Activity.
   */
  async start(config: LiveActivityConfig): Promise<LiveActivityHandle> {
    const result = !isCraft() || getPlatform() !== 'ios'
      ? { id: `mock-${Date.now()}` }
      : await ((window as any).craft?.liveActivities?.start?.(config) ?? { id: `mock-${Date.now()}` })
    return createLiveActivityHandle(
      result.id,
      state => liveActivities.update(result.id, state),
      finalState => liveActivities.end(result.id, finalState),
    )
  },

  /**
   * Update an existing Live Activity.
   */
  async update(
    activityId: string,
    contentState: LiveActivityContentState,
    alertConfig?: {
      title: string
      body: string
      sound?: string
    }
  ): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.liveActivities?.update?.(activityId, contentState, alertConfig)
  },

  /**
   * End a Live Activity.
   */
  async end(
    activityId: string,
    finalContentState?: LiveActivityContentState,
    dismissalPolicy?: 'immediate' | 'default' | 'after'
  ): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.liveActivities?.end?.(activityId, finalContentState, dismissalPolicy)
  },

  /**
   * Get all active Live Activities.
   */
  async getAll(): Promise<Array<{ id: string; activityType: string; contentState: LiveActivityContentState }>> {
    if (!isCraft() || getPlatform() !== 'ios') return []
    return (window as any).craft?.liveActivities?.getAll?.() ?? []
  },

  /**
   * Request push token for remote Live Activity updates.
   */
  async requestPushToken(activityId: string): Promise<string | null> {
    if (!isCraft() || getPlatform() !== 'ios') return null
    return (window as any).craft?.liveActivities?.requestPushToken?.(activityId)
  }
}

// ============================================================================
// SharePlay
// ============================================================================

/**
 * SharePlay session state.
 */
export type SharePlaySessionState = 'waiting' | 'joined' | 'invalidated'

/**
 * SharePlay participant info.
 */
export interface SharePlayParticipant {
  /** Participant identifier */
  id: string
  /** Whether this is the local participant */
  isLocal: boolean
}

/**
 * SharePlay activity configuration.
 */
export interface SharePlayActivity {
  /** Activity identifier */
  id: string
  /** Activity title */
  title: string
  /** Activity subtitle */
  subtitle?: string
  /** Activity image */
  image?: string
  /** Whether activity supports picture-in-picture */
  supportsPictureInPicture?: boolean
}

/**
 * SharePlay API for shared experiences during FaceTime calls.
 *
 * @example
 * // Start a SharePlay activity
 * await sharePlay.startActivity({
 *   id: 'watch-together',
 *   title: 'Watch Movie Together',
 *   subtitle: 'Synchronized playback'
 * })
 *
 * // Send synchronized message to all participants
 * sharePlay.broadcast({ action: 'play', timestamp: 1234 })
 *
 * // Receive messages from other participants
 * sharePlay.onMessage((message, participant) => {
 *   console.log(`${participant.id}: ${message.action}`)
 * })
 */
export const sharePlay = {
  /**
   * Check if SharePlay is available.
   */
  async isAvailable(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.sharePlay?.isAvailable?.() ?? false
  },

  /**
   * Get the current session state.
   */
  async getSessionState(): Promise<SharePlaySessionState | null> {
    if (!isCraft() || getPlatform() !== 'ios') return null
    return (window as any).craft?.sharePlay?.getSessionState?.()
  },

  /**
   * Get all participants in the current session.
   */
  async getParticipants(): Promise<SharePlayParticipant[]> {
    if (!isCraft() || getPlatform() !== 'ios') return []
    return (window as any).craft?.sharePlay?.getParticipants?.() ?? []
  },

  /**
   * Start a SharePlay activity.
   */
  async startActivity(activity: SharePlayActivity): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.sharePlay?.startActivity?.(activity) ?? false
  },

  /**
   * End the current SharePlay activity.
   */
  async endActivity(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.sharePlay?.endActivity?.()
  },

  /**
   * Broadcast a message to all participants.
   */
  async broadcast(message: Record<string, any>): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.sharePlay?.broadcast?.(message)
  },

  /**
   * Send a message to a specific participant.
   */
  async send(participantId: string, message: Record<string, any>): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.sharePlay?.send?.(participantId, message)
  },

  /**
   * Register message handler.
   */
  onMessage(handler: (message: Record<string, any>, participant: SharePlayParticipant) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.sharePlay?.onMessage?.(handler)
  },

  /**
   * Register session state change handler.
   */
  onSessionStateChange(handler: (state: SharePlaySessionState) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.sharePlay?.onSessionStateChange?.(handler)
  },

  /**
   * Register participant change handler.
   */
  onParticipantsChange(handler: (participants: SharePlayParticipant[]) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.sharePlay?.onParticipantsChange?.(handler)
  },

  /**
   * Coordinate playback state across participants.
   */
  async coordinatePlayback(state: {
    isPlaying: boolean
    playbackRate: number
    currentTime: number
  }): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.sharePlay?.coordinatePlayback?.(state)
  }
}

// ============================================================================
// StoreKit 2
// ============================================================================

/**
 * Product type.
 */
export type ProductType = 'consumable' | 'non-consumable' | 'auto-renewable' | 'non-renewable'

/**
 * Product information.
 */
export interface Product {
  /** Product identifier */
  id: string
  /** Product type */
  type: ProductType
  /** Display name */
  displayName: string
  /** Description */
  description: string
  /** Formatted price */
  displayPrice: string
  /** Price in decimal */
  price: number
  /** Currency code */
  currencyCode: string
  /** Subscription info (for subscription products) */
  subscription?: {
    /** Subscription period */
    subscriptionPeriod: {
      unit: 'day' | 'week' | 'month' | 'year'
      value: number
    }
    /** Introductory offer */
    introductoryOffer?: {
      displayPrice: string
      period: { unit: string; value: number }
      periodCount: number
      paymentMode: 'freeTrial' | 'payAsYouGo' | 'payUpFront'
    }
  }
}

/**
 * Transaction information.
 */
export interface Transaction {
  /** Transaction identifier */
  id: string
  /** Original transaction ID (for renewals) */
  originalId: string
  /** Product identifier */
  productId: string
  /** Purchase date */
  purchaseDate: Date
  /** Expiration date (for subscriptions) */
  expirationDate?: Date
  /** Whether transaction is upgraded */
  isUpgraded: boolean
  /** Revocation date (if revoked) */
  revocationDate?: Date
  /** Revocation reason */
  revocationReason?: 'developerIssue' | 'other'
  /** Environment */
  environment: 'production' | 'sandbox' | 'xcode'
}

/**
 * StoreKit 2 API for in-app purchases and subscriptions.
 *
 * @example
 * // Load products
 * const products = await storeKit.getProducts(['premium_monthly', 'premium_yearly'])
 *
 * // Purchase a product
 * const result = await storeKit.purchase(products[0].id)
 * if (result.success) {
 *   console.log('Purchase successful!')
 * }
 *
 * // Check entitlements
 * const hasAccess = await storeKit.isEntitled('premium')
 */
export const storeKit = {
  /**
   * Get products by identifiers.
   */
  async getProducts(productIds: string[]): Promise<Product[]> {
    if (!isCraft() || getPlatform() !== 'ios') return []
    return (window as any).craft?.storeKit?.getProducts?.(productIds) ?? []
  },

  /**
   * Purchase a product.
   */
  async purchase(productId: string, options?: {
    quantity?: number
    appAccountToken?: string
    simulatesAskToBuyInSandbox?: boolean
  }): Promise<{ success: boolean; transaction?: Transaction; error?: string }> {
    if (!isCraft() || getPlatform() !== 'ios') {
      return { success: false, error: 'StoreKit not available' }
    }
    return (window as any).craft?.storeKit?.purchase?.(productId, options) ?? { success: false }
  },

  /**
   * Check if user is entitled to a product/feature.
   */
  async isEntitled(productId: string): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.storeKit?.isEntitled?.(productId) ?? false
  },

  /**
   * Get current entitlements.
   */
  async getCurrentEntitlements(): Promise<Transaction[]> {
    if (!isCraft() || getPlatform() !== 'ios') return []
    return (window as any).craft?.storeKit?.getCurrentEntitlements?.() ?? []
  },

  /**
   * Get transaction history.
   */
  async getTransactionHistory(productId?: string): Promise<Transaction[]> {
    if (!isCraft() || getPlatform() !== 'ios') return []
    return (window as any).craft?.storeKit?.getTransactionHistory?.(productId) ?? []
  },

  /**
   * Restore purchases.
   */
  async restorePurchases(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.storeKit?.restorePurchases?.()
  },

  /**
   * Finish a transaction (required after delivering content).
   */
  async finishTransaction(transactionId: string): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.storeKit?.finishTransaction?.(transactionId)
  },

  /**
   * Get subscription status.
   */
  async getSubscriptionStatus(groupId: string): Promise<{
    state: 'subscribed' | 'expired' | 'inBillingRetry' | 'inGracePeriod' | 'revoked'
    renewalInfo?: {
      willAutoRenew: boolean
      autoRenewProductId: string
      expirationIntent?: 'cancelled' | 'billingError' | 'priceIncrease' | 'productNotAvailable'
    }
  } | null> {
    if (!isCraft() || getPlatform() !== 'ios') return null
    return (window as any).craft?.storeKit?.getSubscriptionStatus?.(groupId)
  },

  /**
   * Present offer code redemption sheet.
   */
  async presentOfferCodeRedemption(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.storeKit?.presentOfferCodeRedemption?.()
  },

  /**
   * Present manage subscriptions sheet.
   */
  async presentManageSubscriptions(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.storeKit?.presentManageSubscriptions?.()
  },

  /**
   * Present refund request sheet.
   */
  async beginRefundRequest(transactionId: string): Promise<'success' | 'userCancelled' | 'failed'> {
    if (!isCraft() || getPlatform() !== 'ios') return 'failed'
    return (window as any).craft?.storeKit?.beginRefundRequest?.(transactionId) ?? 'failed'
  },

  /**
   * Listen for transaction updates.
   */
  onTransactionUpdate(handler: (transaction: Transaction) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.storeKit?.onTransactionUpdate?.(handler)
  },

  /**
   * Show price consent sheet if needed.
   */
  async showPriceConsentIfNeeded(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.storeKit?.showPriceConsentIfNeeded?.()
  }
}

// ============================================================================
// App Intents (Siri Shortcuts)
// ============================================================================

/**
 * App Intent parameter type.
 */
export type IntentParameterType = 'string' | 'integer' | 'double' | 'boolean' | 'date' | 'url' | 'enum'

/**
 * App Intent parameter definition.
 */
export interface IntentParameter {
  /** Parameter name */
  name: string
  /** Parameter type */
  type: IntentParameterType
  /** Display title */
  title: string
  /** Description */
  description?: string
  /** Whether required */
  required?: boolean
  /** Default value */
  defaultValue?: any
  /** Enum values (for enum type) */
  enumValues?: Array<{ value: string; displayName: string }>
}

/**
 * App Intent definition.
 */
export interface AppIntent {
  /** Intent identifier */
  id: string
  /** Display title */
  title: string
  /** Description */
  description: string
  /** Parameters */
  parameters?: IntentParameter[]
  /** Suggested invocation phrase */
  suggestedInvocationPhrase?: string
}

/**
 * App Intents API for Siri Shortcuts and Spotlight.
 *
 * @example
 * // Register an intent
 * appIntents.register({
 *   id: 'com.myapp.order-coffee',
 *   title: 'Order Coffee',
 *   description: 'Order your favorite coffee',
 *   parameters: [
 *     { name: 'size', type: 'enum', title: 'Size', enumValues: [
 *       { value: 'small', displayName: 'Small' },
 *       { value: 'medium', displayName: 'Medium' },
 *       { value: 'large', displayName: 'Large' }
 *     ]}
 *   ],
 *   suggestedInvocationPhrase: 'Order my coffee'
 * })
 *
 * // Handle intent execution
 * appIntents.onPerform('com.myapp.order-coffee', async (params) => {
 *   await orderCoffee(params.size)
 *   return { success: true, message: 'Coffee ordered!' }
 * })
 */
export const appIntents = {
  /**
   * Register an App Intent.
   */
  register(intent: AppIntent): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.appIntents?.register?.(intent)
  },

  /**
   * Unregister an App Intent.
   */
  unregister(intentId: string): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.appIntents?.unregister?.(intentId)
  },

  /**
   * Register intent execution handler.
   */
  onPerform(
    intentId: string,
    handler: (parameters: Record<string, any>) => Promise<{ success: boolean; message?: string; value?: any }>
  ): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.appIntents?.onPerform?.(intentId, handler)
  },

  /**
   * Donate an intent for Siri suggestions.
   */
  async donate(intentId: string, parameters?: Record<string, any>): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.appIntents?.donate?.(intentId, parameters)
  },

  /**
   * Delete donated intents.
   */
  async deleteDonations(intentId?: string): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.appIntents?.deleteDonations?.(intentId)
  },

  /**
   * Update Spotlight index for intent.
   */
  async updateSpotlightIndex(intentId: string, searchableItems: Array<{
    uniqueIdentifier: string
    title: string
    contentDescription?: string
    keywords?: string[]
    thumbnailUrl?: string
  }>): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.appIntents?.updateSpotlightIndex?.(intentId, searchableItems)
  }
}

// ============================================================================
// TipKit
// ============================================================================

/**
 * Tip display frequency.
 */
export type TipDisplayFrequency = 'immediate' | 'hourly' | 'daily' | 'weekly' | 'monthly'

/**
 * Tip configuration.
 */
export interface Tip {
  /** Tip identifier */
  id: string
  /** Title */
  title: string
  /** Message */
  message: string
  /** Image name (SF Symbol or asset) */
  image?: string
  /** Action buttons */
  actions?: Array<{
    id: string
    title: string
  }>
  /** Display rules */
  rules?: {
    /** Show after event count */
    eventCount?: { event: string; count: number }
    /** Show after duration */
    duration?: { seconds: number }
    /** Parameter-based conditions */
    parameters?: Record<string, any>
  }
  /** Display options */
  options?: {
    /** Maximum display count */
    maxDisplayCount?: number
    /** Ignore display frequency */
    ignoreDisplayFrequency?: boolean
  }
}

/**
 * TipKit API for contextual hints and feature discovery.
 *
 * @example
 * // Configure TipKit
 * await tipKit.configure({ displayFrequency: 'daily' })
 *
 * // Register a tip
 * tipKit.register({
 *   id: 'new-feature-tip',
 *   title: 'New Feature!',
 *   message: 'Try our new sharing feature',
 *   image: 'square.and.arrow.up',
 *   rules: {
 *     eventCount: { event: 'app-opened', count: 3 }
 *   }
 * })
 *
 * // Track events for tip rules
 * tipKit.trackEvent('app-opened')
 *
 * // Show tip inline
 * const shouldShow = await tipKit.shouldShow('new-feature-tip')
 */
export const tipKit = {
  /**
   * Configure TipKit.
   */
  async configure(options: {
    displayFrequency?: TipDisplayFrequency
    datastoreLocation?: 'applicationDefault' | 'groupContainer'
  }): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.configure?.(options)
  },

  /**
   * Register a tip.
   */
  register(tip: Tip): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.tipKit?.register?.(tip)
  },

  /**
   * Check if a tip should be displayed.
   */
  async shouldShow(tipId: string): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.tipKit?.shouldShow?.(tipId) ?? false
  },

  /**
   * Invalidate a tip (permanently hide).
   */
  async invalidate(tipId: string, reason?: string): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.invalidate?.(tipId, reason)
  },

  /**
   * Track an event for tip rules.
   */
  async trackEvent(eventId: string): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.trackEvent?.(eventId)
  },

  /**
   * Set a parameter value for tip rules.
   */
  async setParameter(name: string, value: any): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.setParameter?.(name, value)
  },

  /**
   * Show a tip as a popover.
   */
  async showPopover(tipId: string, sourceElement: string): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.showPopover?.(tipId, sourceElement)
  },

  /**
   * Register tip action handler.
   */
  onAction(tipId: string, handler: (actionId: string) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.tipKit?.onAction?.(tipId, handler)
  },

  /**
   * Reset all tips (for testing).
   */
  async resetDatastore(): Promise<void> {
    if (!isCraft() || getPlatform() !== 'ios') return
    return (window as any).craft?.tipKit?.resetDatastore?.()
  }
}

// ============================================================================
// Focus Filters
// ============================================================================

/**
 * Focus status.
 */
export interface FocusStatus {
  /** Whether Focus is active */
  isFocusActive: boolean
  /** Current Focus name (if authorized) */
  focusName?: string
}

/**
 * Focus filter configuration.
 */
export interface FocusFilter {
  /** Filter identifier */
  id: string
  /** Display name */
  name: string
  /** Description */
  description: string
  /** Filter parameters */
  parameters?: Array<{
    name: string
    type: 'boolean' | 'string' | 'selection'
    displayName: string
    options?: string[]
  }>
}

/**
 * Focus Filters API for Focus mode integration.
 *
 * @example
 * // Register a focus filter
 * focusFilters.register({
 *   id: 'work-mode',
 *   name: 'Work Mode',
 *   description: 'Show only work-related content',
 *   parameters: [
 *     { name: 'showNotifications', type: 'boolean', displayName: 'Show Notifications' }
 *   ]
 * })
 *
 * // Handle filter changes
 * focusFilters.onFilterChange((filterSettings) => {
 *   if (filterSettings.showNotifications === false) {
 *     disableNotifications()
 *   }
 * })
 */
export const focusFilters = {
  /**
   * Check Focus authorization status.
   */
  async getAuthorizationStatus(): Promise<'notDetermined' | 'denied' | 'authorized'> {
    if (!isCraft() || getPlatform() !== 'ios') return 'notDetermined'
    return (window as any).craft?.focusFilters?.getAuthorizationStatus?.() ?? 'notDetermined'
  },

  /**
   * Request Focus authorization.
   */
  async requestAuthorization(): Promise<boolean> {
    if (!isCraft() || getPlatform() !== 'ios') return false
    return (window as any).craft?.focusFilters?.requestAuthorization?.() ?? false
  },

  /**
   * Get current Focus status.
   */
  async getFocusStatus(): Promise<FocusStatus> {
    if (!isCraft() || getPlatform() !== 'ios') {
      return { isFocusActive: false }
    }
    return (window as any).craft?.focusFilters?.getFocusStatus?.() ?? { isFocusActive: false }
  },

  /**
   * Register a Focus filter.
   */
  register(filter: FocusFilter): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.focusFilters?.register?.(filter)
  },

  /**
   * Get current filter settings.
   */
  async getCurrentFilterSettings(): Promise<Record<string, any> | null> {
    if (!isCraft() || getPlatform() !== 'ios') return null
    return (window as any).craft?.focusFilters?.getCurrentFilterSettings?.()
  },

  /**
   * Register Focus status change handler.
   */
  onFocusChange(handler: (status: FocusStatus) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.focusFilters?.onFocusChange?.(handler)
  },

  /**
   * Register filter settings change handler.
   */
  onFilterChange(handler: (settings: Record<string, any>) => void): void {
    if (!isCraft() || getPlatform() !== 'ios') return
    ;(window as any).craft?.focusFilters?.onFilterChange?.(handler)
  }
}

// ============================================================================
// Exports
// ============================================================================

const iosAdvanced: {
  carplay: typeof carplay
  appClips: typeof appClips
  liveActivities: typeof liveActivities
  sharePlay: typeof sharePlay
  storeKit: typeof storeKit
  appIntents: typeof appIntents
  tipKit: typeof tipKit
  focusFilters: typeof focusFilters
} = {
  carplay: carplay,
  appClips: appClips,
  liveActivities: liveActivities,
  sharePlay: sharePlay,
  storeKit: storeKit,
  appIntents: appIntents,
  tipKit: tipKit,
  focusFilters: focusFilters
}

export default iosAdvanced

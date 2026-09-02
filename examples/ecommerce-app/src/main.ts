/**
 * E-commerce App - Cross-platform shopping app built with Craft
 * Features: Product catalog, cart, checkout, orders, wishlist, search, reviews
 */

// NOTE: Use `win` alias (for windowManager) instead of `window`. `Platform` (value)
// is exported from 'craft-native/components' to avoid a conflict with the
// Platform type at the top level.
import { db, win as window, haptics } from 'craft-native'
import { Platform } from 'craft-native/components'

// Types
interface Product {
  id: string
  name: string
  description: string
  price: number
  compareAtPrice?: number
  images: string[]
  category: string
  tags: string[]
  variants: ProductVariant[]
  rating: number
  reviewCount: number
  inStock: boolean
  createdAt: string
}

interface ProductVariant {
  id: string
  name: string
  price: number
  sku: string
  inStock: boolean
  options: Record<string, string>
}

interface CartItem {
  productId: string
  variantId: string
  quantity: number
  price: number
}

interface Order {
  id: string
  items: CartItem[]
  subtotal: number
  tax: number
  shipping: number
  total: number
  status: 'pending' | 'processing' | 'shipped' | 'delivered' | 'cancelled'
  shippingAddress: Address
  paymentMethod: string
  createdAt: string
}

interface Address {
  name: string
  line1: string
  line2?: string
  city: string
  state: string
  postalCode: string
  country: string
  phone: string
}

interface User {
  id: string
  email: string
  name: string
  addresses: Address[]
}

interface Review {
  id: string
  productId: string
  userId: string
  userName: string
  rating: number
  title: string
  content: string
  helpful: number
  createdAt: string
}

// Store state management
class Store {
  private products: Map<string, Product> = new Map()
  private cart: CartItem[] = []
  private wishlist: Set<string> = new Set()
  private orders: Order[] = []
  private user: User | null = null
  private searchQuery = ''
  private selectedCategory = 'all'
  private currentView: 'home' | 'product' | 'cart' | 'checkout' | 'orders' | 'wishlist' | 'search' = 'home'
  private currentProductId: string | null = null
  private listeners: Set<() => void> = new Set()

  // Products
  setProducts(products: Product[]): void {
    products.forEach((p) => this.products.set(p.id, p))
    this.notify()
  }

  getProduct(id: string): Product | undefined {
    return this.products.get(id)
  }

  getProducts(category?: string): Product[] {
    const products = Array.from(this.products.values())
    if (category && category !== 'all') {
      return products.filter((p) => p.category === category)
    }
    return products
  }

  searchProducts(query: string): Product[] {
    const q = query.toLowerCase()
    return Array.from(this.products.values()).filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        p.description.toLowerCase().includes(q) ||
        p.tags.some((t) => t.toLowerCase().includes(q))
    )
  }

  getCategories(): string[] {
    const categories = new Set(Array.from(this.products.values()).map((p) => p.category))
    return ['all', ...Array.from(categories)]
  }

  // Cart
  addToCart(productId: string, variantId: string, quantity = 1): void {
    const product = this.products.get(productId)
    if (!product) return

    const variant = product.variants.find((v) => v.id === variantId) || product.variants[0]
    const existingIndex = this.cart.findIndex((i) => i.productId === productId && i.variantId === variantId)

    if (existingIndex >= 0) {
      this.cart[existingIndex].quantity += quantity
    }
else {
      this.cart.push({
        productId,
        variantId,
        quantity,
        price: variant?.price || product.price,
      })
    }

    this.saveCart()
    this.notify()

    if (Platform.OS === 'ios' || Platform.OS === 'android') {
      haptics.notification('success')
    }
  }

  removeFromCart(productId: string, variantId: string): void {
    this.cart = this.cart.filter((i) => !(i.productId === productId && i.variantId === variantId))
    this.saveCart()
    this.notify()
  }

  updateCartQuantity(productId: string, variantId: string, quantity: number): void {
    const item = this.cart.find((i) => i.productId === productId && i.variantId === variantId)
    if (item) {
      if (quantity <= 0) {
        this.removeFromCart(productId, variantId)
      }
else {
        item.quantity = quantity
        this.saveCart()
        this.notify()
      }
    }
  }

  getCart(): CartItem[] {
    return this.cart
  }

  getCartTotal(): { subtotal: number; tax: number; shipping: number; total: number } {
    const subtotal = this.cart.reduce((sum, item) => sum + item.price * item.quantity, 0)
    const tax = subtotal * 0.08 // 8% tax
    const shipping = subtotal > 50 ? 0 : 5.99 // Free shipping over $50
    return { subtotal, tax, shipping, total: subtotal + tax + shipping }
  }

  clearCart(): void {
    this.cart = []
    this.saveCart()
    this.notify()
  }

  private async saveCart(): Promise<void> {
    await db.execute('UPDATE app_state SET cart = ? WHERE id = 1', [JSON.stringify(this.cart)])
  }

  // Wishlist
  addToWishlist(productId: string): void {
    this.wishlist.add(productId)
    this.saveWishlist()
    this.notify()

    if (Platform.OS === 'ios' || Platform.OS === 'android') {
      haptics.impact('light')
    }
  }

  removeFromWishlist(productId: string): void {
    this.wishlist.delete(productId)
    this.saveWishlist()
    this.notify()
  }

  isInWishlist(productId: string): boolean {
    return this.wishlist.has(productId)
  }

  getWishlist(): Product[] {
    return Array.from(this.wishlist)
      .map((id) => this.products.get(id))
      .filter((p): p is Product => p !== undefined)
  }

  private async saveWishlist(): Promise<void> {
    await db.execute('UPDATE app_state SET wishlist = ? WHERE id = 1', [JSON.stringify(Array.from(this.wishlist))])
  }

  // Orders
  async createOrder(shippingAddress: Address, paymentMethod: string): Promise<Order> {
    const totals = this.getCartTotal()
    const order: Order = {
      id: generateId(),
      items: [...this.cart],
      subtotal: totals.subtotal,
      tax: totals.tax,
      shipping: totals.shipping,
      total: totals.total,
      status: 'pending',
      shippingAddress,
      paymentMethod,
      createdAt: new Date().toISOString(),
    }

    this.orders.unshift(order)
    await db.execute(
      'INSERT INTO orders (id, data, createdAt) VALUES (?, ?, ?)',
      [order.id, JSON.stringify(order), order.createdAt]
    )

    this.clearCart()
    return order
  }

  getOrders(): Order[] {
    return this.orders
  }

  // User
  setUser(user: User | null): void {
    this.user = user
    this.notify()
  }

  getUser(): User | null {
    return this.user
  }

  // Navigation
  setView(view: typeof this.currentView, productId?: string): void {
    this.currentView = view
    this.currentProductId = productId || null
    this.notify()
  }

  getView(): typeof this.currentView {
    return this.currentView
  }

  getCurrentProductId(): string | null {
    return this.currentProductId
  }

  setCategory(category: string): void {
    this.selectedCategory = category
    this.notify()
  }

  getCategory(): string {
    return this.selectedCategory
  }

  setSearchQuery(query: string): void {
    this.searchQuery = query
    this.notify()
  }

  getSearchQuery(): string {
    return this.searchQuery
  }

  // State persistence
  async loadState(): Promise<void> {
    const result = await db.query<{ cart: string; wishlist: string }>('SELECT cart, wishlist FROM app_state WHERE id = 1')
    if (result.length > 0) {
      this.cart = JSON.parse(result[0].cart || '[]')
      this.wishlist = new Set(JSON.parse(result[0].wishlist || '[]'))
    }

    const orders = await db.query<{ data: string }>('SELECT data FROM orders ORDER BY createdAt DESC')
    this.orders = orders.map((o) => JSON.parse(o.data))
  }

  // Subscriptions
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private notify(): void {
    this.listeners.forEach((l) => l())
  }
}

// Initialize database
async function initDatabase(): Promise<void> {
  await db.execute(`
    CREATE TABLE IF NOT EXISTS app_state (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      cart TEXT DEFAULT '[]',
      wishlist TEXT DEFAULT '[]'
    )
  `)

  await db.execute(`
    CREATE TABLE IF NOT EXISTS orders (
      id TEXT PRIMARY KEY,
      data TEXT NOT NULL,
      createdAt TEXT NOT NULL
    )
  `)

  await db.execute('INSERT OR IGNORE INTO app_state (id) VALUES (1)')
}

// Mock product data
function getMockProducts(): Product[] {
  return [
    {
      id: 'prod-1',
      name: 'Wireless Headphones',
      description: 'Premium noise-canceling wireless headphones with 30-hour battery life.',
      price: 299.99,
      compareAtPrice: 349.99,
      images: ['headphones-1.jpg', 'headphones-2.jpg'],
      category: 'Electronics',
      tags: ['audio', 'wireless', 'bluetooth'],
      variants: [
        { id: 'var-1', name: 'Black', price: 299.99, sku: 'WH-BLK', inStock: true, options: { color: 'Black' } },
        { id: 'var-2', name: 'White', price: 299.99, sku: 'WH-WHT', inStock: true, options: { color: 'White' } },
        { id: 'var-3', name: 'Blue', price: 319.99, sku: 'WH-BLU', inStock: false, options: { color: 'Blue' } },
      ],
      rating: 4.7,
      reviewCount: 328,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
    {
      id: 'prod-2',
      name: 'Smart Watch Pro',
      description: 'Advanced fitness tracking, ECG monitoring, and 5-day battery life.',
      price: 449.99,
      images: ['watch-1.jpg', 'watch-2.jpg'],
      category: 'Electronics',
      tags: ['wearable', 'fitness', 'smartwatch'],
      variants: [
        { id: 'var-4', name: '40mm', price: 449.99, sku: 'SW-40', inStock: true, options: { size: '40mm' } },
        { id: 'var-5', name: '44mm', price: 479.99, sku: 'SW-44', inStock: true, options: { size: '44mm' } },
      ],
      rating: 4.5,
      reviewCount: 156,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
    {
      id: 'prod-3',
      name: 'Organic Cotton T-Shirt',
      description: '100% organic cotton, sustainably sourced and ethically made.',
      price: 34.99,
      images: ['tshirt-1.jpg'],
      category: 'Clothing',
      tags: ['organic', 'cotton', 'sustainable'],
      variants: [
        { id: 'var-6', name: 'S', price: 34.99, sku: 'TS-S', inStock: true, options: { size: 'S' } },
        { id: 'var-7', name: 'M', price: 34.99, sku: 'TS-M', inStock: true, options: { size: 'M' } },
        { id: 'var-8', name: 'L', price: 34.99, sku: 'TS-L', inStock: true, options: { size: 'L' } },
        { id: 'var-9', name: 'XL', price: 34.99, sku: 'TS-XL', inStock: false, options: { size: 'XL' } },
      ],
      rating: 4.8,
      reviewCount: 89,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
    {
      id: 'prod-4',
      name: 'Minimalist Backpack',
      description: 'Water-resistant backpack with laptop compartment and ergonomic design.',
      price: 89.99,
      compareAtPrice: 119.99,
      images: ['backpack-1.jpg', 'backpack-2.jpg'],
      category: 'Accessories',
      tags: ['backpack', 'laptop', 'travel'],
      variants: [
        { id: 'var-10', name: 'Default', price: 89.99, sku: 'BP-01', inStock: true, options: {} },
      ],
      rating: 4.6,
      reviewCount: 234,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
    {
      id: 'prod-5',
      name: 'Ceramic Pour-Over Set',
      description: 'Handcrafted ceramic pour-over coffee maker with carafe and filter holder.',
      price: 54.99,
      images: ['coffee-1.jpg'],
      category: 'Home',
      tags: ['coffee', 'ceramic', 'kitchen'],
      variants: [
        { id: 'var-11', name: 'White', price: 54.99, sku: 'PO-WHT', inStock: true, options: { color: 'White' } },
        { id: 'var-12', name: 'Black', price: 54.99, sku: 'PO-BLK', inStock: true, options: { color: 'Black' } },
      ],
      rating: 4.9,
      reviewCount: 67,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
    {
      id: 'prod-6',
      name: 'Running Shoes',
      description: 'Lightweight running shoes with responsive cushioning and breathable mesh.',
      price: 129.99,
      images: ['shoes-1.jpg', 'shoes-2.jpg'],
      category: 'Sports',
      tags: ['running', 'shoes', 'athletic'],
      variants: [
        { id: 'var-13', name: 'US 8', price: 129.99, sku: 'RS-8', inStock: true, options: { size: 'US 8' } },
        { id: 'var-14', name: 'US 9', price: 129.99, sku: 'RS-9', inStock: true, options: { size: 'US 9' } },
        { id: 'var-15', name: 'US 10', price: 129.99, sku: 'RS-10', inStock: true, options: { size: 'US 10' } },
        { id: 'var-16', name: 'US 11', price: 129.99, sku: 'RS-11', inStock: true, options: { size: 'US 11' } },
      ],
      rating: 4.4,
      reviewCount: 412,
      inStock: true,
      createdAt: new Date().toISOString(),
    },
  ]
}

// Utility functions
function generateId(): string {
  return `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
}

function formatPrice(price: number): string {
  return `$${price.toFixed(2)}`
}

function renderStars(rating: number): string {
  const fullStars = Math.floor(rating)
  const hasHalf = rating % 1 >= 0.5
  let stars = '★'.repeat(fullStars)
  if (hasHalf) stars += '½'
  stars += '☆'.repeat(5 - fullStars - (hasHalf ? 1 : 0))
  return stars
}

// UI Rendering
function renderApp(store: Store): void {
  const app = document.getElementById('app')
  if (!app) return

  const view = store.getView()

  let content = ''
  switch (view) {
    case 'home':
      content = renderHome(store)
      break
    case 'product':
      content = renderProductDetail(store)
      break
    case 'cart':
      content = renderCart(store)
      break
    case 'checkout':
      content = renderCheckout(store)
      break
    case 'orders':
      content = renderOrders(store)
      break
    case 'wishlist':
      content = renderWishlist(store)
      break
    case 'search':
      content = renderSearch(store)
      break
  }

  app.innerHTML = `
    <div class='shop-app'>
      ${renderHeader(store)}
      <main class='main-content'>${content}</main>
      ${renderBottomNav(store)}
    </div>
  `

  setupEventListeners(store)
}

function renderHeader(store: Store): string {
  const cart = store.getCart()
  const cartCount = cart.reduce((sum, i) => sum + i.quantity, 0)

  return `
    <header class='header'>
      <button class='menu-btn' id='menu-btn'>☰</button>
      <h1 class='logo' data-nav='home'>Shop</h1>
      <div class='header-actions'>
        <button class='icon-btn' id='search-btn'>🔍</button>
        <button class='cart-btn icon-btn' data-nav='cart'>
          🛒
          ${cartCount > 0 ? `<span class='cart-badge'>${cartCount}</span>` : ''}
        </button>
      </div>
    </header>
  `
}

function renderBottomNav(store: Store): string {
  const view = store.getView()
  return `
    <nav class='bottom-nav'>
      <button class="nav-item${view === 'home' ? ' active' : ''}" data-nav="home">
        <span class='nav-icon'>🏠</span>
        <span class='nav-label'>Home</span>
      </button>
      <button class="nav-item${view === 'search' ? ' active' : ''}" data-nav="search">
        <span class='nav-icon'>🔍</span>
        <span class='nav-label'>Search</span>
      </button>
      <button class="nav-item${view === 'wishlist' ? ' active' : ''}" data-nav="wishlist">
        <span class='nav-icon'>❤</span>
        <span class='nav-label'>Wishlist</span>
      </button>
      <button class="nav-item${view === 'orders' ? ' active' : ''}" data-nav="orders">
        <span class='nav-icon'>📦</span>
        <span class='nav-label'>Orders</span>
      </button>
    </nav>
  `
}

function renderHome(store: Store): string {
  const categories = store.getCategories()
  const selectedCategory = store.getCategory()
  const products = store.getProducts(selectedCategory)

  return `
    <div class='home-view'>
      <div class='categories-scroll'>
        ${categories.map((cat) => `
          <button class="category-chip${cat === selectedCategory ? ' active' : ''}" data-category="${cat}">
            ${cat === 'all' ? 'All' : cat}
          </button>
        `).join('')}
      </div>

      <section class='featured-section'>
        <h2>Featured Products</h2>
        <div class='products-grid'>
          ${products.map((product) => renderProductCard(product, store)).join('')}
        </div>
      </section>
    </div>
  `
}

function renderProductCard(product: Product, store: Store): string {
  const isWishlisted = store.isInWishlist(product.id)
  const discount = product.compareAtPrice
    ? Math.round((1 - product.price / product.compareAtPrice) * 100)
    : 0

  return `
    <div class='product-card' data-product-id='${product.id}'>
      <div class='product-image'>
        <div class='image-placeholder'>${product.name.charAt(0)}</div>
        ${discount > 0 ? `<span class='discount-badge'>-${discount}%</span>` : ''}
        <button class="wishlist-btn${isWishlisted ? ' active' : ''}" data-wishlist="${product.id}">
          ${isWishlisted ? '❤' : '♡'}
        </button>
      </div>
      <div class='product-info'>
        <h3 class='product-name'>${product.name}</h3>
        <div class='product-rating'>
          <span class='stars'>${renderStars(product.rating)}</span>
          <span class='review-count'>(${product.reviewCount})</span>
        </div>
        <div class='product-price'>
          <span class='current-price'>${formatPrice(product.price)}</span>
          ${product.compareAtPrice ? `<span class='compare-price'>${formatPrice(product.compareAtPrice)}</span>` : ''}
        </div>
      </div>
    </div>
  `
}

// eslint-disable-next-line pickier/no-unused-vars
function renderProductDetail(store: Store): string {
  const productId = store.getCurrentProductId()
  if (!productId) return '<div>Product not found</div>'

  const product = store.getProduct(productId)
  if (!product) return '<div>Product not found</div>'

  const isWishlisted = store.isInWishlist(product.id)

  return `
    <div class='product-detail'>
      <button class='back-btn' data-nav='home'>← Back</button>

      <div class='product-gallery'>
        <div class='main-image'>
          <div class='image-placeholder large'>${product.name.charAt(0)}</div>
        </div>
      </div>

      <div class='product-content'>
        <h1 class='product-title'>${product.name}</h1>
        <div class='product-rating'>
          <span class='stars'>${renderStars(product.rating)}</span>
          <span class='review-count'>${product.reviewCount} reviews</span>
        </div>

        <div class='product-price-large'>
          <span class='current-price'>${formatPrice(product.price)}</span>
          ${product.compareAtPrice ? `<span class='compare-price'>${formatPrice(product.compareAtPrice)}</span>` : ''}
        </div>

        <p class='product-description'>${product.description}</p>

        ${product.variants.length > 1 ? `
          <div class='variants-section'>
            <h3>Options</h3>
            <div class='variants-grid'>
              ${product.variants.map((v, i) => `
                <button class="variant-btn${i === 0 ? ' selected' : ''}${!v.inStock ? ' out-of-stock' : ''}"
                        data-variant-id="${v.id}"
                        ${!v.inStock ? 'disabled' : ''}>
                  ${v.name}
                </button>
              `).join('')}
            </div>
          </div>
        ` : ''}

        <div class='quantity-section'>
          <h3>Quantity</h3>
          <div class='quantity-selector'>
            <button class='qty-btn' id='qty-minus'>-</button>
            <span id='quantity'>1</span>
            <button class='qty-btn' id='qty-plus'>+</button>
          </div>
        </div>

        <div class='action-buttons'>
          <button class='add-to-cart-btn' id='add-to-cart'
                  data-product-id='${product.id}'
                  data-variant-id='${product.variants[0]?.id}'>
            Add to Cart - ${formatPrice(product.price)}
          </button>
          <button class="wishlist-btn-large${isWishlisted ? ' active' : ''}" data-wishlist="${product.id}">
            ${isWishlisted ? '❤ Saved' : '♡ Save'}
          </button>
        </div>
      </div>
    </div>
  `
}

function renderCart(store: Store): string {
  const cart = store.getCart()
  const totals = store.getCartTotal()

  if (cart.length === 0) {
    return `
      <div class='empty-state'>
        <div class='empty-icon'>🛒</div>
        <h2>Your cart is empty</h2>
        <p>Add some items to get started</p>
        <button class='primary-btn' data-nav='home'>Start Shopping</button>
      </div>
    `
  }

  return `
    <div class='cart-view'>
      <h1>Shopping Cart</h1>

      <div class='cart-items'>
        ${cart.map((item) => {
          const product = store.getProduct(item.productId)
          if (!product) return ''
          const variant = product.variants.find((v) => v.id === item.variantId)

          return `
            <div class='cart-item'>
              <div class='item-image'>
                <div class='image-placeholder small'>${product.name.charAt(0)}</div>
              </div>
              <div class='item-details'>
                <h3>${product.name}</h3>
                ${variant?.name !== 'Default' ? `<p class="variant-name">${variant?.name}</p>` : ''}
                <p class='item-price'>${formatPrice(item.price)}</p>
              </div>
              <div class='item-quantity'>
                <button class='qty-btn small' data-cart-qty='${item.productId}:${item.variantId}:-1'>-</button>
                <span>${item.quantity}</span>
                <button class='qty-btn small' data-cart-qty='${item.productId}:${item.variantId}:1'>+</button>
              </div>
              <button class='remove-btn' data-remove-cart='${item.productId}:${item.variantId}'>×</button>
            </div>
          `
        }).join('')}
      </div>

      <div class='cart-summary'>
        <div class='summary-row'>
          <span>Subtotal</span>
          <span>${formatPrice(totals.subtotal)}</span>
        </div>
        <div class='summary-row'>
          <span>Tax</span>
          <span>${formatPrice(totals.tax)}</span>
        </div>
        <div class='summary-row'>
          <span>Shipping</span>
          <span>${totals.shipping === 0 ? 'Free' : formatPrice(totals.shipping)}</span>
        </div>
        <div class='summary-row total'>
          <span>Total</span>
          <span>${formatPrice(totals.total)}</span>
        </div>
        <button class='checkout-btn' data-nav='checkout'>Proceed to Checkout</button>
      </div>
    </div>
  `
}

function renderCheckout(store: Store): string {
  return `
    <div class='checkout-view'>
      <button class='back-btn' data-nav='cart'>← Back to Cart</button>
      <h1>Checkout</h1>

      <form id='checkout-form' class='checkout-form'>
        <section class='form-section'>
          <h2>Shipping Address</h2>
          <div class='form-grid'>
            <input type='text' name='name' placeholder='Full Name' required class='form-input' />
            <input type='text' name='line1' placeholder='Address Line 1' required class='form-input full-width' />
            <input type='text' name='line2' placeholder='Address Line 2 (optional)' class='form-input full-width' />
            <input type='text' name='city' placeholder='City' required class='form-input' />
            <input type='text' name='state' placeholder='State' required class='form-input' />
            <input type='text' name='postalCode' placeholder='ZIP Code' required class='form-input' />
            <input type='text' name='country' placeholder='Country' value='United States' required class='form-input' />
            <input type='tel' name='phone' placeholder='Phone Number' required class='form-input' />
          </div>
        </section>

        <section class='form-section'>
          <h2>Payment Method</h2>
          <div class='payment-options'>
            <label class='payment-option'>
              <input type='radio' name='payment' value='card' checked />
              <span>💳 Credit Card</span>
            </label>
            <label class='payment-option'>
              <input type='radio' name='payment' value='apple-pay' />
              <span>🍎 Apple Pay</span>
            </label>
            <label class='payment-option'>
              <input type='radio' name='payment' value='paypal' />
              <span>💰 PayPal</span>
            </label>
          </div>
        </section>

        <div class='order-summary'>
          <h2>Order Summary</h2>
          <div class='summary-row total'>
            <span>Total</span>
            <span>${formatPrice(store.getCartTotal().total)}</span>
          </div>
        </div>

        <button type='submit' class='place-order-btn'>Place Order</button>
      </form>
    </div>
  `
}

function renderOrders(store: Store): string {
  const orders = store.getOrders()

  if (orders.length === 0) {
    return `
      <div class='empty-state'>
        <div class='empty-icon'>📦</div>
        <h2>No orders yet</h2>
        <p>Your order history will appear here</p>
        <button class='primary-btn' data-nav='home'>Start Shopping</button>
      </div>
    `
  }

  return `
    <div class='orders-view'>
      <h1>Order History</h1>
      <div class='orders-list'>
        ${orders.map((order) => `
          <div class='order-card'>
            <div class='order-header'>
              <span class='order-id'>Order #${order.id.slice(-8)}</span>
              <span class='order-status ${order.status}'>${order.status}</span>
            </div>
            <div class='order-date'>${new Date(order.createdAt).toLocaleDateString()}</div>
            <div class='order-items'>
              ${order.items.length} item${order.items.length > 1 ? 's' : ''}
            </div>
            <div class='order-total'>${formatPrice(order.total)}</div>
          </div>
        `).join('')}
      </div>
    </div>
  `
}

function renderWishlist(store: Store): string {
  const wishlist = store.getWishlist()

  if (wishlist.length === 0) {
    return `
      <div class='empty-state'>
        <div class='empty-icon'>❤</div>
        <h2>Your wishlist is empty</h2>
        <p>Save items you love for later</p>
        <button class='primary-btn' data-nav='home'>Explore Products</button>
      </div>
    `
  }

  return `
    <div class='wishlist-view'>
      <h1>Wishlist</h1>
      <div class='products-grid'>
        ${wishlist.map((product) => renderProductCard(product, store)).join('')}
      </div>
    </div>
  `
}

function renderSearch(store: Store): string {
  const query = store.getSearchQuery()
  const results = query ? store.searchProducts(query) : []

  return `
    <div class='search-view'>
      <div class='search-bar'>
        <input type='search' id='search-input' placeholder='Search products...'
          value='${query}' class='search-input' autofocus />
      </div>

      ${query ? `
        <p class='search-results-count'>${results.length} result${results.length !== 1 ? 's' : ''} for '${query}'</p>
        <div class='products-grid'>
          ${results.map((product) => renderProductCard(product, store)).join('')}
        </div>
      ` : `
        <div class='search-suggestions'>
          <h3>Popular Searches</h3>
          <div class='suggestion-chips'>
            <button class='suggestion-chip' data-search='headphones'>Headphones</button>
            <button class='suggestion-chip' data-search='watch'>Watch</button>
            <button class='suggestion-chip' data-search='backpack'>Backpack</button>
            <button class='suggestion-chip' data-search='shoes'>Shoes</button>
          </div>
        </div>
      `}
    </div>
  `
}

function setupEventListeners(store: Store): void {
  // Navigation
  document.querySelectorAll('[data-nav]').forEach((el) => {
    el.addEventListener('click', () => {
      const view = el.getAttribute('data-nav') as any
      store.setView(view)
      renderApp(store)
    })
  })

  // Product cards
  document.querySelectorAll('.product-card').forEach((card) => {
    card.addEventListener('click', (e) => {
      if ((e.target as HTMLElement).closest('[data-wishlist]')) return
      const productId = card.getAttribute('data-product-id')
      if (productId) {
        store.setView('product', productId)
        renderApp(store)
      }
    })
  })

  // Wishlist buttons
  document.querySelectorAll('[data-wishlist]').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation()
      const productId = btn.getAttribute('data-wishlist')
      if (productId) {
        if (store.isInWishlist(productId)) {
          store.removeFromWishlist(productId)
        }
else {
          store.addToWishlist(productId)
        }
        renderApp(store)
      }
    })
  })

  // Category filters
  document.querySelectorAll('[data-category]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const category = btn.getAttribute('data-category')
      if (category) {
        store.setCategory(category)
        renderApp(store)
      }
    })
  })

  // Add to cart
  document.getElementById('add-to-cart')?.addEventListener('click', () => {
    const btn = document.getElementById('add-to-cart')
    const productId = btn?.getAttribute('data-product-id')
    const variantId = btn?.getAttribute('data-variant-id')
    const quantity = parseInt(document.getElementById('quantity')?.textContent || '1')
    if (productId && variantId) {
      store.addToCart(productId, variantId, quantity)
      renderApp(store)
    }
  })

  // Quantity selectors (product page)
  document.getElementById('qty-minus')?.addEventListener('click', () => {
    const qtyEl = document.getElementById('quantity')
    if (qtyEl) {
      const current = parseInt(qtyEl.textContent || '1')
      if (current > 1) qtyEl.textContent = String(current - 1)
    }
  })

  document.getElementById('qty-plus')?.addEventListener('click', () => {
    const qtyEl = document.getElementById('quantity')
    if (qtyEl) {
      const current = parseInt(qtyEl.textContent || '1')
      qtyEl.textContent = String(current + 1)
    }
  })

  // Cart quantity
  document.querySelectorAll('[data-cart-qty]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const [productId, variantId, delta] = btn.getAttribute('data-cart-qty')!.split(':')
      const cart = store.getCart()
      const item = cart.find((i) => i.productId === productId && i.variantId === variantId)
      if (item) {
        store.updateCartQuantity(productId, variantId, item.quantity + parseInt(delta))
        renderApp(store)
      }
    })
  })

  // Remove from cart
  document.querySelectorAll('[data-remove-cart]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const [productId, variantId] = btn.getAttribute('data-remove-cart')!.split(':')
      store.removeFromCart(productId, variantId)
      renderApp(store)
    })
  })

  // Search
  document.getElementById('search-input')?.addEventListener('input', (e) => {
    const query = (e.target as HTMLInputElement).value
    store.setSearchQuery(query)
    renderApp(store)
  })

  document.querySelectorAll('[data-search]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const query = btn.getAttribute('data-search')
      if (query) {
        store.setSearchQuery(query)
        renderApp(store)
      }
    })
  })

  // Checkout form
  document.getElementById('checkout-form')?.addEventListener('submit', async (e) => {
    e.preventDefault()
    const form = e.target as HTMLFormElement
    const formData = new FormData(form)

    const address: Address = {
      name: formData.get('name') as string,
      line1: formData.get('line1') as string,
      line2: formData.get('line2') as string || undefined,
      city: formData.get('city') as string,
      state: formData.get('state') as string,
      postalCode: formData.get('postalCode') as string,
      country: formData.get('country') as string,
      phone: formData.get('phone') as string,
    }

    const paymentMethod = formData.get('payment') as string

    await store.createOrder(address, paymentMethod)
    store.setView('orders')
    renderApp(store)

    if (Platform.OS === 'ios' || Platform.OS === 'android') {
      haptics.notification('success')
    }
  })

  // Variant selection
  document.querySelectorAll('.variant-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.variant-btn').forEach((b) => b.classList.remove('selected'))
      btn.classList.add('selected')
      const variantId = btn.getAttribute('data-variant-id')
      const addBtn = document.getElementById('add-to-cart')
      if (addBtn && variantId) {
        addBtn.setAttribute('data-variant-id', variantId)
      }
    })
  })
}

// Main app initialization
async function main(): Promise<void> {
  await initDatabase()

  window.setTitle('Shop')
  window.setSize(400, 800)
  window.setMinSize(320, 568)

  const store = new Store()
  await store.loadState()
  store.setProducts(getMockProducts())

  // Subscribe to store updates
  store.subscribe(() => renderApp(store))

  // Initial render
  renderApp(store)

  // Expose for debugging
  ;(globalThis as any).store = store
}

main().catch(console.error)

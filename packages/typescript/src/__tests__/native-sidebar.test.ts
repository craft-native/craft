import { describe, expect, it } from 'bun:test'
import { CraftApp, createApp, type AppConfig } from '../index'

describe('Native Sidebar', () => {
  describe('createApp with native sidebar config', () => {
    it('should accept nativeSidebar option', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarWidth: 240,
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should accept sidebarConfig with sections', () => {
      const sidebarConfig = {
        sections: [
          {
            id: 'home',
            title: 'Home',
            items: [
              { id: 'dashboard', label: 'Dashboard', icon: 'house.fill', url: '/dashboard' },
            ],
          },
        ],
        minWidth: 200,
        maxWidth: 280,
      }

      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarWidth: 240,
          sidebarConfig,
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should normalize desktop sidebar material options into argv config', () => {
      const app = new (CraftApp as unknown as { new(c: AppConfig): { buildArgs(): string[] } })({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarWidth: 260,
          sidebarVariant: 'desktop',
          sidebarConfig: {
            sections: [
              {
                id: 'main',
                title: 'Main',
                items: [{ id: 'compose', label: 'Compose', icon: 'square.and.pencil', url: '/compose' }],
              },
            ],
          },
        },
      })

      const args = app.buildArgs()
      const config = JSON.parse(args[args.indexOf('--sidebar-config') + 1])
      expect(config.variant).toBe('desktop')
      expect(config.material).toBe('sidebar')
      expect(config.backgroundEffect).toBe('vibrancy')
      expect(config.allowsVibrancy).toBe(true)
    })

    it('should pass web sidebar material options to the native binary', () => {
      const app = new (CraftApp as unknown as { new(c: AppConfig): { buildArgs(): string[] } })({
        url: 'http://localhost:3456/app',
        window: {
          titlebarHidden: true,
          webSidebarMaterial: true,
          webSidebarWidth: 286,
          webSidebarMaterialOpacity: 0.9,
        },
      })

      const args = app.buildArgs()
      expect(args).toContain('--titlebar-hidden')
      expect(args).toContain('--web-sidebar-material')
      expect(args).toContain('--web-sidebar-width')
      expect(args[args.indexOf('--web-sidebar-width') + 1]).toBe('286')
      expect(args).toContain('--web-sidebar-material-opacity')
      expect(args[args.indexOf('--web-sidebar-material-opacity') + 1]).toBe('0.9')
    })

    it('sends the window span as its own flag, and never both spans at once', () => {
      const app = new (CraftApp as unknown as { new(c: AppConfig): { buildArgs(): string[] } })({
        url: 'http://localhost:3456/app',
        window: {
          titlebarHidden: true,
          // Both asked for. The binary resolves this in favour of the window
          // span; the SDK must not send a pair whose meaning depends on that.
          webSidebarMaterial: true,
          webWindowMaterial: true,
          webSidebarMaterialOpacity: 0.9,
        },
      })

      const args = app.buildArgs()
      expect(args).toContain('--web-window-material')
      expect(args).not.toContain('--web-sidebar-material')
      expect(args).not.toContain('--web-sidebar-material-opacity')
    })

    it('should work without sidebarConfig', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should default nativeSidebar to false', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
      })
      expect(app).toBeInstanceOf(CraftApp)
    })
  })

  describe('native sidebar with dashboard-like config', () => {
    it('should handle full dashboard configuration', () => {
      const config: AppConfig = {
        url: 'http://localhost:3456/app?native-sidebar=1',
        window: {
          title: 'Stacks Dashboard',
          width: 1400,
          height: 900,
          titlebarHidden: true,
          nativeSidebar: true,
          sidebarWidth: 240,
          sidebarConfig: {
            sections: [
              {
                id: 'home',
                title: 'Home',
                items: [
                  { id: 'home', label: 'Dashboard', icon: 'house.fill', url: '/pages/index' },
                ],
              },
              {
                id: 'data',
                title: 'Data',
                items: [
                  { id: 'data-dashboard', label: 'Dashboard', icon: 'gauge', url: '/pages/data/dashboard' },
                  { id: 'model-user', label: 'User', icon: 'person.fill', url: '/pages/data/user' },
                ],
              },
            ],
            minWidth: 200,
            maxWidth: 280,
          },
        },
      }

      const app = createApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should handle URL with native-sidebar query param', () => {
      const app = createApp({
        url: 'http://localhost:3456/app?native-sidebar=1',
        window: {
          nativeSidebar: true,
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })
  })

  describe('sidebar config validation', () => {
    it('should handle empty sections array', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarConfig: {
            sections: [],
          },
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should handle sections with multiple items', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarConfig: {
            sections: [
              {
                id: 'content',
                title: 'Content',
                items: [
                  { id: 'pages', label: 'Pages', icon: 'doc.fill', url: '/pages' },
                  { id: 'posts', label: 'Posts', icon: 'text.bubble.fill', url: '/posts' },
                  { id: 'tags', label: 'Tags', icon: 'tag', url: '/tags' },
                  { id: 'categories', label: 'Categories', icon: 'tag.fill', url: '/categories' },
                ],
              },
            ],
          },
        },
      })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should handle custom sidebar widths', () => {
      const narrow = createApp({
        url: 'http://localhost:3456/app',
        window: { nativeSidebar: true, sidebarWidth: 150 },
      })
      const wide = createApp({
        url: 'http://localhost:3456/app',
        window: { nativeSidebar: true, sidebarWidth: 400 },
      })
      expect(narrow).toBeInstanceOf(CraftApp)
      expect(wide).toBeInstanceOf(CraftApp)
    })
  })

  describe('close with native sidebar', () => {
    it('should not throw when closing native sidebar app', () => {
      const app = createApp({
        url: 'http://localhost:3456/app',
        window: {
          nativeSidebar: true,
          sidebarWidth: 240,
          sidebarConfig: {
            sections: [
              {
                id: 'test',
                title: 'Test',
                items: [{ id: 'item', label: 'Item', icon: 'star', url: '/test' }],
              },
            ],
          },
        },
      })
      expect(() => app.close()).not.toThrow()
    })
  })
})

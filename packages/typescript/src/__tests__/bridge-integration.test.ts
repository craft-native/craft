/**
 * Integration tests for Craft JavaScript Bridge
 * These tests verify that the bridge API is properly typed and accessible
 */

import { describe, test, expect } from 'bun:test'
import type { CraftBridgeAPI, CraftTrayAPI, CraftWindowAPI, CraftAppAPI, MenuItem } from '../types'

const readTrayState: CraftTrayAPI['getState'] = async () => ({ title: '', tooltip: '', visible: true, hasIcon: false, template: false, imageWidth: 0, imageHeight: 0, imagePosition: 0 })

describe('Bridge Type Definitions', () => {
  test('should have correct CraftBridgeAPI structure', () => {
    // This is a compile-time test - if it compiles, the types are correct
    const mockBridge: CraftBridgeAPI = {
      tray: {
        getState: readTrayState,
        setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
        setTooltip: async (_tooltip: string) => {},
        onClick: (_callback: (event: any) => void) => () => {},
        onClickToggleWindow: () => () => {},
        setMenu: async (_items: MenuItem[]) => {},
      },
      window: {
        show: async () => {},
        hide: async () => {},
        toggle: async () => {},
        minimize: async () => {},
        close: async () => {},
      },
      app: {
        icon: async () => null,
      hideDockIcon: async () => {},
        showDockIcon: async () => {},
        quit: async () => {},
        notify: async () => {},
        getInfo: async () => ({
          name: 'Test App',
          version: '1.0.0',
          platform: 'macos',
        }),
        setAppearance: async (_appearance: 'light' | 'dark' | 'system') => {},
        getAppearance: async () => 'light',
      },
    }

    expect(mockBridge.tray).toBeDefined()
    expect(mockBridge.window).toBeDefined()
    expect(mockBridge.app).toBeDefined()
  })

  test('should have correct CraftTrayAPI methods', () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
      setTooltip: async (_tooltip: string) => {},
      onClick: (_callback: (event: any) => void) => () => {},
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    expect(typeof mockTray.setTitle).toBe('function')
    expect(typeof mockTray.setTooltip).toBe('function')
    expect(typeof mockTray.onClick).toBe('function')
    expect(typeof mockTray.onClickToggleWindow).toBe('function')
    expect(typeof mockTray.setMenu).toBe('function')
  })

  test('should have correct CraftWindowAPI methods', () => {
    const mockWindow: CraftWindowAPI = {
      show: async () => {},
      hide: async () => {},
      toggle: async () => {},
      minimize: async () => {},
      close: async () => {},
    }

    expect(typeof mockWindow.show).toBe('function')
    expect(typeof mockWindow.hide).toBe('function')
    expect(typeof mockWindow.toggle).toBe('function')
    expect(typeof mockWindow.minimize).toBe('function')
    expect(typeof mockWindow.close).toBe('function')
  })

  test('should have correct CraftAppAPI methods', () => {
    const mockApp: CraftAppAPI = {
      icon: async () => null,
      hideDockIcon: async () => {},
      showDockIcon: async () => {},
      quit: async () => {},
      notify: async () => {},
      getInfo: async () => ({
        name: 'Test App',
        version: '1.0.0',
        platform: 'macos',
      }),
      setAppearance: async (_appearance: 'light' | 'dark' | 'system') => {},
      getAppearance: async () => 'light',
    }

    expect(typeof mockApp.hideDockIcon).toBe('function')
    expect(typeof mockApp.showDockIcon).toBe('function')
    expect(typeof mockApp.quit).toBe('function')
    expect(typeof mockApp.getInfo).toBe('function')
  })
})

describe('MenuItem Type Definition', () => {
  test('should support normal menu items', () => {
    const item: MenuItem = {
      id: 'test',
      label: 'Test Item',
      type: 'normal',
      enabled: true,
      action: 'show',
    }

    expect(item.id).toBe('test')
    expect(item.label).toBe('Test Item')
    expect(item.type).toBe('normal')
    expect(item.enabled).toBe(true)
    expect(item.action).toBe('show')
  })

  test('should support separator items', () => {
    const item: MenuItem = {
      type: 'separator',
    }

    expect(item.type).toBe('separator')
  })

  test('should support checkbox items', () => {
    const item: MenuItem = {
      id: 'checkbox',
      label: 'Check Me',
      type: 'checkbox',
      checked: true,
    }

    expect(item.type).toBe('checkbox')
    expect(item.checked).toBe(true)
  })

  test('should support submenu items', () => {
    const item: MenuItem = {
      label: 'Parent',
      submenu: [
        { label: 'Child 1', action: 'show' },
        { label: 'Child 2', action: 'hide' },
      ],
    }

    expect(item.submenu).toBeDefined()
    expect(item.submenu?.length).toBe(2)
  })

  test('should support keyboard shortcuts', () => {
    const item: MenuItem = {
      label: 'Quit',
      action: 'quit',
      shortcut: 'Cmd+Q',
    }

    expect(item.shortcut).toBe('Cmd+Q')
  })
})

describe('TrayClickEvent Type Definition', () => {
  test('should have correct event structure', () => {
    const event = {
      button: 'left' as const,
      timestamp: Date.now(),
      modifiers: {
        command: true,
        shift: false,
        option: false,
        control: false,
      },
    }

    expect(event.button).toBe('left')
    expect(typeof event.timestamp).toBe('number')
    expect(event.modifiers.command).toBe(true)
  })

  test('should support different button types', () => {
    const buttons: Array<'left' | 'right' | 'middle'> = ['left', 'right', 'middle']

    for (const button of buttons) {
      const event = {
        button,
        timestamp: Date.now(),
        modifiers: {},
      }
      expect(['left', 'right', 'middle']).toContain(event.button)
    }
  })
})

describe('Bridge API Method Signatures', () => {
  test('tray.setTitle should accept string parameter', async () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (title: string) => {
        expect(typeof title).toBe('string')
      },
      setTooltip: async (_tooltip: string) => {},
      onClick: (_callback: (event: any) => void) => () => {},
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    await mockTray.setTitle('Test Title')
  })

  test('tray.setTooltip should accept string parameter', async () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
      setTooltip: async (tooltip: string) => {
        expect(typeof tooltip).toBe('string')
      },
      onClick: (_callback: (event: any) => void) => () => {},
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    await mockTray.setTooltip('Test Tooltip')
  })

  test('tray.onClick should accept callback and return unregister function', () => {
    let callbackCalled = false

    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
      setTooltip: async (_tooltip: string) => {},
      onClick: (callback: (event: any) => void) => {
        // Simulate click
        callback({ button: 'left', timestamp: Date.now(), modifiers: {} })
        callbackCalled = true
        return () => {} // unregister function
      },
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    const unregister = mockTray.onClick((event) => {
      expect(event.button).toBe('left')
    })

    expect(typeof unregister).toBe('function')
    expect(callbackCalled).toBe(true)
  })

  test('tray.setMenu should accept MenuItem array', async () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
      setTooltip: async (_tooltip: string) => {},
      onClick: (_callback: (event: any) => void) => () => {},
      onClickToggleWindow: () => () => {},
      setMenu: async (items: MenuItem[]) => {
        expect(Array.isArray(items)).toBe(true)
        expect(items.length).toBeGreaterThan(0)
      },
    }

    await mockTray.setMenu([
      { label: 'Show', action: 'show' },
      { type: 'separator' },
      { label: 'Quit', action: 'quit' },
    ])
  })

  test('window methods should return promises', async () => {
    const mockWindow: CraftWindowAPI = {
      show: async () => {},
      hide: async () => {},
      toggle: async () => {},
      minimize: async () => {},
      close: async () => {},
    }

    await expect(mockWindow.show()).resolves.toBeUndefined()
    await expect(mockWindow.hide()).resolves.toBeUndefined()
    await expect(mockWindow.toggle()).resolves.toBeUndefined()
    await expect(mockWindow.minimize()).resolves.toBeUndefined()
    await expect(mockWindow.close()).resolves.toBeUndefined()
  })

  test('app.getInfo should return AppInfo', async () => {
    const mockApp: CraftAppAPI = {
      icon: async () => null,
      hideDockIcon: async () => {},
      showDockIcon: async () => {},
      quit: async () => {},
      notify: async () => {},
      getInfo: async () => ({
        name: 'Test App',
        version: '1.0.0',
        platform: 'macos',
      }),
      setAppearance: async (_appearance: 'light' | 'dark' | 'system') => {},
      getAppearance: async () => 'light',
    }

    const info = await mockApp.getInfo()
    expect(info.name).toBe('Test App')
    expect(info.version).toBe('1.0.0')
    expect(info.platform).toBe('macos')
  })
})

describe('Window Global Type Augmentation', () => {
  test('should extend Window interface', () => {
    // This is a compile-time test
    // If this compiles, the Window interface is properly augmented

    // Mock window.craft for testing
    const mockWindow = {
      craft: {
        tray: {
        getState: readTrayState,
          setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
          setTooltip: async (_tooltip: string) => {},
          onClick: (_callback: (event: any) => void) => () => {},
          onClickToggleWindow: () => () => {},
          setMenu: async (_items: MenuItem[]) => {},
        },
        window: {
          show: async () => {},
          hide: async () => {},
          toggle: async () => {},
          minimize: async () => {},
          close: async () => {},
        },
        app: {
          icon: async () => null,
      hideDockIcon: async () => {},
          showDockIcon: async () => {},
          quit: async () => {},
          notify: async () => {},
          getInfo: async () => ({
            name: 'Test App',
            version: '1.0.0',
            platform: 'macos',
          }),
          setAppearance: async (_appearance: 'light' | 'dark' | 'system') => {},
          getAppearance: async () => 'light',
        },
      } as CraftBridgeAPI,
    }

    expect(mockWindow.craft).toBeDefined()
    expect(mockWindow.craft.tray).toBeDefined()
    expect(mockWindow.craft.window).toBeDefined()
    expect(mockWindow.craft.app).toBeDefined()
  })
})

describe('Error Handling', () => {
  test('should handle API errors gracefully', async () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {
        throw new Error('Native error')
      },
      setTooltip: async (_tooltip: string) => {},
      onClick: (_callback: (event: any) => void) => () => {},
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    await expect(mockTray.setTitle('Test')).rejects.toThrow('Native error')
  })

  test('should handle callback errors gracefully', () => {
    const mockTray: CraftTrayAPI = {
        getState: readTrayState,
      setIcon: async (_icon: string) => {},
      setTitle: async (_title: string) => {},
      setTooltip: async (_tooltip: string) => {},
      onClick: (callback: (event: any) => void) => {
        try {
          callback({ button: 'left', timestamp: Date.now(), modifiers: {} })
        }
catch (error) {
          // Errors in callbacks should be caught
          expect(error).toBeDefined()
        }
        return () => {}
      },
      onClickToggleWindow: () => () => {},
      setMenu: async (_items: MenuItem[]) => {},
    }

    mockTray.onClick(() => {
      throw new Error('Callback error')
    })
  })
})

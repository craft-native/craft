import { describe, expect, it, beforeEach } from 'bun:test'
import { CraftApp, craftProcessFailedMessage, createApp, parseCraftVersionOutput, type WindowOptions, type AppConfig } from '../index'

describe('CraftApp', () => {
  describe('constructor', () => {
    it('should create app with default config', () => {
      const app = new CraftApp()
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should accept custom window options', () => {
      const config: AppConfig = {
        window: {
          title: 'Test App',
          width: 1024,
          height: 768,
        },
      }
      const app = new CraftApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should merge custom options with defaults', () => {
      const config: AppConfig = {
        window: {
          title: 'Test App',
        },
      }
      const app = new CraftApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should accept HTML content', () => {
      const config: AppConfig = {
        html: '<h1>Test</h1>',
      }
      const app = new CraftApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should accept URL', () => {
      const config: AppConfig = {
        url: 'http://localhost:3000',
      }
      const app = new CraftApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })
  })

  describe('Window options', () => {
    it('should handle all boolean flags', () => {
      const options: WindowOptions = {
        frameless: true,
        transparent: true,
        alwaysOnTop: true,
        fullscreen: true,
        resizable: false,
        darkMode: true,
        hotReload: true,
        devTools: true,
        systemTray: true,
      }
      const app = new CraftApp({ window: options })
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should handle position and size options', () => {
      const options: WindowOptions = {
        x: 100,
        y: 200,
        width: 1920,
        height: 1080,
      }
      const app = new CraftApp({ window: options })
      expect(app).toBeInstanceOf(CraftApp)
    })
  })

  describe('close', () => {
    it('should not throw when closing app with no process', () => {
      const app = new CraftApp()
      expect(() => app.close()).not.toThrow()
    })
  })
})

describe('Helper functions', () => {
  describe('parseCraftVersionOutput', () => {
    it('extracts the semantic version from the native CLI report', () => {
      expect(parseCraftVersionOutput(
        'craft version 0.0.64\nBuilt with Zig 0.17.0-dev\nPlatform: macOS\n',
      )).toBe('0.0.64')
    })

    it('accepts compact registry binaries that print only a version', () => {
      expect(parseCraftVersionOutput('v0.0.64\n')).toBe('0.0.64')
    })

    // #236: this is the CLI's own form, and the platform suffix used to
    // survive the strip, so the whole line was compared against a semver.
    // Two halves of one checkout were reported as drift — and that warning
    // was the only signal a user got for a failure it had nothing to do with.
    it('reads the CLI form, whose version is followed by the platform', () => {
      expect(parseCraftVersionOutput('craft/0.0.92 darwin-arm64 bun-v1.4.1\n')).toBe('0.0.92')
    })

    it('reads a bare name and version, and a bare version', () => {
      expect(parseCraftVersionOutput('craft 0.0.92\n')).toBe('0.0.92')
      expect(parseCraftVersionOutput('0.0.92\n')).toBe('0.0.92')
    })

    it('answers nothing for output that carries no version at all', () => {
      expect(parseCraftVersionOutput('')).toBe('')
    })
  })

  describe('craftProcessFailedMessage', () => {
    // #236: `quiet` mapped to stdio: 'ignore', so the child's explanation was
    // discarded and the error then told the caller to read output that no
    // longer existed. A dashboard passing `quiet: !verbose` saw only the code.
    it('leads with what the child said, when it said anything', () => {
      const message = craftProcessFailedMessage(1, '"/Users/me/.bun/bin/craft" on PATH is the Craft CLI\n', true)
      expect(message).toContain('exited with code 1')
      expect(message).toContain('on PATH is the Craft CLI')
      expect(message).not.toContain('console output above')
    })

    it('does not point a quiet caller at output that was never printed', () => {
      const message = craftProcessFailedMessage(1, '', true)
      expect(message).not.toContain('console output above')
      expect(message).toContain('quiet')
    })

    it('still points an inheriting caller at its own console', () => {
      const message = craftProcessFailedMessage(1, '', false)
      expect(message).toContain('console output above')
    })
  })

  describe('createApp', () => {
    it('should create CraftApp instance', () => {
      const app = createApp()
      expect(app).toBeInstanceOf(CraftApp)
    })

    it('should accept config', () => {
      const config: AppConfig = {
        window: { title: 'Helper Test' },
      }
      const app = createApp(config)
      expect(app).toBeInstanceOf(CraftApp)
    })
  })
})

describe('Type exports', () => {
  it('should export WindowOptions type', () => {
    const options: WindowOptions = {
      title: 'Test',
      width: 800,
      height: 600,
    }
    expect(options.title).toBe('Test')
  })

  it('should export AppConfig type', () => {
    const config: AppConfig = {
      html: '<h1>Test</h1>',
      window: {
        title: 'Test',
      },
    }
    expect(config.html).toBe('<h1>Test</h1>')
  })
})

describe('Configuration validation', () => {
  it('should handle empty config', () => {
    const app = new CraftApp({})
    expect(app).toBeInstanceOf(CraftApp)
  })

  it('should handle partial window config', () => {
    const app = new CraftApp({
      window: {
        width: 1200,
      },
    })
    expect(app).toBeInstanceOf(CraftApp)
  })

  it('should handle custom craftPath', () => {
    const app = new CraftApp({
      craftPath: '/custom/path/to/craft',
    })
    expect(app).toBeInstanceOf(CraftApp)
  })
})

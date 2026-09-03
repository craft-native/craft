# Contributing to Craft

Thank you for your interest in contributing to Craft! This document provides guidelines and instructions for contributing.

## Development Setup

### Prerequisites

- **Pantry-managed stable Zig**: run `eval "$(pantry env | sed -n '/^export /,$p')"`, then invoke `zig` (locally only — CI does not: the pantry action already puts `zig` on PATH, and `pantry env` runs a workspace setup that re-installs JS deps with its own `--linker`, rewriting `node_modules` mid-job)
- **Bun**: Install from [bun.sh](https://bun.sh)

#### Platform-specific Dependencies

**macOS:**

```bash
# macOS has native WebKit support, no additional dependencies needed
```

**Linux:**

```bash
sudo apt-get update
sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev
```

**Windows:**

```bash
# Windows support is in development
```

### Clone the Repository

```bash
git clone https://github.com/craft-native/craft.git
cd craft
```

### Build from Source

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run tests
zig build test

# Run example
zig build run

# Run the craft CLI
zig build run
```

## Project Structure

```
craft/
├── src/              # Zig source code
│   ├── main.zig      # Main library entry point
│   ├── api.zig       # Public API
│   ├── macos.zig     # macOS implementation
│   ├── linux.zig     # Linux implementation
│   ├── windows.zig   # Windows implementation
│   └── ...           # Feature modules
├── build.zig         # Zig build configuration
├── bin/              # CLI wrapper scripts
├── scripts/          # Build and release scripts
├── docs/             # Documentation
├── examples/         # Example applications
└── .github/          # CI/CD workflows
```

## Development Workflow

### 1. Create a Branch

```bash
git checkout -b feature/your-feature-name
```

### 2. Make Changes

- Write clean, well-documented code
- Follow Zig's style guide
- Add tests for new functionality
- Update documentation as needed

### 3. Format Code

```bash
bun run fmt
```

### 4. Test Your Changes

```bash
# Run all tests
bun run test

# Build and run
zig build
zig build run
```

### 5. Commit Changes

```bash
git add .
git commit -m "feat: add your feature description"
```

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `chore:` - Maintenance tasks
- `refactor:` - Code refactoring
- `test:` - Test changes
- `perf:` - Performance improvements

### 6. Push and Create PR

```bash
git push origin feature/your-feature-name
```

Then open a Pull Request on GitHub.

## Code Style

### Zig Code Style

- Use `zig fmt` for automatic formatting
- Follow standard Zig naming conventions:
  - `camelCase` for functions and variables
  - `PascalCase` for types and structs
  - `SCREAMING_SNAKE_CASE` for constants
- Add doc comments for public APIs

Example:

```zig
/// Creates a new window with the given options.
/// Returns an error if the window cannot be created.
pub fn createWindow(options: WindowOptions) !Window {
    // Implementation
}
```

### JavaScript/TypeScript Code Style

- Use Bun's built-in formatter
- Follow modern ES6+ conventions
- Use TypeScript types where applicable

## Testing

### Unit Tests

Add tests in the same file as your implementation:

```zig
test "window creation" {
    const window = try Window.create(.{
        .title = "Test",
        .width = 800,
        .height = 600,
    });
    defer window.destroy();

    try std.testing.expect(window.width == 800);
}
```

### Integration Tests

Add examples in the `examples/` directory to demonstrate new features.

## Documentation

### Code Documentation

- Add doc comments to all public APIs
- Include examples in doc comments
- Document edge cases and error conditions

### User Documentation

- Update `README.md` for user-facing changes
- Update `API_REFERENCE.md` for API changes
- Add guides to `docs/` for complex features

## Platform Support

### Adding Platform-Specific Code

Platform-specific code should be isolated in dedicated files:

- `src/macos.zig` - macOS implementations
- `src/linux.zig` - Linux implementations
- `src/windows.zig` - Windows implementations

Use compile-time conditionals in `build.zig` for platform detection.

## Release Process

Releases are automated through GitHub Actions:

1. Update version in `package.json`
2. Create and push a git tag:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. GitHub Actions will:
   - Build binaries for all platforms
   - Create GitHub release
   - Publish to npm
   - Generate changelog

## Getting Help

- **Questions**: Open a [Discussion](https://github.com/craft-native/craft/discussions)
- **Bugs**: Open an [Issue](https://github.com/craft-native/craft/issues)
- **Chat**: Join our community channels

## License

By contributing to Craft, you agree that your contributions will be licensed under the MIT License.

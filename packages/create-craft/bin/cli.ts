#!/usr/bin/env bun

/**
 * create-craft - Scaffold a new Craft desktop app project
 */

import { CLI } from '@stacksjs/clapp'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import process from 'node:process'

// Read the current version from the package's own package.json (which stays in sync via bumpx --recursive)
const craftVersion = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf-8')).version

const cli = new CLI('create-craft')

/**
 * Validate a project name against npm's package-name rules so the generated
 * package.json is always parseable by npm/bun and free of shell metacharacters
 * that could leak into commands like `bun install <name>`.
 *
 * Rules (subset of validate-npm-package-name):
 *   - 1..214 characters
 *   - lowercase letters, digits, and `-`, `_`, `.`
 *   - must start with letter or digit (no leading dot/underscore)
 *   - no whitespace, slashes, or path separators
 */
function validateProjectName(name: string): void {
  if (typeof name !== 'string' || name.length === 0) {
    throw new Error('Project name must be a non-empty string')
  }
  if (name.length > 214) {
    throw new Error('Project name must be 214 characters or fewer')
  }
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(name)) {
    throw new Error(
      `Invalid project name "${name}". `
      + 'Use lowercase letters, digits, dot, underscore, and dash only; must start with a letter or digit.',
    )
  }
}

// Default command - create a new project
cli
  .command('[project-name]', 'Create a new Craft desktop app')
  .option('--template <template>', 'Template to use', { default: 'minimal' })
  .option('--skip-install', 'Skip installing dependencies', { default: false })
  .example('create-craft my-app')
  .example('create-craft my-app --template full-featured')
  .example('bun create craft my-app')
  .action(async (projectName?: string, options?: any) => {
    if (!projectName) {
      console.error('Error: Project name is required')
      console.log('\nUsage: create-craft <project-name>')
      console.log('Example: create-craft my-app')
      process.exit(1)
    }

    try {
      validateProjectName(projectName)
    }
    catch (e) {
      console.error(`Error: ${(e as Error).message}`)
      process.exit(2)
    }

    const template = options?.template || 'minimal'
    if (!['minimal', 'full-featured', 'todo-app'].includes(template)) {
      console.error(`Error: Unknown template "${template}"`)
      console.error('Available templates: minimal, full-featured, todo-app')
      process.exit(1)
    }
    const skipInstall = options?.skipInstall || false

    console.log(`\n✨ Creating a new Craft app: ${projectName}`)
    console.log(`📦 Template: ${template}\n`)

    const projectPath = resolve(process.cwd(), projectName)

    // Check if directory already exists
    if (existsSync(projectPath)) {
      console.error(`Error: Directory "${projectName}" already exists`)
      process.exit(1)
    }

    // Create project directory
    mkdirSync(projectPath, { recursive: true })

    // Generate project based on template
    if (template === 'minimal') {
      createMinimalTemplate(projectPath, projectName)
    }
    else if (template === 'full-featured') {
      createFullFeaturedTemplate(projectPath, projectName)
    }
    else if (template === 'todo-app') {
      createTodoAppTemplate(projectPath, projectName)
    }

    // Install dependencies unless skipped
    if (!skipInstall) {
      console.log('\n📦 Installing dependencies...\n')
      await installDependencies(projectPath)
    }

    // Success message
    console.log('\n✅ Project created successfully!\n')
    console.log('Next steps:')
    console.log(`  cd ${projectName}`)
    if (skipInstall) {
      console.log('  bun install')
    }
    console.log('  bun run dev\n')
  })

// List available templates
cli
  .command('list', 'List available templates')
  .action(() => {
    console.log('\n📋 Available templates:\n')
    console.log('  minimal        - Simplest possible Craft app')
    console.log('  full-featured  - Modern styled app with examples')
    console.log('  todo-app       - Interactive todo list application\n')
  })

cli.version(craftVersion)
cli.help()
cli.parse()

// Template generators

function createMinimalTemplate(projectPath: string, projectName: string): void {
  console.log('📝 Generating minimal template...')

  // Create package.json
  const packageJson = {
    name: projectName,
    version: '0.0.1',
    type: 'module',
    private: true,
    scripts: {
      doctor: 'craft --version',
      dev: 'bun run src/index.ts',
      build: 'bun build src/index.ts --outdir dist --target bun',
    },
    dependencies: {
      'craft-native': `^${craftVersion}`,

    },
    devDependencies: {
      '@types/bun': 'latest',
    },
  }

  writeFileSync(
    join(projectPath, 'package.json'),
    JSON.stringify(packageJson, null, 2),
  )

  // Create src directory
  mkdirSync(join(projectPath, 'src'))

  // Create src/index.ts
  const indexTs = `import { show } from 'craft-native'

const html = \`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    body {
      margin: 0;
      height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    }
    h1 {
      font-size: 3rem;
      text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
    }
  </style>
</head>
<body>
  <h1>⚡ Hello from ${projectName}!</h1>
</body>
</html>
\`

await show(html, {
  title: '${projectName}',
  width: 600,
  height: 400,
})
`

  writeFileSync(join(projectPath, 'src/index.ts'), indexTs)

  // Create README.md
  const readme = `# ${projectName}

A minimal Craft desktop application.

## Getting Started

\`\`\`bash
bun install
bun run doctor
bun run dev
\`\`\`

\`bun run doctor\` verifies that the native \`craft\` binary is available on your PATH. Install it with \`pantry install craft\` if the command is missing.

## Build

\`\`\`bash
bun run build
\`\`\`

## Learn More

- [Craft Documentation](https://github.com/home-lang/craft)
- [TypeScript SDK](https://github.com/home-lang/craft/tree/main/packages/typescript)
`

  writeFileSync(join(projectPath, 'README.md'), readme)

  // Create .gitignore
  const gitignore = `node_modules
dist
zig-out
zig-cache
.DS_Store
`

  writeFileSync(join(projectPath, '.gitignore'), gitignore)
}

function createFullFeaturedTemplate(projectPath: string, projectName: string): void {
  console.log('📝 Generating full-featured template...')

  // Create package.json
  const packageJson = {
    name: projectName,
    version: '0.0.1',
    type: 'module',
    private: true,
    scripts: {
      doctor: 'craft --version',
      dev: 'bun run src/index.ts',
      build: 'bun build src/index.ts --outdir dist --target bun',
    },
    dependencies: {
      'craft-native': `^${craftVersion}`,

    },
    devDependencies: {
      '@types/bun': 'latest',
    },
  }

  writeFileSync(
    join(projectPath, 'package.json'),
    JSON.stringify(packageJson, null, 2),
  )

  // Create src directory
  mkdirSync(join(projectPath, 'src'))

  // Create src/index.ts
  const indexTs = `import { show } from 'craft-native'

const html = \`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
      padding: 20px;
    }

    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      max-width: 600px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    }

    h1 {
      color: #667eea;
      font-size: 2.5rem;
      margin-bottom: 20px;
    }

    p {
      color: #666;
      line-height: 1.6;
      margin-bottom: 30px;
    }

    .features {
      display: grid;
      gap: 15px;
    }

    .feature {
      padding: 15px;
      background: #f8f9fa;
      border-radius: 8px;
      border-left: 4px solid #667eea;
    }

    .feature h3 {
      color: #333;
      margin-bottom: 5px;
    }

    .feature p {
      margin: 0;
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>⚡ ${projectName}</h1>
    <p>Welcome to your new Craft desktop application!</p>

    <div class="features">
      <div class="feature">
        <h3>🚀 Fast</h3>
        <p>Built with Zig for maximum performance</p>
      </div>
      <div class="feature">
        <h3>💡 Simple</h3>
        <p>TypeScript-first API, no Zig required</p>
      </div>
      <div class="feature">
        <h3>🎨 Modern</h3>
        <p>Use any web framework you love</p>
      </div>
    </div>
  </div>
</body>
</html>
\`

await show(html, {
  title: '${projectName}',
  width: 800,
  height: 600,
})
`

  writeFileSync(join(projectPath, 'src/index.ts'), indexTs)

  // Create README.md
  const readme = `# ${projectName}

A full-featured Craft desktop application.

## Getting Started

\`\`\`bash
bun install
bun run doctor
bun run dev
\`\`\`

\`bun run doctor\` verifies that the native \`craft\` binary is available on your PATH. Install it with \`pantry install craft\` if the command is missing.

## Build

\`\`\`bash
bun run build
\`\`\`

## Features

- ⚡ Fast startup and runtime performance
- 💡 TypeScript-first development
- 🎨 Modern HTML/CSS/JavaScript support
- 🔥 Hot reload in development mode

## Learn More

- [Craft Documentation](https://github.com/home-lang/craft)
- [TypeScript SDK](https://github.com/home-lang/craft/tree/main/packages/typescript)
`

  writeFileSync(join(projectPath, 'README.md'), readme)

  // Create .gitignore
  const gitignore = `node_modules
dist
zig-out
zig-cache
.DS_Store
`

  writeFileSync(join(projectPath, '.gitignore'), gitignore)
}

function createTodoAppTemplate(projectPath: string, projectName: string): void {
  console.log('📝 Generating todo app template...')

  // Create package.json
  const packageJson = {
    name: projectName,
    version: '0.0.1',
    type: 'module',
    private: true,
    scripts: {
      doctor: 'craft --version',
      dev: 'bun run src/index.ts',
      build: 'bun build src/index.ts --outdir dist --target bun',
    },
    dependencies: {
      'craft-native': `^${craftVersion}`,

    },
    devDependencies: {
      '@types/bun': 'latest',
    },
  }

  writeFileSync(
    join(projectPath, 'package.json'),
    JSON.stringify(packageJson, null, 2),
  )

  // Create src directory
  mkdirSync(join(projectPath, 'src'))

  // Create src/index.ts with full todo app
  const indexTs = `import { show } from 'craft-native'

const html = \`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
      padding: 20px;
    }

    .container {
      background: white;
      border-radius: 16px;
      padding: 30px;
      width: 100%;
      max-width: 500px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    }

    h1 {
      color: #667eea;
      margin-bottom: 20px;
      font-size: 2rem;
    }

    .input-group {
      display: flex;
      gap: 10px;
      margin-bottom: 20px;
    }

    input[type="text"] {
      flex: 1;
      padding: 12px;
      border: 2px solid #e0e0e0;
      border-radius: 8px;
      font-size: 1rem;
    }

    button {
      padding: 12px 24px;
      background: #667eea;
      color: white;
      border: none;
      border-radius: 8px;
      cursor: pointer;
      font-size: 1rem;
      font-weight: 600;
    }

    button:hover {
      background: #5568d3;
    }

    .todo-list {
      list-style: none;
    }

    .todo-item {
      display: flex;
      align-items: center;
      padding: 15px;
      background: #f8f9fa;
      border-radius: 8px;
      margin-bottom: 10px;
      gap: 10px;
    }

    .todo-item.completed {
      opacity: 0.6;
    }

    .todo-item.completed span {
      text-decoration: line-through;
    }

    input[type="checkbox"] {
      width: 20px;
      height: 20px;
      cursor: pointer;
    }

    .todo-text {
      flex: 1;
      color: #333;
    }

    .delete-btn {
      padding: 6px 12px;
      background: #ff6b6b;
      font-size: 0.9rem;
    }

    .delete-btn:hover {
      background: #ee5a52;
    }

    .empty-state {
      text-align: center;
      padding: 40px;
      color: #999;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>📝 Todo List</h1>

    <div class="input-group">
      <input type="text" id="todoInput" placeholder="What needs to be done?" />
      <button onclick="addTodo()">Add</button>
    </div>

    <ul id="todoList" class="todo-list"></ul>
    <div id="emptyState" class="empty-state">No todos yet. Add one above!</div>
  </div>

  <script>
    let todos = []

    function render() {
      const list = document.getElementById('todoList')
      const emptyState = document.getElementById('emptyState')

      if (todos.length === 0) {
        list.innerHTML = ''
        emptyState.style.display = 'block'
        return
      }

      emptyState.style.display = 'none'
      list.innerHTML = todos.map((todo, index) => \\\`
        <li class="todo-item \\\${todo.completed ? 'completed' : ''}">
          <input type="checkbox" \\\${todo.completed ? 'checked' : ''} onchange="toggleTodo(\\\${index})" />
          <span class="todo-text">\\\${todo.text}</span>
          <button class="delete-btn" onclick="deleteTodo(\\\${index})">Delete</button>
        </li>
      \\\`).join('')
    }

    function addTodo() {
      const input = document.getElementById('todoInput')
      const text = input.value.trim()

      if (text) {
        todos.push({ text, completed: false })
        input.value = ''
        render()
      }
    }

    function toggleTodo(index) {
      todos[index].completed = !todos[index].completed
      render()
    }

    function deleteTodo(index) {
      todos.splice(index, 1)
      render()
    }

    document.getElementById('todoInput').addEventListener('keypress', (e) => {
      if (e.key === 'Enter') {
        addTodo()
      }
    })

    render()
  </script>
</body>
</html>
\`

await show(html, {
  title: '${projectName}',
  width: 600,
  height: 700,
})
`

  writeFileSync(join(projectPath, 'src/index.ts'), indexTs)

  // Create README.md
  const readme = `# ${projectName}

An interactive todo list application built with Craft.

## Getting Started

\`\`\`bash
bun install
bun run doctor
bun run dev
\`\`\`

\`bun run doctor\` verifies that the native \`craft\` binary is available on your PATH. Install it with \`pantry install craft\` if the command is missing.

## Build

\`\`\`bash
bun run build
\`\`\`

## Features

- ✅ Add, complete, and delete todos
- 💾 Clean, modern UI
- ⚡ Fast and lightweight

## Learn More

- [Craft Documentation](https://github.com/home-lang/craft)
- [TypeScript SDK](https://github.com/home-lang/craft/tree/main/packages/typescript)
`

  writeFileSync(join(projectPath, 'README.md'), readme)

  // Create .gitignore
  const gitignore = `node_modules
dist
zig-out
zig-cache
.DS_Store
`

  writeFileSync(join(projectPath, '.gitignore'), gitignore)
}

function installDependencies(projectPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn('bun', ['install'], {
      cwd: projectPath,
      stdio: 'inherit',
    })

    proc.on('exit', (code) => {
      if (code === 0 || code === null) {
        resolve()
      }
      else {
        reject(new Error(`Installation failed with code ${code}`))
      }
    })

    proc.on('error', (error) => {
      reject(error)
    })
  })
}

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { init, type CraftAndroidConfig } from '../src/index'

interface CompileFixture {
  config?: Partial<CraftAndroidConfig>
  directoryName: string
  name: string
  packageName: string
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const packageDirectory = dirname(scriptDirectory)
const compileFixtureDirectory = join(packageDirectory, 'compile-fixtures')
const compileTestTemplates = readdirSync(compileFixtureDirectory, { withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith('Test.kt'))
  .map(entry => ({
    name: entry.name,
    source: readFileSync(join(compileFixtureDirectory, entry.name), 'utf8'),
  }))
const gradleExecutable = process.env.GRADLE_EXECUTABLE || 'gradle'
const keepProjects = process.argv.includes('--keep')
const workspace = mkdtempSync(join(tmpdir(), 'craft-android-templates-'))

const fixtures: CompileFixture[] = [
  {
    directoryName: 'minimal',
    name: 'Craft & "Kotlin" $Build',
    packageName: 'dev.craft.fixture.minimal',
  },
  {
    directoryName: 'capabilities',
    name: 'CraftTemplateCapabilities',
    packageName: 'dev.craft.fixture.capabilities',
    config: {
      enableBackgroundLocation: true,
      enableBiometric: true,
      enableCamera: true,
      enableDeepLinks: true,
      enableGeolocation: true,
      enableHaptics: true,
      enableHealthConnect: true,
      enableKeepAwake: true,
      enablePushNotifications: true,
      enableSecureStorage: true,
      enableShare: true,
      enableSpeechRecognition: true,
      trustedOrigins: ['https://fixture.craft.dev'],
      urlSchemes: ['craft-fixture'],
    },
  },
]

function writeGoogleServicesFixture(path: string, packageName: string): void {
  writeFileSync(path, JSON.stringify({
    client: [{
      api_key: [{ current_key: 'fixture-api-key' }],
      client_info: {
        android_client_info: { package_name: packageName },
        mobilesdk_app_id: '1:123456789:android:0123456789abcdef',
      },
    }],
    configuration_version: '1',
    project_info: {
      project_id: 'craft-template-fixture',
      project_number: '123456789',
      storage_bucket: 'craft-template-fixture.appspot.com',
    },
  }, null, 2))
}

try {
  for (const fixture of fixtures) {
    const output = join(workspace, fixture.directoryName)
    const config = { ...fixture.config }

    if (config.enablePushNotifications) {
      const googleServicesFile = join(workspace, `${fixture.directoryName}-google-services.json`)
      writeGoogleServicesFixture(googleServicesFile, fixture.packageName)
      config.googleServicesFile = googleServicesFile
    }

    await init({
      name: fixture.name,
      output,
      packageName: fixture.packageName,
      config,
    })

    const testDirectory = join(
      output,
      'app/src/test/java',
      fixture.packageName.replaceAll('.', '/'),
    )
    mkdirSync(testDirectory, { recursive: true })
    for (const testTemplate of compileTestTemplates) {
      writeFileSync(
        join(testDirectory, testTemplate.name),
        testTemplate.source.replaceAll('{{PACKAGE_NAME}}', fixture.packageName),
      )
    }

    console.log(`\nCompiling generated Android fixture: ${fixture.name}`)
    const result = Bun.spawnSync([
      gradleExecutable,
      '--no-daemon',
      '--stacktrace',
      ':app:assembleDebug',
      ':app:assembleRelease',
      ':app:testDebugUnitTest',
    ], {
      cwd: output,
      env: process.env,
      stderr: 'inherit',
      stdout: 'inherit',
    })

    if (result.exitCode !== 0) {
      throw new Error(`${fixture.name} Gradle build exited with ${result.exitCode}`)
    }
  }
}
finally {
  if (keepProjects) {
    console.log(`\nGenerated Android fixtures kept at ${workspace}`)
  }
  else {
    rmSync(workspace, { force: true, recursive: true })
  }
}

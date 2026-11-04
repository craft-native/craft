/** Compile and execute a native Kotlin fixture with Gradle's dependency resolver. */
import { readFileSync } from 'node:fs'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'

/** Uses the Android builder's Kotlin version, including its transitive compiler dependencies. */
export async function runKotlinFixture(source: string, libraries: readonly string[] = []): Promise<void> {
  const gradle = Bun.which('gradle')
  if (!gradle) throw new Error('Gradle is required to run native Kotlin fixtures')
  const template = readFileSync(join(dirname(import.meta.dir), 'templates/build.gradle.kts.project.template'), 'utf8')
  const version = template.match(/id\("org.jetbrains.kotlin.android"\) version "([\d.]+)"/)?.[1]
  if (!version) throw new Error('The Android builder Kotlin version is missing')
  const directory = await mkdtemp(join(tmpdir(), 'craft-kotlin-fixture-'))
  try {
    await writeFile(join(directory, 'Fixture.kt'), source)
    await writeFile(join(directory, 'settings.gradle'), "rootProject.name = 'craft-kotlin-fixture'\n")
    await writeFile(join(directory, 'gradle.properties'), 'org.gradle.jvmargs=-Xmx512m\n')
    await writeFile(join(directory, 'build.gradle'), `
repositories { mavenCentral() }
configurations {
    kotlinCompiler
    kotlinRuntime
}
dependencies {
    kotlinCompiler 'org.jetbrains.kotlin:kotlin-compiler-embeddable:${version}'
    kotlinRuntime 'org.jetbrains.kotlin:kotlin-stdlib:${version}'
${libraries.map(library => `    kotlinRuntime ${JSON.stringify(library)}`).join('\n')}
}
tasks.register('compileFixture', JavaExec) {
    classpath = configurations.kotlinCompiler
    mainClass = 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler'
    args '-no-stdlib', '-no-reflect', '-classpath', configurations.kotlinRuntime.asPath,
         '-d', layout.buildDirectory.dir('classes').get().asFile.absolutePath,
         file('Fixture.kt').absolutePath
}
tasks.register('runFixture', JavaExec) {
    dependsOn 'compileFixture'
    classpath = files(layout.buildDirectory.dir('classes')) + configurations.kotlinRuntime
    mainClass = 'FixtureKt'
}
`)
    const child = Bun.spawn([gradle, '--no-daemon', '--console=plain', '--max-workers=2', 'runFixture'], {
      cwd: directory,
      stdout: 'inherit',
      stderr: 'inherit',
    })
    const code = await child.exited
    if (code !== 0) throw new Error(`Native Kotlin fixture failed with exit code ${code}`)
  }
  finally {
    await rm(directory, { recursive: true, force: true })
  }
}

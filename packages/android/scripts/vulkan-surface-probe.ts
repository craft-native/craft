/** Version identity for the frontend used by the owned native fixture. */
export function emulatorVersionCommand(executable: string): string[] {
  return [executable, '-no-window', '-no-audio', '-version']
}

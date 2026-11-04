/** App-script fixture: actions must work with no screen or Activity alive. */
export default function (craft: {
  storage: { set(key: string, value: unknown): Promise<unknown> }
  background: { complete(ok: boolean, id: string): Promise<unknown> }
}): () => void {
  const receive = (event: Event) => {
    const detail = (event as CustomEvent).detail
    void craft.storage.set('fixture-notification-action', detail)
      .then(() => craft.background.complete(true, detail.id))
      .catch(() => craft.background.complete(false, detail.id))
  }
  globalThis.addEventListener('craftNotificationAction', receive)
  return () => globalThis.removeEventListener('craftNotificationAction', receive)
}

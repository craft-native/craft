export interface TypedLiveActivityHandle<State> {
  readonly id: string
  update(state: State): Promise<void>
  end(finalState?: State): Promise<void>
}

export function createLiveActivityHandle<State>(
  id: string,
  update: (state: State) => Promise<void>,
  end: (finalState?: State) => Promise<void>,
): TypedLiveActivityHandle<State> {
  return {
    id,
    update,
    end,
  }
}

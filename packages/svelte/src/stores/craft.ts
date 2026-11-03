import { writable, derived } from 'svelte/store';
import type { Readable } from 'svelte/store';

// Core owns Window.craft; bindings retain their legacy flat host view.
import type { CraftBindingsAPI as CraftAPI } from 'craft-native';

function createCraftStore(): Readable<CraftAPI | null> {
  const { subscribe, set } = writable<CraftAPI | null>(null);

  if (typeof window !== 'undefined') {
    if (window.craft) {
      set(window.craft as unknown as CraftAPI);
    }
else {
      const checkCraft = setInterval(() => {
        if (window.craft) {
          set(window.craft as unknown as CraftAPI);
          clearInterval(checkCraft);
        }
      }, 100);
    }
  }

  return {
    subscribe,
  };
}

export const craft = createCraftStore();
export const isReady = derived(craft, (_$craft) => _$craft !== null);
